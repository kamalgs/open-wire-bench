// MarketShard publishes market-data ticks for the symbols owned by this shard.
//
// Symbols are split into tick classes (hot/warm/cool/cold) each at a different
// rate. The shard owns a modulo stripe of each class. One goroutine per class
// fires a single ticker at (class_rate × owned_count) msg/s and round-robins
// over the class's symbols — no per-symbol goroutines or timers needed.
package main

import (
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"open-wire-bench/internal/msg"
)

// MarketShard publishes market ticks for the symbols it owns.
type MarketShard struct {
	ShardID    int
	ShardCount int
	Config     *Config
	Published  atomic.Int64
}

// Run launches one goroutine per tick class (owned subset) and blocks until stop fires.
func (s *MarketShard) Run(stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	var inner sync.WaitGroup
	for _, cls := range s.Config.TickClasses {
		// Build the global index list for this class, then take the stripe.
		classSize := cls.End - cls.Start
		mine := ShardIndices(classSize, s.ShardID, s.ShardCount)
		if len(mine) == 0 {
			continue
		}
		// Resolve local-within-class indices to global symbol indices.
		symbols := make([][]byte, len(mine))
		for i, localIdx := range mine {
			globalIdx := cls.Start + localIdx
			symbols[i] = []byte(fmt.Sprintf("market.sym%04d", globalIdx))
		}
		inner.Add(1)
		if s.Config.Protocol == "nats" {
			go s.runNATSClass(symbols, cls.Rate, cls.Name, stop, &inner)
		} else {
			go s.runClass(symbols, cls.Rate, cls.Name, stop, &inner)
		}
	}
	inner.Wait()
}

// runClass owns one connection and publishes to symbols round-robin at ratePerSym ticks/s each.
func (s *MarketShard) runClass(symbols [][]byte, ratePerSym float64, className string, stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	conn, err := net.DialTimeout("tcp", s.Config.URL, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "market[%d/%s]: connect %s: %v\n", s.ShardID, className, s.Config.URL, err)
		return
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true) //nolint:errcheck
	}

	drainStop := &atomic.Bool{}
	go drainServer(conn, drainStop)
	defer drainStop.Store(true)

	n := len(symbols)
	// One tick per round-robin step: fire at n*ratePerSym ticks/s total.
	totalRate := float64(n) * ratePerSym
	interval := time.Duration(float64(time.Second) / totalRate)
	if interval < time.Millisecond {
		interval = time.Millisecond
	}

	payload := make([]byte, s.Config.PayloadSize)
	buf := make([]byte, 0, headerLen+16+s.Config.PayloadSize)
	var seq uint64
	symIdx := 0
	var localPub int64

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for !stop.Load() {
		select {
		case <-ticker.C:
			subj := symbols[symIdx]
			symIdx = (symIdx + 1) % n
			msg.Encode(payload, seq)
			seq++
			buf = buf[:0]
			appendMsg(&buf, subj, payload)
			if _, err := conn.Write(buf); err != nil {
				return
			}
			localPub++
			if localPub == 512 {
				s.Published.Add(localPub)
				localPub = 0
			}
		}
	}
	s.Published.Add(localPub)
}
