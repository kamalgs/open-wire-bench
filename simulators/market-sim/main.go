// market-sim publishes synthetic market-data messages at a controlled rate.
//
// Subjects: market.sym0000 … market.sym{N-1}
// Message format: [8B ts_ns][8B seq][padding] — see internal/msg
//
// Flags:
//
//	--url       NATS broker URL          (default: nats://localhost:4222)
//	--symbols   number of symbols        (default: 50)
//	--rate      total publish rate msg/s (default: 2000)
//	--size      message size in bytes    (default: 128, min 16)
//	--duration  how long to publish      (default: 30s)
//	--name      connection name          (default: market-sim)
//
// Prints a single JSON line on exit:
//
//	{"url":"…","published":N,"elapsed_s":F,"msg_per_sec":F}
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"

	"open-wire-bench/internal/msg"
)

func main() {
	url      := flag.String("url", nats.DefaultURL, "NATS broker URL")
	symbols  := flag.Int("symbols", 50, "number of symbols")
	rate     := flag.Int("rate", 2000, "total publish rate (msg/s)")
	size     := flag.Int("size", 128, "message size in bytes (min 16)")
	duration := flag.Duration("duration", 30*time.Second, "publish duration (0 = run until signal)")
	name     := flag.String("name", "market-sim", "NATS connection name")
	flag.Parse()

	if *size < msg.MinSize {
		fmt.Fprintf(os.Stderr, "size must be >= %d\n", msg.MinSize)
		os.Exit(1)
	}

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

	subjects := make([]string, *symbols)
	for i := range subjects {
		subjects[i] = fmt.Sprintf("market.sym%04d", i)
	}

	payload := make([]byte, *size) // zero-padded; Encode overwrites first 16 bytes

	var published atomic.Int64
	var seq uint64

	// Use a ticker at the target interval. Go timers have ~1ms resolution,
	// which is adequate for rates up to ~1000 msg/s. At higher rates the
	// ticker fires in batches and we publish multiple messages per tick.
	interval := time.Second / time.Duration(*rate)
	if interval < time.Millisecond {
		interval = time.Millisecond // floor: publish in batches below 1K msg/s
	}
	msgsPerTick := *rate / int(time.Second/interval)
	if msgsPerTick < 1 {
		msgsPerTick = 1
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var deadline <-chan time.Time
	if *duration > 0 {
		deadline = time.After(*duration)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	start := time.Now()

loop:
	for {
		select {
		case <-ticker.C:
			for i := 0; i < msgsPerTick; i++ {
				subj := subjects[rand.Intn(len(subjects))]
				msg.Encode(payload, seq)
				seq++
				if err := nc.Publish(subj, payload); err != nil {
					fmt.Fprintf(os.Stderr, "publish: %v\n", err)
					break loop
				}
				published.Add(1)
			}
		case <-deadline:
			break loop
		case <-sigCh:
			break loop
		}
	}

	_ = nc.Flush()

	elapsed := time.Since(start).Seconds()
	total := published.Load()

	out, _ := json.Marshal(map[string]any{
		"url":         *url,
		"published":   total,
		"elapsed_s":   elapsed,
		"msg_per_sec": float64(total) / elapsed,
	})
	fmt.Println(string(out))
}
