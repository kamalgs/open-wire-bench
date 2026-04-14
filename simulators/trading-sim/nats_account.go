// nats_account.go — NATS-protocol publisher for AccountShard.
// Mirrors runTier() but uses nats.go instead of raw TCP + binary framing.
package main

import (
	"fmt"
	"math/rand"
	"os"
	"sync"
	"sync/atomic"
	"time"

	natsgo "github.com/nats-io/nats.go"
	"open-wire-bench/internal/msg"
)

// runNATSTier publishes order/trade events via the NATS protocol.
// One nats.Conn per tier; users published round-robin at (orderRate+tradeRate) events/s each.
func (s *AccountShard) runNATSTier(userIDs []int, orderRate, tradeRate float64, tierName string, stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	nc, err := natsgo.Connect(s.Config.URL,
		natsgo.Name(fmt.Sprintf("account-%d/%s", s.ShardID, tierName)),
		natsgo.MaxReconnects(-1),
		natsgo.ReconnectWait(200*time.Millisecond),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "account[%d/%s]: nats connect %s: %v\n", s.ShardID, tierName, s.Config.URL, err)
		return
	}
	defer nc.Close()

	n := len(userIDs)
	combinedRate := (orderRate + tradeRate) * float64(n)
	if combinedRate < 0.01 {
		combinedRate = 0.01
	}
	interval := time.Duration(float64(time.Second) / combinedRate)
	if interval < time.Millisecond {
		interval = time.Millisecond
	}
	orderFrac := orderRate / (orderRate + tradeRate)

	rng := rand.New(rand.NewSource(int64(s.ShardID)*2654435761 + int64(len(userIDs))))
	payload := make([]byte, s.Config.PayloadSize)
	var seq uint64
	userIdx := 0
	var localOrders, localTrades int64

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for !stop.Load() {
		select {
		case <-ticker.C:
			uid := userIDs[userIdx]
			userIdx = (userIdx + 1) % n
			msg.Encode(payload, seq)
			seq++
			if rng.Float64() < orderFrac {
				nc.Publish(fmt.Sprintf("orders.%06d", uid), payload) //nolint:errcheck
				localOrders++
			} else {
				nc.Publish(fmt.Sprintf("trades.%06d", uid), payload) //nolint:errcheck
				localTrades++
			}
			if localOrders == 256 {
				s.OrdersPub.Add(localOrders)
				localOrders = 0
			}
			if localTrades == 256 {
				s.TradesPub.Add(localTrades)
				localTrades = 0
			}
		}
	}
	s.OrdersPub.Add(localOrders)
	s.TradesPub.Add(localTrades)
	nc.Flush() //nolint:errcheck
}
