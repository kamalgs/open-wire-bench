// trading-sim simulates a realistic stock-trading platform workload using the
// open-wire binary protocol.
//
// Three actor roles can run in a single process (--role all) or as separate
// processes distributed across machines (--role users|market|accounts). A
// modulo-stripe shard scheme (--shard-id / --shard-count) divides work without
// any runtime coordination — every shard's slice is fully determined by the
// global config flags.
//
// # Symbol model
//
// Symbols are implicitly ranked by popularity: index 0 is most popular, N-1
// is least. Tick rates decrease by class:
//
//	hot (top ~2%)  → 30 ticks/s per symbol   (e.g., AAPL, TSLA)
//	warm           → 8 ticks/s per symbol
//	cool           → 1 tick/s per symbol
//	cold           → 0.1 ticks/s per symbol
//
// # User model
//
// Each user has K_visible active subscriptions. Half come from their assigned
// screen (home/trending/midcap), biasing toward popular symbols. Half come from
// a Zipf-weighted sample of all symbols. Scroll events periodically swap some
// visible symbols for new Zipf-drawn ones. Algo users (uid < algo-users) also
// subscribe to orders.{uid} and trades.{uid}.
//
// # Metrics
//
// End-of-run latency percentiles are computed from OTel histogram bucket
// counts (no sample cap bias). Pass --metrics-port to expose a live Prometheus
// /metrics endpoint during the run.
//
// # Output
//
// One JSON line per process on stdout. Each includes per-channel published/
// received counts, latency percentiles, and histogram bucket data (for accurate
// cross-shard percentile merging via aggregate.py).
//
// # Usage examples
//
//	# Single process, all roles (smoke test)
//	trading-sim --role all --users 100 --symbols 200
//
//	# Publisher process (shard 0 of 2)
//	trading-sim --role market --shard-id 0 --shard-count 2 --url broker:4224
//
//	# User process (shard 3 of 8, 4000 total users)
//	trading-sim --role users --shard-id 3 --shard-count 8 --users 4000 --url broker:4224
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"open-wire-bench/internal/msg"
)

// Config holds global benchmark parameters that must be identical across all shards.
type Config struct {
	Symbols   int
	Users     int
	AlgoUsers int

	VisibleK int
	Alpha    float64
	Screens  []Screen

	ScrollInterval time.Duration
	ScrollCount    int

	TickClasses []TickClass
	AlgoTiers   []AlgoTier

	PayloadSize int
	URL         string
	Protocol    string // "binary" (default) or "nats"
}

func main() {
	role := flag.String("role", "all", "actor role: all | users | market | accounts")
	url := flag.String("url", "localhost:4224", "binary broker address (host:port)")
	symbols := flag.Int("symbols", 500, "total market symbols")
	users := flag.Int("users", 200, "total users")
	algoUsers := flag.Int("algo-users", 20, "users with private order/trade feeds (uid < N)")
	visibleK := flag.Int("visible", 20, "market symbols visible per user at one time")
	alpha := flag.Float64("popularity-alpha", 1.0, "Zipf exponent: higher = more concentration on popular symbols")
	screensSpec := flag.String("screens", "", `screen pools e.g. "home:0-49,trending:0-99,midcap:200-499"`)
	scrollIntvl := flag.Duration("scroll-interval", 10*time.Second, "time between scroll events per user")
	scrollCount := flag.Int("scroll-count", 5, "market symbols swapped per scroll event")
	tickSpec := flag.String("tick-classes", "", `tick rate tiers e.g. "hot:2%@30,warm:8%@8,cool:40%@1,cold:50%@0.1"`)
	algoSpec := flag.String("algo-tiers", "", `algo user tiers e.g. "hft:1%@2.0/1.0,mm:10%@0.5/0.3,retail:89%@0.05/0.02"`)
	size := flag.Int("size", 128, "message payload bytes (min 16)")
	duration := flag.Duration("duration", 60*time.Second, "simulation duration (0 = until SIGINT)")
	shardID := flag.Int("shard-id", 0, "0-indexed shard for this process")
	shardCount := flag.Int("shard-count", 1, "total shards of this role")
	metricsPort := flag.Int("metrics-port", 0, "expose Prometheus /metrics on this port (0 = disabled)")
	protocol := flag.String("protocol", "binary", `broker protocol: "binary" (open-wire binary port) or "nats" (standard NATS)`)
	flag.Parse()

	// ── Validate ───────────────────────────────────────────────────────────────
	if *protocol != "binary" && *protocol != "nats" {
		fmt.Fprintf(os.Stderr, "protocol must be binary or nats\n")
		os.Exit(1)
	}
	if *size < msg.MinSize {
		fmt.Fprintf(os.Stderr, "size must be >= %d\n", msg.MinSize)
		os.Exit(1)
	}
	if *shardID >= *shardCount {
		fmt.Fprintf(os.Stderr, "shard-id %d must be < shard-count %d\n", *shardID, *shardCount)
		os.Exit(1)
	}
	if *algoUsers > *users {
		*algoUsers = *users
	}

	screens, err := ParseScreens(*screensSpec, *symbols)
	if err != nil {
		fmt.Fprintln(os.Stderr, "screens:", err)
		os.Exit(1)
	}

	tickClasses, err := ParseTickClasses(*tickSpec, *symbols)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tick-classes:", err)
		os.Exit(1)
	}

	var algoTiers []AlgoTier
	if *algoUsers > 0 {
		algoTiers, err = ParseAlgoTiers(*algoSpec, *algoUsers)
		if err != nil {
			fmt.Fprintln(os.Stderr, "algo-tiers:", err)
			os.Exit(1)
		}
	}

	cfg := &Config{
		Symbols:        *symbols,
		Users:          *users,
		AlgoUsers:      *algoUsers,
		VisibleK:       *visibleK,
		Alpha:          *alpha,
		Screens:        screens,
		ScrollInterval: *scrollIntvl,
		ScrollCount:    *scrollCount,
		TickClasses:    tickClasses,
		AlgoTiers:      algoTiers,
		PayloadSize:    *size,
		URL:            *url,
		Protocol:       *protocol,
	}

	// ── OTel metrics ───────────────────────────────────────────────────────────
	otelState, err := SetupOTel(*metricsPort)
	if err != nil {
		fmt.Fprintln(os.Stderr, "otel:", err)
		os.Exit(1)
	}

	// ── Launch actors ──────────────────────────────────────────────────────────
	var stop atomic.Bool
	var wg sync.WaitGroup

	var userShard *UserShard
	var marketShard *MarketShard
	var accountShard *AccountShard

	if *role == "all" || *role == "users" {
		userShard = &UserShard{
			ShardID:    *shardID,
			ShardCount: *shardCount,
			Config:     cfg,
			Latency:    otelState.Latency,
			MktAttr:    otelState.MktAttr,
			OrdAttr:    otelState.OrdAttr,
			TrdAttr:    otelState.TrdAttr,
		}
		wg.Add(1)
		go userShard.Run(&stop, &wg)
		go Heartbeat("users", *shardID, &stop,
			&userShard.MarketRx, &userShard.OrdersRx, &userShard.TradesRx,
			&userShard.ScrollEvts)
	}

	if *role == "all" || *role == "market" {
		marketShard = &MarketShard{
			ShardID:    *shardID,
			ShardCount: *shardCount,
			Config:     cfg,
		}
		wg.Add(1)
		go marketShard.Run(&stop, &wg)
	}

	if *role == "all" || *role == "accounts" {
		accountShard = &AccountShard{
			ShardID:    *shardID,
			ShardCount: *shardCount,
			Config:     cfg,
		}
		wg.Add(1)
		go accountShard.Run(&stop, &wg)
	}

	if userShard == nil && marketShard == nil && accountShard == nil {
		fmt.Fprintf(os.Stderr, "unknown role %q — use: all | users | market | accounts\n", *role)
		os.Exit(1)
	}

	// Wire OTel observable counter pointers to the shard atomics.
	if marketShard != nil {
		otelState.MarketPub = &marketShard.Published
	}
	if userShard != nil {
		otelState.MarketRx = &userShard.MarketRx
		otelState.OrdersRx = &userShard.OrdersRx
		otelState.TradesRx = &userShard.TradesRx
		otelState.ScrollEvts = &userShard.ScrollEvts
	}
	if accountShard != nil {
		otelState.OrdersPub = &accountShard.OrdersPub
		otelState.TradesPub = &accountShard.TradesPub
	}

	// ── Wait for duration or signal ────────────────────────────────────────────
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	start := time.Now()
	var deadlineCh <-chan time.Time
	if *duration > 0 {
		deadlineCh = time.After(*duration)
	}
	select {
	case <-deadlineCh:
	case <-sigCh:
	}
	stop.Store(true)
	wg.Wait()
	elapsed := time.Since(start).Seconds()

	// ── Collect counters ───────────────────────────────────────────────────────
	var marketPub, ordersPub, tradesPub int64
	if marketShard != nil {
		marketPub = marketShard.Published.Load()
	}
	if accountShard != nil {
		ordersPub = accountShard.OrdersPub.Load()
		tradesPub = accountShard.TradesPub.Load()
	}

	var marketRx, ordersRx, tradesRx, scrollEvts int64
	if userShard != nil {
		marketRx = userShard.MarketRx.Load()
		ordersRx = userShard.OrdersRx.Load()
		tradesRx = userShard.TradesRx.Load()
		scrollEvts = userShard.ScrollEvts.Load()
	}

	// ── Snapshot OTel histograms ───────────────────────────────────────────────
	snap := otelState.Collect()
	mktP50, mktP99, mktP999, mktHist := ChannelResult(&snap, "market")
	ordP50, ordP99, ordP999, ordHist := ChannelResult(&snap, "orders")
	trdP50, trdP99, trdP999, trdHist := ChannelResult(&snap, "trades")

	var mktGaps, mktDups int64
	if userShard != nil {
		mktGaps = userShard.GapCount.Load()
		mktDups = userShard.DupCount.Load()
	}

	mkt := makeChanResult(marketPub, marketRx, mktGaps, mktDups, elapsed, mktP50, mktP99, mktP999, mktHist)
	ord := makeChanResult(ordersPub, ordersRx, 0, 0, elapsed, ordP50, ordP99, ordP999, ordHist)
	trd := makeChanResult(tradesPub, tradesRx, 0, 0, elapsed, trdP50, trdP99, trdP999, trdHist)

	// ── Print JSON ─────────────────────────────────────────────────────────────
	type SubsInfo struct {
		Users          int `json:"users"`
		AlgoUsers      int `json:"algo_users"`
		VisiblePerUser int `json:"visible_per_user"`
	}
	type Output struct {
		Role         string     `json:"role"`
		ShardID      int        `json:"shard_id"`
		ShardCount   int        `json:"shard_count"`
		URL          string     `json:"url"`
		ElapsedS     float64    `json:"elapsed_s"`
		Market       ChanResult `json:"market"`
		Orders       ChanResult `json:"orders"`
		Trades       ChanResult `json:"trades"`
		ScrollEvents int64      `json:"scroll_events"`
		Subs         SubsInfo   `json:"subscriptions"`
	}

	out := Output{
		Role:         *role,
		ShardID:      *shardID,
		ShardCount:   *shardCount,
		URL:          *url,
		ElapsedS:     elapsed,
		Market:       mkt,
		Orders:       ord,
		Trades:       trd,
		ScrollEvents: scrollEvts,
		Subs: SubsInfo{
			Users:          *users,
			AlgoUsers:      *algoUsers,
			VisiblePerUser: *visibleK,
		},
	}

	enc, _ := json.MarshalIndent(out, "", "  ")
	fmt.Println(string(enc))
}
