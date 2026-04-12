# ADR-002: Simulator Design and Binary Protocol Client

**Status:** Accepted
**Date:** 2026-04-12

## Context

The benchmark needs publisher and subscriber processes for two protocols:

1. **NATS text protocol** — used by both open-wire and nats-server. The reference
   client library is nats.go (official, well-tested, used by the Go nats-server itself).
2. **Open-wire binary protocol** — 9-byte fixed header framing used by open-wire's
   dedicated binary port. No existing client library.

An existing benchmark tool, `nats bench` (part of the nats CLI), provides
pub/sub throughput measurement for the NATS protocol. The question was whether to
use it or write custom simulators.

## Decision

### NATS protocol: custom Go simulators, not `nats bench`

`nats bench` measures throughput well but cannot:
- Embed nanosecond timestamps for end-to-end latency histograms
- Model domain-specific workloads (market feed, order/fill)
- Expose Prometheus metrics for live dashboard visibility
- Ramp rate gradually (tests server behaviour under load growth, not just peak)

Custom Go simulators using nats.go provide all of these. The implementation
cost is low (~500 lines total across three binaries).

### Binary protocol: Go client implementation

The open-wire binary protocol is simple enough for a Go implementation:
- 9-byte fixed header: `op(u8) | subj_len(u16 LE) | repl_len(u16 LE) | pay_len(u32 LE)`
- Five operations: Ping, Pong, Msg, Sub, Unsub
- No state machine beyond the header decode

Estimated implementation: ~300 lines. Both the NATS and binary clients are in the
same Go module, so latency measurement and Prometheus export code is shared.

A Rust implementation was considered (reusing open-wire source). Rejected because:
- Go binary compiles to a single static binary, trivial to containerise
- The binary protocol is simple enough that a Go port is not a burden
- Keeping simulators in one language (Go) reduces context switching

### Simulator binaries

| Binary | Protocol | Role |
|--------|----------|------|
| `market-sim` | NATS or binary | Publisher: stock feed |
| `market-sub` | NATS or binary | Subscriber + latency reporter |
| `order-sim` | NATS | Publisher + subscriber: order/fill |

`--protocol nats|binary` flag selects the client. Binary protocol only connects
to open-wire; the flag is validated at startup.

### Load testing frameworks

**wrk** — HTTP only. Not applicable.

**k6** — JavaScript-based, primarily HTTP/WebSockets. A NATS extension exists
(xk6-nats) but it does not support pub/sub throughput measurement, only
request-reply. The abstraction is wrong for this use case.

**Gatling** — JVM-based, significant overhead, primarily HTTP.

**nats bench** — useful for quick sanity checks but lacks the features above.
May be included as an optional comparison data point.

Custom Go simulators are the right choice for this workload.

## Consequences

**Positive:**
- End-to-end latency measurement included from day one
- Both protocols use the same measurement infrastructure
- Ramp-up behaviour tests server stability under increasing load
- Prometheus metrics visible in Grafana during the run

**Negative:**
- Binary protocol client needs to be kept in sync with open-wire protocol changes
  (mitigated: protocol is intentionally stable and simple)
- Custom simulators require maintenance; `nats bench` would be zero maintenance
