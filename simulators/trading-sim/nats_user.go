// nats_user.go — NATS-protocol subscriber for UserShard.
// Mirrors the binary-mode run()/read-loop in user.go but uses nats.go subscriptions.
package main

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"sync/atomic"
	"time"

	natsgo "github.com/nats-io/nats.go"
	"open-wire-bench/internal/msg"
)

// runNATSUsers launches one goroutine per owned user (NATS mode) and blocks until stop fires.
func (s *UserShard) runNATSUsers(stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	myUsers := ShardIndices(s.Config.Users, s.ShardID, s.ShardCount)
	if len(myUsers) == 0 {
		return
	}
	zipf := NewZipfSampler(s.Config.Alpha)

	var inner sync.WaitGroup
	for _, uid := range myUsers {
		inner.Add(1)
		go s.runNATSUser(uid, zipf, stop, &inner)
	}
	inner.Wait()
}

func (s *UserShard) runNATSUser(uid int, zipf *ZipfSampler, stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	nc, err := natsgo.Connect(s.Config.URL,
		natsgo.Name(fmt.Sprintf("user-%d", uid)),
		natsgo.MaxReconnects(-1),
		natsgo.ReconnectWait(200*time.Millisecond),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "user[%d]: nats connect %s: %v\n", uid, s.Config.URL, err)
		return
	}
	defer nc.Close()

	ctx := context.Background()
	isAlgo := uid < s.Config.AlgoUsers

	// Private subscriptions for algo users.
	if isAlgo {
		nc.Subscribe(fmt.Sprintf("orders.%06d", uid), func(m *natsgo.Msg) { //nolint:errcheck
			s.OrdersRx.Add(1)
			if latNs, _, ok := msg.Decode(m.Data); ok && latNs > 0 {
				s.Latency.Record(ctx, float64(latNs)*1e-9, s.OrdAttr)
			}
		})
		nc.Subscribe(fmt.Sprintf("trades.%06d", uid), func(m *natsgo.Msg) { //nolint:errcheck
			s.TradesRx.Add(1)
			if latNs, _, ok := msg.Decode(m.Data); ok && latNs > 0 {
				s.Latency.Record(ctx, float64(latNs)*1e-9, s.TrdAttr)
			}
		})
	}

	// Build initial visible set — reuse binary-mode logic via a minimal userConn.
	rng := rand.New(rand.NewSource(int64(uid)*2654435761 + 1))
	uc := &userConn{uid: uid, config: s.Config, zipf: zipf, shard: s, stop: stop}
	visibleIdx, notVisible := uc.buildVisible(rng)

	// Subscribe to each visible market symbol; retain handles for scroll.
	subs := make([]*natsgo.Subscription, len(visibleIdx))
	for slot, symIdx := range visibleIdx {
		subs[slot] = s.natsSubMkt(nc, ctx, symIdx)
	}

	// Stop watcher: fires stopCh when global stop is set.
	stopCh := make(chan struct{})
	go func() {
		for !stop.Load() {
			time.Sleep(50 * time.Millisecond)
		}
		close(stopCh)
	}()

	scrollTicker := time.NewTicker(s.Config.ScrollInterval)
	defer scrollTicker.Stop()

	for {
		select {
		case <-stopCh:
			return
		case <-scrollTicker.C:
			if stop.Load() {
				return
			}
			s.natsScroll(rng, visibleIdx, notVisible, subs, nc, ctx, zipf)
			s.ScrollEvts.Add(1)
		}
	}
}

// natsSubMkt subscribes to one market symbol and returns the subscription handle.
// Samples latency 1-in-50 using the sequence number from the payload.
func (s *UserShard) natsSubMkt(nc *natsgo.Conn, ctx context.Context, symIdx int) *natsgo.Subscription {
	sub, _ := nc.Subscribe(fmt.Sprintf("market.sym%04d", symIdx), func(m *natsgo.Msg) {
		s.MarketRx.Add(1)
		if latNs, seq, ok := msg.Decode(m.Data); ok && latNs > 0 && seq%50 == 0 {
			s.Latency.Record(ctx, float64(latNs)*1e-9, s.MktAttr)
		}
	})
	return sub
}

// natsScroll swaps visible symbols by un/re-subscribing. Mirrors binary-mode scroll().
func (s *UserShard) natsScroll(
	rng *rand.Rand, visibleIdx []int, notVisible []int,
	subs []*natsgo.Subscription, nc *natsgo.Conn, ctx context.Context,
	zipf *ZipfSampler,
) {
	count := s.Config.ScrollCount
	if count > len(visibleIdx) {
		count = len(visibleIdx)
	}
	k := len(visibleIdx)

	for i := 0; i < count; i++ {
		if len(notVisible) == 0 {
			break
		}
		picks := zipf.Sample(rng, notVisible, 1)
		if len(picks) == 0 {
			break
		}
		newIdx := picks[0]
		slot := rng.Intn(k)
		oldIdx := visibleIdx[slot]

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
		subs[slot] = s.natsSubMkt(nc, ctx, newIdx)
	}
}
