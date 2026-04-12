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

# ── Prerequisites ───────────────────────────────────────────────────��──────────
echo ""
echo "Prerequisites:"

command -v nomad >/dev/null 2>&1 && ok "nomad $(nomad version | head -1)" || fail "nomad not found"
command -v go    >/dev/null 2>&1 && ok "go $(go version)"                 || fail "go not found"
command -v docker>/dev/null 2>&1 && ok "docker available"                 || warn "docker not found (needed for observability job)"

# ── Nomad agent ────────────────────────────────────────────────────────────────
echo ""
echo "Nomad:"
if nomad node status >/dev/null 2>&1; then
    NODES=$(nomad node status 2>/dev/null | grep -c "ready" || echo 0)
    ok "agent running, $NODES node(s) ready"
else
    fail "Nomad agent not running. Start with: nomad agent -dev -log-level=warn &"
fi

# ── Binaries ──────────────────────────────────────────────────────────────────
echo ""
echo "Binaries (run 'make build' if missing):"

BIN="$(pwd)/bin"
[[ -x "$BIN/open-wire"    ]] && ok "open-wire"    || warn "bin/open-wire missing"
[[ -x "$BIN/nats-server"  ]] && ok "nats-server"  || warn "bin/nats-server missing"
[[ -x "$BIN/market-sim"   ]] && ok "market-sim"   || warn "bin/market-sim missing"
[[ -x "$BIN/market-sub"   ]] && ok "market-sub"   || warn "bin/market-sub missing"

# ── Running jobs ───────────────────────────────────────────────────────────────
echo ""
echo "Running jobs:"
JOBS=$(nomad job status 2>/dev/null | grep -v "^ID" | grep -v "^$" | awk '{print $1, $4}' || echo "none")
if [[ -z "$JOBS" ]]; then
    warn "no jobs running — deploy with: nomad job run jobs/brokers.nomad"
else
    while IFS= read -r line; do ok "$line"; done <<< "$JOBS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Quick start:"
echo "  make build                        # build all binaries"
echo "  nomad job run jobs/brokers.nomad  # start open-wire + nats-server"
echo "  make bench                        # run point-to-point scenario"
echo ""
echo "Endpoints (once brokers job is running):"
echo "  open-wire   nats://localhost:4222"
echo "  nats-server nats://localhost:4333"
echo ""
