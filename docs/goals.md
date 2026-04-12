# Goals

## Primary goal

Determine how open-wire compares to nats-server under realistic production workloads
at each stage of its development — not just on synthetic micro-benchmarks.

The existing single-machine benchmarks (throughput.sh) are fast feedback loops for
development but don't reflect real deployment conditions: separate publisher/subscriber
machines, real TCP across a network, a multi-broker cluster under mixed load.

## What "open-wire wins" means

Not just raw throughput. The comparison should be meaningful:

- **Throughput parity or better** at the broker under equivalent hardware
- **Latency parity or better** at p99 — tail latency matters more than median for
  financial messaging
- **Stable under sustained load** — no slow-consumer disconnect storms, no memory
  growth over a 10-minute run
- **Cluster routing correct** — delivered count matches published count across nodes

## Non-goals

- Absolute numbers. Numbers only make sense relative to the hardware they ran on.
  Every result is tagged with the instance type and git SHA.
- Benchmarking the NATS client library. Simulators use the same nats.go client against
  both servers. Any client overhead is identical.
- Benchmarking open-wire's binary protocol against nats-server. The binary protocol
  is open-wire-only; those runs measure the protocol overhead, not server comparison.

## Success criteria for the harness itself

- A developer can run a full local benchmark in under 5 minutes on a laptop
- Promoting from local to AWS requires changing one variable file, not the workload code
- Results from two runs at the same git SHA on the same hardware should be within 5%
- Every result references the open-wire git SHA and the nats-server version it ran against
