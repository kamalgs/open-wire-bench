# Architecture

## Topology

```
  ┌──────────────────────────────────────────────────────┐
  │  Nomad cluster (1 node local / 7 nodes AWS)          │
  │                                                        │
  │  broker pool (tainted: role=broker)                   │
  │  ┌────────────┐  ┌────────────┐  ┌────────────┐      │
  │  │ open-wire  │  │ open-wire  │  │ open-wire  │      │
  │  │  :4222     │──│  :4222     │──│  :4222     │      │
  │  └────────────┘  └────────────┘  └────────────┘      │
  │         ╲               ╲               ╲             │
  │  ┌────────────┐  ┌────────────┐  ┌────────────┐      │
  │  │nats-server │  │nats-server │  │nats-server │      │
  │  │  :4333     │──│  :4333     │──│  :4333     │      │
  │  └────────────┘  └────────────┘  └────────────┘      │
  │                                                        │
  │  pub pool (tainted: role=pub)                         │
  │  ┌────────────┐  ┌────────────┐                       │
  │  │ market-sim │  │ order-sim  │                       │
  │  └────────────┘  └────────────┘                       │
  │                                                        │
  │  sub pool (tainted: role=sub)                         │
  │  ┌────────────┐  ┌────────────┐                       │
  │  │ market-sub │  │ order-sub  │                       │
  │  └────────────┘  └────────────┘                       │
  │                                                        │
  │  infra pool                                            │
  │  ┌────────────────────────────────────────────┐       │
  │  │  Prometheus  │  Grafana  │  Loki           │       │
  │  └────────────────────────────────────────────┘       │
  └──────────────────────────────────────────────────────┘
```

Both open-wire and nats-server run in parallel on the same broker nodes, on different
ports. A single benchmark run targets one or the other. This ensures identical hardware
conditions for all comparisons.

## Components

### Broker jobs

`open-wire` and `nats-server` run as Nomad system jobs on broker-tainted nodes.
Both use `network { mode = "host" }` — no CNI overlay, direct NIC access.
Consul health checks on the client port gate simulator startup.

### Simulators

Three Go binaries. Each connects with nats.go (or the binary protocol client for
open-wire binary runs) and publishes/subscribes according to a scenario definition.
Simulators embed a nanosecond timestamp in every message payload for end-to-end
latency measurement without a shared clock (publisher and subscriber on different nodes
require NTP sync or PTP — documented in scenarios.md).

| Binary | Role |
|--------|------|
| `market-sim` | Publishes stock quote and trade events at configurable rate |
| `market-sub` | Subscribes to market subjects, counts deliveries, records latency histogram |
| `order-sim` | Publishes orders and subscribes to fills (request-reply) |

### Observability

Prometheus scrapes open-wire's `/metrics` endpoint and both simulator binaries (which
expose a `/metrics` endpoint on a side port). Grafana is pre-configured with a
provisioned dashboard from `dashboards/bench.json`. Loki receives structured logs from
all simulators via Nomad's log shipper.

### Environment abstraction

The only environment-specific data lives in `envs/*.vars` files:

```
# envs/local.vars
broker_count    = 1
pub_rate        = 2000
symbols         = 50
msg_size        = 128
workers         = 1

# envs/aws.vars
broker_count    = 3
pub_rate        = 200000
symbols         = 1000
msg_size        = 128
workers         = 3
```

Job specs reference these as Nomad variables. Nothing else changes between environments.

## Data flow: market feed scenario

```
market-sim
  │  PUB market.AAPL.quote {bid,ask,ts_ns}
  │  PUB market.AAPL.trade {price,qty,ts_ns}
  ▼
open-wire / nats-server
  │  deliver to matching subscribers
  ▼
market-sub
  │  records (recv_ns - ts_ns) per message
  │  exposes histogram on :9091/metrics
  ▼
Prometheus ──► Grafana dashboard
```

## Local vs cloud differences

| Aspect | Local (dev mode) | AWS |
|--------|-----------------|-----|
| Nomad | `nomad agent -dev` | 7-node cluster (3 broker + 2 pub + 2 sub) |
| Networking | loopback | VPC private subnet, placement group for brokers |
| Broker count | 1 | 3 (full mesh) |
| Registry | ghcr.io direct | Zot pull-through in VPC |
| Node affinity | ignored | tainted node pools per role |
