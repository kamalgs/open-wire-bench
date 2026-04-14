// nats_market.go — NATS-protocol publisher for MarketShard.
// Mirrors runClass() but uses nats.go instead of raw TCP + binary framing.
package main

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"

	natsgo "github.com/nats-io/nats.go"
	"open-wire-bench/internal/msg"
)

// runNATSClass publishes market ticks via the NATS protocol.
// One nats.Conn per tick class; symbols published round-robin at ratePerSym ticks/s.
func (s *MarketShard) runNATSClass(symbols [][]byte, ratePerSym float64, className string, stop *atomic.Bool, wg *sync.WaitGroup) {
	defer wg.Done()

	nc, err := natsgo.Connect(s.Config.URL,
		natsgo.Name(fmt.Sprintf("market-%d/%s", s.ShardID, className)),
		natsgo.MaxReconnects(-1),
		natsgo.ReconnectWait(200*time.Millisecond),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "market[%d/%s]: nats connect %s: %v\n", s.ShardID, className, s.Config.URL, err)
		return
	}
	defer nc.Close()

	n := len(symbols)
	totalRate := float64(n) * ratePerSym
	interval := time.Duration(float64(time.Second) / totalRate)
	if interval < time.Millisecond {
		interval = time.Millisecond
	}

	payload := make([]byte, s.Config.PayloadSize)
	var seq uint64
	symIdx := 0
	var localPub int64

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for !stop.Load() {
		select {
		case <-ticker.C:
			msg.Encode(payload, seq)
			seq++
			// nats.go copies payload before enqueuing — safe to reuse buffer.
			nc.Publish(string(symbols[symIdx]), payload) //nolint:errcheck
			symIdx = (symIdx + 1) % n
			localPub++
			if localPub == 512 {
				s.Published.Add(localPub)
				localPub = 0
			}
		}
	}
	s.Published.Add(localPub)
	nc.Flush() //nolint:errcheck
}
