# ADR-004: Observability Stack

**Status:** Accepted
**Date:** 2026-04-12

## Context

The benchmark needs to capture metrics and logs during a run and present them in a
dashboard. Requirements:

- Metrics from open-wire (`/metrics` endpoint, already implemented)
- Metrics from simulators (delivery rate, latency histogram)
- Logs from simulators (for debugging drops and errors without SSH)
- Grafana dashboard showing all of the above in real time
- Dashboard definition versioned in git, provisioned automatically

## Decision

**Prometheus + Grafana + Loki**, deployed as a single Nomad job.

### Prometheus

Scrapes open-wire and simulator `/metrics` endpoints via Consul service discovery.
No manual scrape target configuration — Consul registers each service with a
`metrics_path` tag; Prometheus uses `consul_sd_configs`. Local Prometheus storage
is sufficient: benchmark runs last minutes to hours, not months.

### Grafana

Pre-configured via provisioning files mounted by Nomad's `template` stanza. The
dashboard JSON lives in `dashboards/bench.json` in the repository. No manual
dashboard import step. Available at `grafana.service.consul:3000`.

### Loki

Receives structured log output from simulator binaries (JSON lines). Useful for
diagnosing drop events, connection resets, and slow-consumer disconnects without
SSH-ing into individual nodes. Simulators log to stdout; Nomad's log collection
ships to Loki via Promtail (one Nomad task in the infra job).

### Components not included

**Tempo (distributed tracing):** The benchmark is not a production service. There
is no distributed trace to analyse — messages flow in one direction, latency is
measured end-to-end at the subscriber.

**Mimir / Thanos / VictoriaMetrics:** Long-term metrics storage. Benchmark runs
are short; local Prometheus retention (15 days default) is more than sufficient.
If results need to be preserved across runs, a `prometheus snapshot` is taken at
the end of each run and archived with the results JSON.

**kube-prometheus-stack:** Kubernetes-specific. Not applicable on Nomad.

## Consequences

**Positive:**
- Three lightweight processes; total idle memory ~150 MB
- Dashboard provisioned from git — no manual Grafana setup
- Loki centralises simulator logs without requiring SSH access during a run
- Consul service discovery handles Prometheus target registration automatically

**Negative:**
- Promtail adds one additional Nomad task per node (or one in the infra job with
  a volume mount for log directories — implementation decision)
- kube-prometheus-stack's node-level metrics (CPU, network per pod) are not
  available; replaced by node_exporter running as a Nomad system job
