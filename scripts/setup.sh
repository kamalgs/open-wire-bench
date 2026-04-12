#!/usr/bin/env bash
# scripts/setup.sh — download observability binaries and build Go simulators
#
# open-wire and nats-server run as Docker images (pulled by Nomad automatically).
# This script only downloads the observability stack and builds the simulators.
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
