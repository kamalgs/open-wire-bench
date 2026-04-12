// market-sub subscribes to market.> and reports throughput + latency percentiles.
//
// Flags:
//
//	--url       NATS broker URL   (default: nats://localhost:4222)
//	--duration  how long to run   (default: 35s)
//	--name      connection name   (default: market-sub)
//
// Prints a single JSON line on exit:
//
//	{"url":"…","received":N,"elapsed_s":F,"msg_per_sec":F,"p50_us":F,"p99_us":F}
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"os/signal"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"

	"open-wire-bench/internal/msg"
)

func main() {
	url      := flag.String("url", nats.DefaultURL, "NATS broker URL")
	duration := flag.Duration("duration", 35*time.Second, "subscribe duration (0 = run until signal)")
	name     := flag.String("name", "market-sub", "NATS connection name")
	flag.Parse()

	nc, err := nats.Connect(*url,
		nats.Name(*name),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(500*time.Millisecond),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect %s: %v\n", *url, err)
		os.Exit(1)
	}
	defer nc.Close()

	var received atomic.Int64
	var mu sync.Mutex
	var latencies []int64

	_, err = nc.Subscribe("market.>", func(m *nats.Msg) {
		received.Add(1)
		if lat, _, ok := msg.Decode(m.Data); ok && lat >= 0 {
			mu.Lock()
			latencies = append(latencies, lat)
			mu.Unlock()
		}
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "subscribe: %v\n", err)
		os.Exit(1)
	}

	var deadline <-chan time.Time
	if *duration > 0 {
		deadline = time.After(*duration)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	start := time.Now()
	select {
	case <-deadline:
	case <-sigCh:
	}

	elapsed := time.Since(start).Seconds()
	total := received.Load()

	mu.Lock()
	lats := make([]int64, len(latencies))
	copy(lats, latencies)
	mu.Unlock()

	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })

	out, _ := json.Marshal(map[string]any{
		"url":         *url,
		"received":    total,
		"elapsed_s":   elapsed,
		"msg_per_sec": float64(total) / elapsed,
		"p50_us":      float64(pct(lats, 50)) / 1000,
		"p99_us":      float64(pct(lats, 99)) / 1000,
	})
	fmt.Println(string(out))
}

// pct returns the p-th percentile value from a sorted slice of nanosecond latencies.
func pct(sorted []int64, p float64) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(float64(len(sorted))*p/100.0)) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}
