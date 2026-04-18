// stats.go — per-channel result structs, bucket data type, and heartbeat printer.
package main

import (
	"fmt"
	"os"
	"sync/atomic"
	"time"
)

// BucketData holds histogram bucket counts for accurate cross-shard percentile
// merging. Bounds are in µs; len(Counts) == len(Bounds)+1 (last bucket is
// the overflow above the highest bound).
type BucketData struct {
	Bounds []float64 `json:"bounds_us"`
	Counts []uint64  `json:"counts"`
}

// ChanResult holds throughput and latency statistics for one message channel.
type ChanResult struct {
	Published     int64       `json:"published,omitempty"`
	Received      int64       `json:"received,omitempty"`
	Gaps          int64       `json:"gaps,omitempty"`
	Dups          int64       `json:"dups,omitempty"`
	DeliveryRatio float64     `json:"delivery_ratio,omitempty"`
	MsgPerSec     float64     `json:"msg_per_sec"`
	P50Us         float64     `json:"p50_us,omitempty"`
	P99Us         float64     `json:"p99_us,omitempty"`
	P999Us        float64     `json:"p999_us,omitempty"`
	Histogram     *BucketData `json:"histogram,omitempty"`
}

// makeChanResult builds a ChanResult from counters and pre-computed latency values.
// gaps is the count of missed messages detected via sequence gaps; dups is the count
// of duplicate or out-of-order deliveries. p50/p99/p999 are in µs.
func makeChanResult(pub, rx, gaps, dups int64, elapsed, p50, p99, p999 float64, hist *BucketData) ChanResult {
	var deliveryRatio float64
	if gaps > 0 || dups > 0 {
		if expected := rx + gaps; expected > 0 {
			deliveryRatio = float64(rx) / float64(expected)
		}
	}
	return ChanResult{
		Published:     pub,
		Received:      rx,
		Gaps:          gaps,
		Dups:          dups,
		DeliveryRatio: deliveryRatio,
		MsgPerSec:     float64(rx) / elapsed,
		P50Us:         p50,
		P99Us:         p99,
		P999Us:        p999,
		Histogram:     hist,
	}
}

// Heartbeat prints a periodic status line to stderr so long-running shards
// remain observable without needing Prometheus. Runs until stop fires.
func Heartbeat(
	role string, shardID int, stop *atomic.Bool,
	marketRx, ordersRx, tradesRx *atomic.Int64,
	scrollEvents *atomic.Int64,
) {
	start := time.Now()
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	var prevRx int64
	for range ticker.C {
		if stop.Load() {
			return
		}
		rx := marketRx.Load()
		elapsed := time.Since(start).Seconds()
		rate := float64(rx-prevRx) / 10.0
		prevRx = rx
		fmt.Fprintf(os.Stderr,
			"[%s shard=%d] t=%.0fs mkt_rx=%dk ord_rx=%d trd_rx=%d scroll=%d rate=%.0f/s\n",
			role, shardID, elapsed,
			rx/1000, ordersRx.Load(), tradesRx.Load(),
			scrollEvents.Load(), rate,
		)
	}
}
