// UserShard manages a stripe of user connections. Each user has one TCP
// connection and subscribes to:
//
//   - K_visible market symbols (half from their assigned screen, half Zipf from all)
//   - orders.{uid} and trades.{uid} if the user is an algo user
//
// Scroll events periodically swap some visible market symbols for new ones
// drawn with Zipf weights from the not-visible pool.
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel/metric"
	"open-wire-bench/internal/msg"
)

// SID allocation per user connection:
//
//	1        = orders.{uid}  (algo users only)
//	2        = trades.{uid}  (algo users only)
//	100..N   = market symbol slots (slot i → SID 100+i)
const (
	sidOrders     = uint32(1)
	sidTrades     = uint32(2)
	sidMarketBase = uint32(100)
)

// UserShard manages a stripe of user goroutines for this process.
type UserShard struct {
	ShardID    int
	ShardCount int
	Config     *Config
	MarketRx   atomic.Int64
	OrdersRx   atomic.Int64
	TradesRx   atomic.Int64
	ScrollEvts atomic.Int64

	// OTel instruments — set once before Run(), read-only after.
	Latency metric.Float64Histogram
	MktAttr metric.MeasurementOption
	OrdAttr metric.MeasurementOption
	TrdAttr metric.MeasurementOption
}

// Run launches one goroutine per owned user and blocks until stop fires.
func (s *UserShard) Run(stop *atomic.Bool, wg *sync.WaitGroup) {
	if s.Config.Protocol == "nats" {
		s.runNATSUsers(stop, wg)
		return
	}

	defer wg.Done()

	myUsers := ShardIndices(s.Config.Users, s.ShardID, s.ShardCount)
	if len(myUsers) == 0 {
		return
	}
	zipf := NewZipfSampler(s.Config.Alpha)

	var inner sync.WaitGroup
	for _, uid := range myUsers {
		inner.Add(1)
		u := &userConn{uid: uid, config: s.Config, zipf: zipf, shard: s, stop: stop}
		go u.run(&inner)
	}
	inner.Wait()
}

// userConn represents one user's TCP connection to the broker.
type userConn struct {
	uid    int
	config *Config
	zipf   *ZipfSampler
	shard  *UserShard
	stop   *atomic.Bool
}

func (u *userConn) run(wg *sync.WaitGroup) {
	defer wg.Done()

	conn, err := net.DialTimeout("tcp", u.config.URL, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "user[%d]: connect: %v\n", u.uid, err)
		return
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true)          //nolint:errcheck
		tc.SetReadBuffer(256 * 1024) //nolint:errcheck
	}

	// Mutex-protected writer — scroll goroutine and read loop both write Pong/SUB/UNSUB.
	var writeMu sync.Mutex
	write := func(frame []byte) error {
		writeMu.Lock()
		_, err := conn.Write(frame)
		writeMu.Unlock()
		return err
	}

	// Private subscriptions for algo users.
	isAlgo := u.uid < u.config.AlgoUsers
	if isAlgo {
		if err := write(subFrame([]byte(fmt.Sprintf("orders.%06d", u.uid)), sidOrders)); err != nil {
			return
		}
		if err := write(subFrame([]byte(fmt.Sprintf("trades.%06d", u.uid)), sidTrades)); err != nil {
			return
		}
	}

	// Build initial visible set and not-visible pool.
	rng := rand.New(rand.NewSource(int64(u.uid)*2654435761 + 1))
	visibleIdx, notVisible := u.buildVisible(rng)

	// Subscribe to each visible market symbol.
	for slot, symIdx := range visibleIdx {
		subj := []byte(fmt.Sprintf("market.sym%04d", symIdx))
		if err := write(subFrame(subj, sidMarketBase+uint32(slot))); err != nil {
			return
		}
	}

	// Read loop: dispatches inbound frames, records latency, responds to Pings.
	readDone := make(chan struct{})
	go func() {
		var mktCount, ordCount, trdCount int64
		defer func() {
			// Flush residual counts — otherwise low-rate channels (orders/trades)
			// lose their entire count since they rarely fill a batch in a short run.
			if mktCount > 0 {
				u.shard.MarketRx.Add(mktCount)
			}
			if ordCount > 0 {
				u.shard.OrdersRx.Add(ordCount)
			}
			if trdCount > 0 {
				u.shard.TradesRx.Add(trdCount)
			}
			close(readDone)
		}()
		ctx := context.Background()
		hdr := make([]byte, headerLen)
		body := make([]byte, 512)

		for {
			if _, err := io.ReadFull(conn, hdr); err != nil {
				return
			}
			subjLen := int(binary.LittleEndian.Uint16(hdr[1:3]))
			replLen := int(binary.LittleEndian.Uint16(hdr[3:5]))
			payLen := int(binary.LittleEndian.Uint32(hdr[5:9]))
			bodyLen := subjLen + replLen + payLen
			if bodyLen > len(body) {
				body = make([]byte, bodyLen+256)
			}
			if bodyLen > 0 {
				if _, err := io.ReadFull(conn, body[:bodyLen]); err != nil {
					return
				}
			}

			switch hdr[0] {
			case 0x01: // Ping
				writeMu.Lock()
				conn.Write(pongFrame) //nolint:errcheck
				writeMu.Unlock()

			case 0x03, 0x04: // Msg, HMsg
				subj := body[:subjLen]
				pay := body[subjLen+replLen : bodyLen]

				switch {
				case hasPrefix(subj, "market."):
					mktCount++
					if mktCount == 256 {
						u.shard.MarketRx.Add(256)
						mktCount = 0
					}
					// Sample 1-in-50 for latency — reduces OTel overhead on the hot path.
					if mktCount%50 == 1 {
						if latNs, _, ok := msg.Decode(pay); ok && latNs > 0 {
							u.shard.Latency.Record(ctx, float64(latNs)*1e-9, u.shard.MktAttr)
						}
					}
				case hasPrefix(subj, "orders."):
					ordCount++
					if ordCount == 64 {
						u.shard.OrdersRx.Add(64)
						ordCount = 0
					}
					if latNs, _, ok := msg.Decode(pay); ok && latNs > 0 {
						u.shard.Latency.Record(ctx, float64(latNs)*1e-9, u.shard.OrdAttr)
					}
				case hasPrefix(subj, "trades."):
					trdCount++
					if trdCount == 64 {
						u.shard.TradesRx.Add(64)
						trdCount = 0
					}
					if latNs, _, ok := msg.Decode(pay); ok && latNs > 0 {
						u.shard.Latency.Record(ctx, float64(latNs)*1e-9, u.shard.TrdAttr)
					}
				}
			}
		}
	}()

	// Stop watcher: sets read deadline when global stop fires, unblocking the read loop.
	go func() {
		for !u.stop.Load() {
			time.Sleep(50 * time.Millisecond)
		}
		conn.SetDeadline(time.Now().Add(200 * time.Millisecond)) //nolint:errcheck
	}()

	// Scroll loop: swap some visible symbols on each tick.
	scrollTicker := time.NewTicker(u.config.ScrollInterval)
	defer scrollTicker.Stop()

	for {
		select {
		case <-readDone:
			return
		case <-scrollTicker.C:
			if u.stop.Load() {
				<-readDone
				return
			}
			u.scroll(rng, visibleIdx, notVisible, write)
			u.shard.ScrollEvts.Add(1)
		}
	}
}

// buildVisible constructs the initial visible symbol slots and the not-visible pool.
//
// Half the visible slots come from the user's assigned screen (uniform random within
// the screen range — all are "popular"). The other half come from a Zipf-weighted
// sample of the remaining symbols. This concentrates fan-out on popular symbols
// while preserving long-tail diversity across users.
func (u *userConn) buildVisible(rng *rand.Rand) (visibleIdx []int, notVisible []int) {
	cfg := u.config
	k := cfg.VisibleK
	if k > cfg.Symbols {
		k = cfg.Symbols
	}

	// Assign user to a screen.
	screen := cfg.Screens[u.uid%len(cfg.Screens)]
	screenIdxs := screen.Indices(cfg.Symbols)

	// Half of visible from screen, half from Zipf over the rest.
	kScreen := k / 2
	if kScreen > len(screenIdxs) {
		kScreen = len(screenIdxs)
	}

	// Shuffle screen indices and take the first kScreen.
	rng.Shuffle(len(screenIdxs), func(i, j int) {
		screenIdxs[i], screenIdxs[j] = screenIdxs[j], screenIdxs[i]
	})
	screenSet := make(map[int]bool, kScreen)
	for i := 0; i < kScreen; i++ {
		screenSet[screenIdxs[i]] = true
	}

	// Build a pool of all symbols not taken by the screen selection.
	kZipf := k - kScreen
	pool := make([]int, 0, cfg.Symbols-kScreen)
	for i := 0; i < cfg.Symbols; i++ {
		if !screenSet[i] {
			pool = append(pool, i)
		}
	}
	zipfPicked := u.zipf.Sample(rng, pool, kZipf)

	// Merge into visibleIdx.
	visSet := make(map[int]bool, k)
	visibleIdx = make([]int, 0, k)
	for i := 0; i < kScreen; i++ {
		idx := screenIdxs[i]
		visSet[idx] = true
		visibleIdx = append(visibleIdx, idx)
	}
	for _, idx := range zipfPicked {
		if !visSet[idx] {
			visSet[idx] = true
			visibleIdx = append(visibleIdx, idx)
		}
	}

	// notVisible = everything not in visibleIdx.
	notVisible = make([]int, 0, cfg.Symbols-len(visibleIdx))
	for i := 0; i < cfg.Symbols; i++ {
		if !visSet[i] {
			notVisible = append(notVisible, i)
		}
	}
	return visibleIdx, notVisible
}

// scroll swaps up to ScrollCount visible symbols for new Zipf-weighted picks
// from the not-visible pool. Both visibleIdx and notVisible are modified in place.
func (u *userConn) scroll(rng *rand.Rand, visibleIdx []int, notVisible []int, write func([]byte) error) {
	count := u.config.ScrollCount
	if count > len(visibleIdx) {
		count = len(visibleIdx)
	}
	k := len(visibleIdx)

	for i := 0; i < count; i++ {
		if len(notVisible) == 0 {
			break
		}
		// Pick a new symbol from the not-visible pool (Zipf-weighted).
		picks := u.zipf.Sample(rng, notVisible, 1)
		if len(picks) == 0 {
			break
		}
		newIdx := picks[0]

		// Pick a random slot to evict.
		slot := rng.Intn(k)
		oldIdx := visibleIdx[slot]

		// Swap newIdx out of the not-visible pool, put oldIdx in its place.
		for j, v := range notVisible {
			if v == newIdx {
				notVisible[j] = oldIdx
				break
			}
		}

		// Update visible tracking and send UNSUB + SUB.
		visibleIdx[slot] = newIdx
		sid := sidMarketBase + uint32(slot)
		write(unsubFrame(sid))                                                          //nolint:errcheck
		write(subFrame([]byte(fmt.Sprintf("market.sym%04d", newIdx)), sid)) //nolint:errcheck
	}
}

// hasPrefix reports whether b starts with the given ASCII string, without allocating.
func hasPrefix(b []byte, prefix string) bool {
	if len(b) < len(prefix) {
		return false
	}
	for i := 0; i < len(prefix); i++ {
		if b[i] != prefix[i] {
			return false
		}
	}
	return true
}
