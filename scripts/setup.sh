#!/usr/bin/env bash
# scripts/setup.sh — download binaries and build Go simulators
#
# Downloads: nats-server, prometheus, node_exporter into bin/.
# Builds:    market-sim, market-sub from simulators/ into bin/.
#
# open-wire is NOT downloaded here. For local dev, copy the binary manually:
#   cp ../nats_rust/target/release/open-wire bin/
# For cloud, the Docker image is pulled automatically by Nomad.
#
# Versions are pinned in envs/versions.env.

set -euo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }

# shellcheck source=envs/versions.env
source envs/versions.env

BIN="$(pwd)/bin"
mkdir -p "$BIN"

ARCH="linux-amd64"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── nats-server (for brokers-dev.nomad raw_exec mode) ─────────────────────────
echo ""
echo "nats-server v${NATS_SERVER_VERSION}:"
if [[ -x "$BIN/nats-server" ]] && "$BIN/nats-server" --version 2>&1 | grep -q "${NATS_SERVER_VERSION}"; then
    ok "already at v${NATS_SERVER_VERSION}"
else
    curl -fsSL "https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VERSION}/nats-server-v${NATS_SERVER_VERSION}-${ARCH}.tar.gz" \
        | tar xz -C "$TMP" "nats-server-v${NATS_SERVER_VERSION}-${ARCH}/nats-server"
    mv "$TMP/nats-server-v${NATS_SERVER_VERSION}-${ARCH}/nats-server" "$BIN/nats-server"
    chmod +x "$BIN/nats-server"
    ok "downloaded bin/nats-server"
fi

# ── Prometheus ────────────────────────────────────────────────────────────────
echo ""
echo "Prometheus v${PROMETHEUS_VERSION}:"
if [[ -x "$BIN/prometheus" ]] && "$BIN/prometheus" --version 2>&1 | grep -q "$PROMETHEUS_VERSION"; then
    ok "already at v${PROMETHEUS_VERSION}"
else
    curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.${ARCH}.tar.gz" \
        | tar xz -C "$TMP" "prometheus-${PROMETHEUS_VERSION}.${ARCH}/prometheus"
    mv "$TMP/prometheus-${PROMETHEUS_VERSION}.${ARCH}/prometheus" "$BIN/prometheus"
    chmod +x "$BIN/prometheus"
    ok "downloaded bin/prometheus"
fi

# ── node_exporter ─────────────────────────────────────────────────────────────
echo ""
echo "node_exporter v${NODE_EXPORTER_VERSION}:"
if [[ -x "$BIN/node_exporter" ]] && "$BIN/node_exporter" --version 2>&1 | grep -q "$NODE_EXPORTER_VERSION"; then
    ok "already at v${NODE_EXPORTER_VERSION}"
else
    curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz" \
        | tar xz -C "$TMP" "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter"
    mv "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" "$BIN/node_exporter"
    chmod +x "$BIN/node_exporter"
    ok "downloaded bin/node_exporter"
fi

# ── Simulators ────────────────────────────────────────────────────────────────
echo ""
echo "Simulators:"
cd simulators
go build -o "$BIN/market-sim" ./market-sim
ok "bin/market-sim"
go build -o "$BIN/market-sub" ./market-sub
ok "bin/market-sub"
echo ""
