# ADR-001: Nomad over Kubernetes

**Status:** Accepted
**Date:** 2026-04-12

## Context

The benchmark harness needs to run on a laptop for fast iteration and on cloud VMs
for real measurements, without changing workload definitions between environments.

Kubernetes was the initial candidate given its ecosystem (kube-prometheus-stack,
ArgoCD, Helm). On review, it introduces overhead that directly contaminates benchmark
results:

- CNI plugins (Calico, Cilium, Flannel) add 10–50 µs per network hop
- kube-proxy iptables rules consume CPU on benchmark nodes
- kube-system DaemonSets (log collector, CNI agent, metrics-server) cause cache
  and memory bandwidth competition
- CPU limits engage the Linux CFS throttler, causing periodic pauses in latency
  histograms; removing limits means pods compete with system daemons

## Decision

Use **Nomad** for orchestration and **Consul** for service discovery.

- Processes use host networking by default — no CNI layer, direct NIC access
- No control plane components on benchmark nodes
- `nomad agent -dev` is the local environment: one binary, one command, functional
  multi-job scheduling in under a second
- The same HCL job spec runs locally and on AWS; environment differences are
  captured in `envs/*.vars` variable files
- Terraform has first-class Nomad support (`nomad_job` resource); the full stack
  is a single `terraform apply`
- **Nomad Pack** (HashiCorp's package manager for Nomad) provides parametrised,
  versioned job templates equivalent to Helm charts

GitOps is implemented via GitHub Actions: push to `main` triggers
`nomad-pack run` against the target cluster. No ArgoCD reconciliation daemon
is needed for a benchmark workload.

## Consequences

**Positive:**
- Network measurements reflect bare-metal performance, not CNI overhead
- Benchmark nodes have no competing system processes
- Local iteration: `nomad agent -dev` + `nomad-pack run` — no Docker-in-Docker,
  no kubeconfig, no cluster to tear down between experiments
- Entire stack (brokers + simulators + observability) captured in one Terraform plan

**Negative:**
- kube-prometheus-stack autodiscovery is not available; Prometheus scrape targets
  are configured via Consul service discovery (~30 lines of prometheus.yml)
- Smaller ecosystem than Kubernetes; fewer off-the-shelf integrations
- Nomad Pack is less mature than Helm

## Alternatives considered

**k3d (local) + EKS (AWS):** Adds CNI and kube-system overhead to measurements.
k3d's multi-node support uses Docker-in-Docker which further complicates host
networking. Rejected on measurement cleanliness grounds.

**Kubernetes with hostNetwork: true + dedicated node pools:** Mitigates CNI overhead
on broker pods but not on pub/sub pods. kube-system still runs on all nodes. More
configuration to achieve the same isolation Nomad provides by default.
