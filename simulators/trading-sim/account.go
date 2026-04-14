// AccountShard publishes order and trade events for algo users owned by this shard.
//
// Algo users are split into tiers (hft/mm/retail) each at different rates.
// The shard owns a modulo stripe of each tier. One goroutine per tier fires a
// combined ticker and round-robins across users, randomly choosing order vs trade
// based on the tier's relative rates.
package main

import (
	"fmt"
	"math/rand"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"open-wire-bench/internal/msg"
)

// AccountShard publishes order/trade events for the algo users it owns.
type AccountShard struct {
	ShardID    int
	ShardCount int
	Config     *Config
	OrdersPub  atomic.Int64
	TradesPub  atomic.Int64
}

// Run launches one goroutine per algo tier slice and blocks until stop fires.
func (s *AccountShard) Run(stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	if s.Config.AlgoUsers == 0 || len(s.Config.AlgoTiers) == 0 {
		return
	}

	var inner sync.WaitGroup
	for _, tier := range s.Config.AlgoTiers {
		tierSize := tier.End - tier.Start
		mine := ShardIndices(tierSize, s.ShardID, s.ShardCount)
		if len(mine) == 0 {
			continue
		}
		// Resolve local-within-tier indices to global algo user IDs.
		userIDs := make([]int, len(mine))
		for i, localIdx := range mine {
			userIDs[i] = tier.Start + localIdx
		}
		inner.Add(1)
		if s.Config.Protocol == "nats" {
			go s.runNATSTier(userIDs, tier.OrderRate, tier.TradeRate, tier.Name, stop, &inner)
		} else {
			go s.runTier(userIDs, tier.OrderRate, tier.TradeRate, tier.Name, stop, &inner)
		}
	}
	inner.Wait()
}

// runTier owns one connection and publishes orders/trades round-robin across
// userIDs at the combined (orderRate+tradeRate) events/s per user.
func (s *AccountShard) runTier(userIDs []int, orderRate, tradeRate float64, tierName string, stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	conn, err := net.DialTimeout("tcp", s.Config.URL, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "account[%d/%s]: connect %s: %v\n", s.ShardID, tierName, s.Config.URL, err)
		return
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true) //nolint:errcheck
	}

	drainStop := &atomic.Bool{}
	go drainServer(conn, drainStop)
	defer drainStop.Store(true)

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
	buf := make([]byte, 0, headerLen+32+s.Config.PayloadSize)
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
			buf = buf[:0]
			if rng.Float64() < orderFrac {
				appendMsg(&buf, []byte(fmt.Sprintf("orders.%06d", uid)), payload)
				localOrders++
			} else {
				appendMsg(&buf, []byte(fmt.Sprintf("trades.%06d", uid)), payload)
				localTrades++
			}
			if _, err := conn.Write(buf); err != nil {
				return
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
}
