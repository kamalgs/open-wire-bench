# Benchmark Scenarios

Each scenario runs against both open-wire and nats-server in sequence on the same
hardware. Results are tagged with `{server}:{git-sha}` for tracking over time.

## 1. Throughput ceiling (pub-only)

**What it tests:** raw message ingestion rate with no delivery work.
**Why it matters:** establishes the upper bound. If delivery scenarios approach this
ceiling, the server is delivery-bound, not ingestion-bound.

```
Publishers:  2  (one per broker node on AWS, one local)
Subscribers: 0  (no one subscribed — messages dropped at broker)
Subject:     bench.noop
Rate:        unlimited (as fast as publisher can push)
Duration:    60s steady state after 10s warmup
Message:     128B
```

## 2. Point-to-point

**What it tests:** basic pub/sub pipeline — one writer, one reader.

```
Publishers:  1
Subscribers: 1  (exact subject match)
Subject:     bench.p2p
Rate:        unlimited
Duration:    60s
Message:     128B, 1KB
```

## 3. Fan-out

**What it tests:** delivery throughput as subscriber count scales. Tests the server's
ability to fan out a single message to N connections without proportional CPU growth.

```
Publishers:  1
Subscribers: 5, 20, 100  (run separately, compare)
Subject:     bench.fanout
Rate:        unlimited
Duration:    60s per subscriber count
Message:     128B
```

## 4. Market feed

**What it tests:** realistic financial data distribution. High-frequency, many subjects,
wildcard subscriptions, mixed message sizes.

```
Publishers:  2 (market-sim instances, each half the symbol space)
Subscribers: 4 market-sub instances:
               - 2 × wildcard  SUB market.>         (all events)
               - 2 × wildcard  SUB market.*.quote   (quotes only)
Subjects:    market.{SYMBOL}.quote  64B  (bid, ask, bid_sz, ask_sz, ts_ns)
             market.{SYMBOL}.trade  128B (price, qty, side, exchange, ts_ns)
Symbols:     1000 (AWS) / 50 (local)
Rate:        ramp 0→target over 30s, hold for 5min
Target rate: 200K msg/s (AWS) / 5K msg/s (local)
```

**Metrics recorded:**
- Publisher send rate (msg/s)
- Subscriber receive rate per instance
- End-to-end latency histogram (p50/p95/p99/p999)
- Slow consumer disconnects (should be zero)

**Clock sync note:** publisher and subscriber on different nodes. NTP sync (chrony)
is configured on all nodes. Measured latency includes NTP error (~100µs); interpret
p50 with that in mind. p99 and disconnect rates are the meaningful signals.

## 5. Order/fill (request-reply)

**What it tests:** targeted delivery, low-volume high-criticality path. Models a
trading desk publishing orders and expecting fill confirmations.

```
Publishers:  1 order-sim (publishes orders, subscribes to fills)
Subscribers: 1 order-sim (subscribes to orders, publishes fills)
Subjects:    orders.{account}          128B  (order_id, symbol, qty, side, ts_ns)
             fills.{account}.{order_id} 128B (fill_price, qty, ts_ns)
Accounts:    10
Rate:        1K, 5K, 10K orders/s
Duration:    60s per rate
```

**Metrics recorded:**
- Round-trip latency (p50/p95/p99) — most important metric for this scenario
- Order delivery rate
- Fill delivery rate

## 6. Cluster routing

**What it tests:** cross-broker delivery overhead. All publishers connect to broker-0;
subscribers connect to broker-1 and broker-2. Every message must traverse a route
connection.

```
Topology:    3-node cluster (AWS only)
Publishers:  2 × market-sim → broker-0 only
Subscribers: 2 × market-sub → broker-1 and broker-2
Scenario:    market feed parameters (scenario 4)
```

Comparison point: same scenario on a single broker (no routing). The difference is
the cluster overhead.

## 7. Binary protocol (open-wire only)

**What it tests:** open-wire's custom binary protocol vs NATS text protocol on the
same server. Not a server comparison — nats-server doesn't support binary protocol.

Runs scenarios 1, 2, and 3 using the binary protocol Go client instead of nats.go.

```
Client:      Go binary protocol client (9-byte header framing)
Comparator:  same scenarios using nats.go against the same open-wire instance
```

**What it should show:** binary framing reduces per-message parsing overhead. The gap
between binary and NATS protocol throughput measures that overhead.

## Run matrix

| Scenario | open-wire | nats-server | open-wire binary |
|----------|-----------|-------------|-----------------|
| 1. pub-only | ✓ | ✓ | ✓ |
| 2. point-to-point | ✓ | ✓ | ✓ |
| 3. fan-out x5/20/100 | ✓ | ✓ | ✓ |
| 4. market feed | ✓ | ✓ | — |
| 5. order/fill | ✓ | ✓ | — |
| 6. cluster routing | ✓ | ✓ | — |
| 7. binary protocol | ✓ | — | ✓ |
