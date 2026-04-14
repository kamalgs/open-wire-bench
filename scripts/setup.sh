#!/usr/bin/env bash
# scripts/setup.sh — download all broker + observability binaries, build simulators
#
# Downloads into bin/ (idempotent — skips if already at the right version):
#   open-wire      from github.com/kamalgs/open-wire releases
#   nats-server    from github.com/nats-io/nats-server releases
#   prometheus     from github.com/prometheus/prometheus releases
#   node_exporter  from github.com/prometheus/node_exporter releases
#
# Builds from source (simulators/ subdirectory, Go):
#   market-sim, market-sub
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

# ── open-wire ─────────────────────────────────────────────────────────────────
echo ""
echo "open-wire v${OPEN_WIRE_VERSION}:"
if [[ -x "$BIN/open-wire" ]] && "$BIN/open-wire" --version 2>&1 | grep -q "${OPEN_WIRE_VERSION}"; then
    ok "already at v${OPEN_WIRE_VERSION}"
else
    GH="https://github.com/kamalgs/open-wire/releases/download/v${OPEN_WIRE_VERSION}"
    if curl -fsSL --head "${GH}/open-wire-${ARCH}" >/dev/null 2>&1; then
        curl -fsSL -o "$BIN/open-wire" "${GH}/open-wire-${ARCH}"
        chmod +x "$BIN/open-wire"
        ok "downloaded bin/open-wire"
    else
        warn "GitHub release v${OPEN_WIRE_VERSION} not yet published."
        warn "For local dev, copy the binary manually:"
        warn "  cp ../nats_rust/target/release/open-wire bin/"
        warn "See scripts/build-image.sh for building a local dev image."
    fi
fi

# ── nats-server ───────────────────────────────────────────────────────────────
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
if [[ -x "$BIN/prometheus" ]] && "$BIN/prometheus" --version 2>&1 | grep -q "${PROMETHEUS_VERSION}"; then
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
if [[ -x "$BIN/node_exporter" ]] && "$BIN/node_exporter" --version 2>&1 | grep -q "${NODE_EXPORTER_VERSION}"; then
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
go build -o "$BIN/market-sim-bin" ./market-sim-bin
ok "bin/market-sim-bin"
go build -o "$BIN/market-sub-bin" ./market-sub-bin
ok "bin/market-sub-bin"
echo ""
