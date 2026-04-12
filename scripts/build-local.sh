#!/usr/bin/env bash
# scripts/build-local.sh — build all binaries for local development
#
# Builds open-wire from ../nats_rust, copies nats-server from PATH,
# and compiles Go simulator binaries into bin/.

set -euo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }

BIN="$(pwd)/bin"
mkdir -p "$BIN"

# ── open-wire ──────────────────────────────────────────────────────────────────
echo ""
echo "open-wire:"
OW_REPO="$(cd "$(dirname "$0")/../.." && pwd)/nats_rust"
if [[ -d "$OW_REPO" ]]; then
    cargo build --release --manifest-path "$OW_REPO/Cargo.toml" --quiet
    # Use install -b (backup) trick in case the binary is currently running under Nomad
    if ! cp "$OW_REPO/target/release/open-wire" "$BIN/open-wire" 2>/dev/null; then
        # Binary busy (Nomad task running) — replace via rename trick
        cp "$OW_REPO/target/release/open-wire" "$BIN/open-wire.new"
        mv "$BIN/open-wire.new" "$BIN/open-wire"
    fi
    ok "bin/open-wire ($(file "$BIN/open-wire" | awk -F, '{print $2}' | xargs))"
else
    warn "nats_rust repo not found at $OW_REPO — skipping open-wire build"
    warn "Place open-wire binary manually at bin/open-wire"
fi

# ── nats-server ────────────────────────────────────────────────────────────────
echo ""
echo "nats-server:"
if command -v nats-server >/dev/null 2>&1; then
    cp "$(command -v nats-server)" "$BIN/nats-server"
    ok "bin/nats-server ($(nats-server --version 2>&1 | head -1))"
else
    warn "nats-server not found in PATH — install with: go install github.com/nats-io/nats-server/v2@main"
fi

# ── simulators ────────────────────────────────────────────────────────────────
echo ""
echo "simulators:"
cd simulators
go mod tidy -e 2>/dev/null || true
go build -o "$BIN/market-sim" ./market-sim
ok "bin/market-sim"
go build -o "$BIN/market-sub" ./market-sub
ok "bin/market-sub"
echo ""
