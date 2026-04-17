// user.go — UserShard manages a stripe of user connections.
//
// Each user subscribes to K_visible market symbols (half from their assigned
// screen, half Zipf from all) plus orders.{uid} and trades.{uid} for algo users.
// Scroll events periodically swap some visible market symbols for new ones.
//
// Subscription management is protocol-agnostic via dialMsgSub, which returns a
// MsgSub backed by either binary TCP or a NATS connection. Both protocols share
// identical business logic: gap/dup tracking, latency sampling, scroll handling,
// and reconnect on connection loss.
package main

import (
	"context"
	"fmt"
	"math/rand"
	"sync"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel/metric"
	"open-wire-bench/internal/msg"
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
	GapCount   atomic.Int64 // missed market messages detected via sequence gaps
	DupCount   atomic.Int64 // duplicate or out-of-order market messages detected

	// OTel instruments — set once before Run(), read-only after.
	Latency metric.Float64Histogram
	MktAttr metric.MeasurementOption
	OrdAttr metric.MeasurementOption
	TrdAttr metric.MeasurementOption
}

// Run launches one goroutine per owned user and blocks until stop fires.
func (s *UserShard) Run(stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	myUsers := ShardIndices(s.Config.Users, s.ShardID, s.ShardCount)
	if len(myUsers) == 0 {
		return
	}
	zipf := NewZipfSampler(s.Config.Alpha)

	var inner sync.WaitGroup
	for i, uid := range myUsers {
		inner.Add(1)
		u := &userConn{uid: uid, config: s.Config, zipf: zipf, shard: s, stop: stop}
		go u.run(&inner)
		// Stagger connections to avoid overwhelming the broker's accept queue.
		if i > 0 && i%50 == 0 {
			time.Sleep(10 * time.Millisecond)
		}
	}
	inner.Wait()
}

// userConn represents one user's broker connection.
type userConn struct {
	uid    int
	config *Config
	zipf   *ZipfSampler
	shard  *UserShard
	stop   *atomic.Bool
}

// seqState tracks the last-seen sequence number for one subscription slot.
// Each subscription closure owns its own *seqState, so scroll-induced
// resubscriptions start gap tracking fresh without any explicit reset.
type seqState struct {
	last uint64
	init bool
}

// subMarket subscribes to one market symbol and returns a SubHandle.
// The closure owns a fresh *seqState; gap/dup counts go to shard atomics.
// Latency is sampled every 500th sequence number (deterministic across protocols).
func subMarket(sub MsgSub, shard *UserShard, ctx context.Context, symIdx int) SubHandle {
	st := &seqState{}
	h, _ := sub.Subscribe(fmt.Sprintf("market.sym%04d", symIdx), func(payload []byte) {
		shard.MarketRx.Add(1)
		if latNs, seq, ok := msg.Decode(payload); ok {
			if st.init {
				if seq > st.last+1 {
					shard.GapCount.Add(int64(seq - st.last - 1))
				} else if seq <= st.last {
					shard.DupCount.Add(1)
				}
			}
			st.last = seq
			st.init = true
			// Sample every 500th seq — deterministic and protocol-neutral.
			if latNs > 0 && seq%500 == 0 {
				shard.Latency.Record(ctx, float64(latNs)*1e-9, shard.MktAttr)
			}
		}
	})
	return h
}

func (u *userConn) run(wg *sync.WaitGroup) {
	defer wg.Done()

	isAlgo := u.uid < u.config.AlgoUsers

	// Scroll state and RNG persist across reconnects.
	rng := rand.New(rand.NewSource(int64(u.uid)*2654435761 + 1))
	visibleIdx, notVisible := u.buildVisible(rng)

	// stopCh closes once when the global stop flag fires.
	stopCh := make(chan struct{})
	go func() {
		for !u.stop.Load() {
			time.Sleep(50 * time.Millisecond)
		}
		close(stopCh)
	}()

	scrollTicker := time.NewTicker(u.config.ScrollInterval)
	defer scrollTicker.Stop()

	ctx := context.Background()
	name := fmt.Sprintf("user-%d", u.uid)

outer:
	for {
		select {
		case <-stopCh:
			return
		default:
		}

		sub := dialMsgSub(u.config, name, u.stop)
		if sub == nil {
			return // stop fired while connecting
		}

		// Subscribe algo channels (orders, trades).
		if isAlgo {
			sub.Subscribe(fmt.Sprintf("orders.%06d", u.uid), func(payload []byte) { //nolint:errcheck
				u.shard.OrdersRx.Add(1)
				if latNs, _, ok := msg.Decode(payload); ok && latNs > 0 {
					u.shard.Latency.Record(ctx, float64(latNs)*1e-9, u.shard.OrdAttr)
				}
			})
			sub.Subscribe(fmt.Sprintf("trades.%06d", u.uid), func(payload []byte) { //nolint:errcheck
				u.shard.TradesRx.Add(1)
				if latNs, _, ok := msg.Decode(payload); ok && latNs > 0 {
					u.shard.Latency.Record(ctx, float64(latNs)*1e-9, u.shard.TrdAttr)
				}
			})
		}

		// Subscribe to the current visible market symbols.
		// On reconnect this reflects wherever visibleIdx was left by scroll events.
		subs := make([]SubHandle, len(visibleIdx))
		for slot, symIdx := range visibleIdx {
			subs[slot] = subMarket(sub, u.shard, ctx, symIdx)
		}

		// Event loop: scroll, stop, or connection death.
		for {
			select {
			case <-stopCh:
				sub.Close()
				return
			case <-sub.Done():
				// Binary connection lost — reconnect.
				sub.Close()
				select {
				case <-stopCh:
					return
				case <-time.After(200 * time.Millisecond):
				}
				continue outer
			case <-scrollTicker.C:
				if u.stop.Load() {
					sub.Close()
					return
				}
				u.scrollSub(rng, visibleIdx, notVisible, subs, sub, ctx)
				u.shard.ScrollEvts.Add(1)
			}
		}
	}
}

// scrollSub swaps up to ScrollCount visible symbols for new Zipf-weighted picks.
// Each new subscription gets a fresh *seqState so no explicit reset is needed.
func (u *userConn) scrollSub(
	rng *rand.Rand, visibleIdx []int, notVisible []int,
	subs []SubHandle, sub MsgSub, ctx context.Context,
) {
	count := u.config.ScrollCount
	if count > len(visibleIdx) {
		count = len(visibleIdx)
	}
	k := len(visibleIdx)

	for i := 0; i < count; i++ {
		if len(notVisible) == 0 {
			break
		}
		picks := u.zipf.Sample(rng, notVisible, 1)
		if len(picks) == 0 {
			break
		}
		newIdx := picks[0]
		slot := rng.Intn(k)
		oldIdx := visibleIdx[slot]

		// Swap newIdx out of the not-visible pool.
		for j, v := range notVisible {
			if v == newIdx {
				notVisible[j] = oldIdx
				break
			}
		}

		visibleIdx[slot] = newIdx
		if subs[slot] != nil {
			subs[slot].Unsubscribe() //nolint:errcheck
		}
		// Fresh seqState in subMarket resets gap tracking for the new symbol.
		subs[slot] = subMarket(sub, u.shard, ctx, newIdx)
	}
}

// buildVisible constructs the initial visible symbol slots and the not-visible pool.
//
// Half the visible slots come from the user's assigned screen (uniform random within
// the screen range). The other half come from a Zipf-weighted sample of the remaining
// symbols. This concentrates fan-out on popular symbols while preserving long-tail
// diversity across users.
func (u *userConn) buildVisible(rng *rand.Rand) (visibleIdx []int, notVisible []int) {
	cfg := u.config
	k := cfg.VisibleK
	if k > cfg.Symbols {
		k = cfg.Symbols
	}

	screen := cfg.Screens[u.uid%len(cfg.Screens)]
	screenIdxs := screen.Indices(cfg.Symbols)

	kScreen := k / 2
	if kScreen > len(screenIdxs) {
		kScreen = len(screenIdxs)
	}

	rng.Shuffle(len(screenIdxs), func(i, j int) {
		screenIdxs[i], screenIdxs[j] = screenIdxs[j], screenIdxs[i]
	})
	screenSet := make(map[int]bool, kScreen)
	for i := 0; i < kScreen; i++ {
		screenSet[screenIdxs[i]] = true
	}

	kZipf := k - kScreen
	pool := make([]int, 0, cfg.Symbols-kScreen)
	for i := 0; i < cfg.Symbols; i++ {
		if !screenSet[i] {
			pool = append(pool, i)
		}
	}
	zipfPicked := u.zipf.Sample(rng, pool, kZipf)

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

	notVisible = make([]int, 0, cfg.Symbols-len(visibleIdx))
	for i := 0; i < cfg.Symbols; i++ {
		if !visSet[i] {
			notVisible = append(notVisible, i)
		}
	}
	return visibleIdx, notVisible
}
