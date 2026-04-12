# open-wire-bench

Benchmark harness for [open-wire](https://github.com/kamalgs/open-wire) vs the
reference Go [nats-server](https://github.com/nats-io/nats-server) implementation.

Runs on a laptop (Nomad dev mode) and promotes to AWS or any cloud without changing
workload definitions. Results are reproducible: job specs and scenario parameters are
versioned in git.

## What it measures

- **Throughput** — messages/second at the broker and delivered to subscribers
- **Fan-out** — delivery rate as subscriber count scales
- **Latency** — end-to-end p50/p95/p99/p999 from publisher timestamp to subscriber receipt
- **Cluster routing** — cross-node delivery overhead in a 3-broker mesh
- **Binary protocol** — open-wire's custom binary framing vs standard NATS text protocol

Workloads model real financial messaging patterns: market data feed distribution and
order/fill request-reply.

## Quick start (local)

```bash
# Prerequisites: Nomad, Consul, Docker, Go 1.22+
./bootstrap/local.sh

# Run a scenario
./runs/bench.sh --scenario market-feed --duration 3m --target local

# Results in Grafana
open http://localhost:3000
```

## Stack

| Layer | Tool |
|-------|------|
| Orchestration | Nomad |
| Service discovery | Consul |
| Provisioning | Terraform |
| Package management | Nomad Pack |
| CI / GitOps | GitHub Actions |
| Metrics | Prometheus + Grafana |
| Logs | Loki |
| Registry | ghcr.io (+ Zot pull-through on AWS) |
| Simulators | Go (nats.go + binary protocol client) |

## Repository layout

```
bootstrap/      cluster bootstrap scripts (local, aws)
terraform/      infrastructure as code (modules + environments)
packs/          Nomad Pack definitions for each workload
envs/           per-environment variable files
runs/           benchmark execution scripts
simulators/     Go simulator binaries
  market-sim/   stock feed publisher
  market-sub/   subscriber + latency reporter
  order-sim/    order/fill request-reply
dashboards/     Grafana dashboard JSON (provisioned automatically)
docs/           architecture, scenarios, ADRs
```

## See also

- [Goals](docs/goals.md)
- [Architecture](docs/architecture.md)
- [Scenarios](docs/scenarios.md)
- [ADRs](docs/adr/)
