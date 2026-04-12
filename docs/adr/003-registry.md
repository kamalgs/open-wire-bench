# ADR-003: Container Registry

**Status:** Accepted
**Date:** 2026-04-12

## Context

Benchmark nodes need to pull ~5 container images (open-wire, nats-server, three
simulator binaries). The registry must be accessible from any cloud provider without
vendor-specific authentication or configuration.

## Decision

**ghcr.io** as the primary registry. **Zot** as a pull-through cache on cloud
environments.

### ghcr.io (source of truth)

GitHub Container Registry is cloud-agnostic — any node on any cloud pulls images
over HTTPS without provider-specific IAM or credential configuration. Images are
public (open-source project, no sensitive data in simulator binaries). GitHub Actions
pushes images on every commit to `main`; the image tag is the git SHA.

Zero infrastructure to operate. Fast iteration on a laptop: push commit, image
available globally within ~30 seconds.

### Zot (pull-through cache, cloud environments)

[Zot](https://zotregistry.dev) is a single ~20 MB Go binary implementing the OCI
distribution spec. Running as a Nomad task in the infra pool, it caches images from
ghcr.io within the VPC. Benchmark nodes pull from `registry.service.consul:5000`
regardless of environment; the Nomad variable `registry_host` points to Zot on cloud
and ghcr.io locally.

This eliminates cold-pull latency from benchmark startup and removes the dependency
on an external registry during a run.

### Harbor: considered and rejected

Harbor provides image scanning, RBAC, replication, and Notary. All are enterprise
registry concerns. For five benchmark images built from a trusted repository, these
features add operational overhead with no benefit. Harbor requires PostgreSQL, Redis,
and Nginx in addition to the registry itself — seven containers for a registry
storing five images.

### Cloud-native registries (ECR, GCR, ACR): rejected

Vendor-specific authentication (IAM roles, service accounts) would be required per
cloud provider, breaking the cloud-agnostic property.

## Consequences

**Positive:**
- Zero infrastructure locally; fast iteration
- Cloud runs have VPC-local pulls after first cache warm
- Adding a new cloud: set `registry_host` variable, no auth config changes
- Image provenance: every benchmark result references the ghcr.io SHA

**Negative:**
- Zot adds one Nomad task to the infra job; needs a volume for image storage
- First pull on a fresh cloud cluster goes to ghcr.io (subsequent pulls are cached)
