// market.go — MarketShard publishes market-data ticks for the symbols it owns.
//
// Symbols are split into tick classes (hot/warm/cool/cold) each at a different
// rate. The shard owns a modulo stripe of each class. One goroutine per class
// fires a single ticker at (class_rate × owned_count) msg/s and round-robins
// over the class's symbols — no per-symbol goroutines or timers needed.
//
// Publishing is protocol-agnostic: dialPublisher returns a Publisher backed by
// either raw binary TCP or a NATS connection depending on Config.Protocol.
// symSeqs persists across reconnects so subscribers can observe the gap.
package main

import (
	"fmt"
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
		classSize := cls.End - cls.Start
		mine := ShardIndices(classSize, s.ShardID, s.ShardCount)
		if len(mine) == 0 {
			continue
		}
		symbols := make([][]byte, len(mine))
		for i, localIdx := range mine {
			globalIdx := cls.Start + localIdx
			symbols[i] = []byte(fmt.Sprintf("market.sym%04d", globalIdx))
		}
		inner.Add(1)
		go s.runClass(symbols, cls.Rate, cls.Name, stop, &inner)
	}
	inner.Wait()
}

// runClass publishes to symbols round-robin at ratePerSym ticks/s each.
// Reconnects on transport failure. symSeqs is allocated once and persists
// across reconnects so that subscribers can measure gaps during outages.
func (s *MarketShard) runClass(symbols [][]byte, ratePerSym float64, className string, stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	n := len(symbols)
	// One tick per round-robin step: fire at n*ratePerSym ticks/s total.
	totalRate := float64(n) * ratePerSym
	interval := time.Duration(float64(time.Second) / totalRate)
	if interval < time.Millisecond {
		interval = time.Millisecond
	}

	symSeqs := make([]uint64, n) // per-symbol seq counters; survive reconnects
	payload := make([]byte, s.Config.PayloadSize)
	symIdx := 0
	var localPub int64

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	name := fmt.Sprintf("market-%d/%s", s.ShardID, className)
	for !stop.Load() {
		pub := dialPublisher(s.Config, name, stop)
		if pub == nil {
			break // stop fired while connecting
		}

	connLoop:
		for !stop.Load() {
			select {
			case <-ticker.C:
				msg.Encode(payload, symSeqs[symIdx])
				symSeqs[symIdx]++
				if err := pub.Publish(string(symbols[symIdx]), payload); err != nil {
					break connLoop
				}
				symIdx = (symIdx + 1) % n
				localPub++
				if localPub == 512 {
					s.Published.Add(512)
					localPub = 0
				}
			}
		}

		pub.Flush()
		pub.Close()
		if !stop.Load() {
			time.Sleep(200 * time.Millisecond)
		}
	}
	s.Published.Add(localPub)
}
