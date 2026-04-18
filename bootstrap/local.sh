#!/usr/bin/env bash
# bootstrap/local.sh — verify local environment is ready for benchmarking
#
# Nomad is expected to already be running (nomad agent -dev).
# This script checks prerequisites and prints connection info.

set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; exit 1; }

echo ""
echo "open-wire-bench — local environment check"
echo "========================================="

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo ""
echo "Prerequisites:"

command -v nomad  >/dev/null 2>&1 && ok "nomad $(nomad version | head -1)"  || fail "nomad not found"
command -v go     >/dev/null 2>&1 && ok "go $(go version)"                  || fail "go not found"
command -v docker >/dev/null 2>&1 && ok "docker available"                  || warn "docker not found (needed for observability job only)"
command -v curl   >/dev/null 2>&1 && ok "curl available"                    || fail "curl not found (required for setup)"

# ── Nomad agent ───────────────────────────────────────────────────────────────
echo ""
echo "Nomad:"
if nomad node status >/dev/null 2>&1; then
    NODES=$(nomad node status 2>/dev/null | grep -c "ready" || echo 0)
    ok "agent running, $NODES node(s) ready"
else
    fail "Nomad agent not running. Start with: nomad agent -dev -log-level=warn &"
fi

# ── Binaries (simulator + observability) ──────────────────────────────────────
echo ""
echo "Binaries (run 'make setup' if missing):"

BIN="$(pwd)/bin"
[[ -x "$BIN/open-wire"      ]] && ok "open-wire"      || warn "bin/open-wire missing  (run: make setup)"
[[ -x "$BIN/nats-server"    ]] && ok "nats-server"    || warn "bin/nats-server missing  (run: make setup)"
[[ -x "$BIN/market-sim"     ]] && ok "market-sim"     || warn "bin/market-sim missing  (run: make setup)"
[[ -x "$BIN/market-sub"     ]] && ok "market-sub"     || warn "bin/market-sub missing  (run: make setup)"
[[ -x "$BIN/prometheus"     ]] && ok "prometheus"     || warn "bin/prometheus missing  (run: make setup)"
[[ -x "$BIN/node_exporter"  ]] && ok "node_exporter"  || warn "bin/node_exporter missing  (run: make setup)"

# ── Running jobs ──────────────────────────────────────────────────────────────
echo ""
echo "Running jobs:"
JOBS=$(nomad job status 2>/dev/null | grep -v "^ID" | grep -v "^$" | awk '{print $1, $4}' || echo "")
if [[ -z "$JOBS" ]]; then
    warn "no jobs running — deploy with: make brokers observe"
else
    while IFS= read -r line; do ok "$line"; done <<< "$JOBS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Quick start:"
echo "  make setup          # download observability binaries + build simulators"
echo "  make brokers        # start open-wire :4222 and nats-server :4333"
echo "  make observe        # start Prometheus :9090 and node_exporter :9100"
echo "  make bench          # run market-feed scenario (30s)"
echo "  make stop           # stop all jobs"
echo ""
echo "Endpoints (once jobs are running):"
echo "  open-wire     nats://localhost:4222  metrics: http://localhost:9101/metrics"
echo "  nats-server   nats://localhost:4333  monitor: http://localhost:8333/varz"
echo "  Prometheus    http://localhost:9092"
echo "  node_exporter http://localhost:9100/metrics"
echo ""
