# CLAUDE.md — AI Agent Instructions for open-wire-bench

## Project overview

Benchmark harness for open-wire vs nats-server. Nomad-orchestrated, cloud-agnostic.
Runs locally (Nomad dev mode) and on AWS without changing workload definitions.

## Repository structure

```
bootstrap/      cluster bootstrap scripts
terraform/      infrastructure (modules/k3d, modules/eks; envs/local, envs/aws)
packs/          Nomad Pack job templates
  open-wire/    broker job
  nats-server/  reference broker job
  simulators/   market-sim, market-sub, order-sim
  observability/ prometheus, grafana, loki, node-exporter
envs/           per-environment variable files (local.vars, aws.vars)
runs/           benchmark execution scripts
simulators/     Go source for simulator binaries
  market-sim/
  market-sub/
  order-sim/
dashboards/     Grafana dashboard JSON (provisioned automatically)
docs/           goals, architecture, scenarios, ADRs
```

## Key design decisions (see ADRs for detail)

- **Nomad** over Kubernetes — no CNI overhead, host networking by default, cleaner measurements
- **Consul** for service discovery — native Nomad integration
- **Nomad Pack** for job templates — parametrised, versioned
- **ghcr.io** as registry — cloud-agnostic, zero infrastructure locally
- **Zot** as pull-through cache on cloud — VPC-local pulls
- **Prometheus + Grafana + Loki** — no Tempo, no Mimir
- **Go simulators** — nats.go for NATS protocol, custom binary client for open-wire binary protocol

## Simulator binary protocol

open-wire binary protocol: 9-byte header `op(u8) | subj_len(u16 LE) | repl_len(u16 LE) | pay_len(u32 LE)`
Ops: Ping(0x01) Pong(0x02) Msg(0x03) HMsg(0x04) Sub(0x05) Unsub(0x06)
Go client lives in `simulators/internal/binclient/`.

## Environment variable files

`envs/local.vars` and `envs/aws.vars` are the only files that differ between
environments. All Nomad Pack templates read from these. Do not hardcode values
in job specs.

## Build commands

```bash
# Build simulator binaries
cd simulators && go build ./...

# Build and push images
./scripts/build-push.sh --tag $(git rev-parse --short HEAD)

# Run locally
./bootstrap/local.sh
./runs/bench.sh --scenario market-feed --env local --duration 3m
```

## Code conventions

- Simulators: standard Go project layout, one binary per `cmd/` subdirectory
- Nomad Pack templates: HCL, variables declared in `variables.hcl`
- Terraform: modules in `terraform/modules/`, environments in `terraform/envs/`
- No hardcoded IPs or ports — always via Consul DNS (`service.consul`) or Nomad variables
- Results files: `results/{env}-{scenario}-{sha}-{timestamp}.json`
