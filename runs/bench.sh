#!/usr/bin/env bash
# runs/bench.sh — run a benchmark scenario against open-wire and nats-server
#
# Usage:
#   ./runs/bench.sh [--scenario SCENARIO] [--env ENV] [--duration DURATION]
#
# Scenarios: market-feed (default)
# Envs:      local (default), aws
# Duration:  e.g. 30s, 3m (default: from env vars file)
#
# Prerequisite: brokers job must be running (make brokers or nomad job run ...)
# Both brokers must be healthy before running this script.

set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; exit 1; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
SCENARIO="market-feed"
ENV="local"
DURATION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario) SCENARIO="$2"; shift 2 ;;
        --env)      ENV="$2";      shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Load env vars ─────────────────────────────────────────────────────────────
VARS_FILE="envs/${ENV}.vars"
[[ -f "$VARS_FILE" ]] || fail "env vars file not found: $VARS_FILE"

# Parse key = value lines (ignore comments and blank lines)
eval "$(grep -E '^[a-z_]+ *= *' "$VARS_FILE" | sed 's/ *= */=/' | sed 's/^/declare /')"

[[ -n "$DURATION" ]] || DURATION="${duration:-30s}"

# Convert duration to seconds for sleep (simple: strip trailing s/m)
dur_s="$DURATION"
if [[ "$DURATION" =~ ^([0-9]+)m$ ]]; then dur_s=$(( ${BASH_REMATCH[1]} * 60 )); fi
if [[ "$DURATION" =~ ^([0-9]+)s$ ]]; then dur_s="${BASH_REMATCH[1]}"; fi

BIN="$(pwd)/bin"
RESULTS_DIR="$(pwd)/results"
mkdir -p "$RESULTS_DIR"

TS=$(date +%s)
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "local")
RESULT_FILE="$RESULTS_DIR/${ENV}-${SCENARIO}-${SHA}-${TS}.json"

# ── Verify binaries ──────────────────────────────────────────────────────────
hdr "Scenario: $SCENARIO  env: $ENV  duration: $DURATION"
echo ""
echo "Verifying binaries..."

[[ -x "$BIN/market-sim" ]] || fail "bin/market-sim missing — run: make build"
[[ -x "$BIN/market-sub" ]] || fail "bin/market-sub missing — run: make build"
ok "market-sim, market-sub"

# ── Verify brokers ───────────────────────────────────────────────────────────
echo ""
echo "Checking brokers..."

wait_ready() {
    local url="$1" label="$2"
    for i in $(seq 1 20); do
        if "$BIN/market-sub" --url "$url" --duration 1s --name "healthcheck" >/dev/null 2>&1; then
            ok "$label ($url)"
            return 0
        fi
        sleep 0.5
    done
    fail "$label not reachable at $url (is the brokers job running?)"
}

wait_ready "nats://localhost:4222" "open-wire"
wait_ready "nats://localhost:4333" "nats-server"

# ── Run benchmark ─────────────────────────────────────────────────────────────
hdr "Running ${SCENARIO}..."

SUB_DUR=$(( dur_s + 5 ))s  # sub runs slightly longer to catch all in-flight msgs

OW_SUB_OUT=$(mktemp)
NS_SUB_OUT=$(mktemp)
OW_PUB_OUT=$(mktemp)
NS_PUB_OUT=$(mktemp)
trap "rm -f $OW_SUB_OUT $NS_SUB_OUT $OW_PUB_OUT $NS_PUB_OUT" EXIT

echo ""
echo "Starting subscribers (${SUB_DUR})..."

"$BIN/market-sub" \
    --url "nats://localhost:4222" \
    --duration "$SUB_DUR" \
    --name "bench-sub-ow" \
    > "$OW_SUB_OUT" 2>&1 &
OW_SUB_PID=$!

"$BIN/market-sub" \
    --url "nats://localhost:4333" \
    --duration "$SUB_DUR" \
    --name "bench-sub-ns" \
    > "$NS_SUB_OUT" 2>&1 &
NS_SUB_PID=$!

# Give subs a moment to connect and subscribe
sleep 1

echo "Starting publishers (${DURATION}, rate=${pub_rate} msg/s, symbols=${symbols}, size=${msg_size}B)..."

"$BIN/market-sim" \
    --url "nats://localhost:4222" \
    --symbols "$symbols" \
    --rate "$pub_rate" \
    --size "$msg_size" \
    --duration "$DURATION" \
    --name "bench-pub-ow" \
    > "$OW_PUB_OUT" 2>&1 &
OW_PUB_PID=$!

"$BIN/market-sim" \
    --url "nats://localhost:4333" \
    --symbols "$symbols" \
    --rate "$pub_rate" \
    --size "$msg_size" \
    --duration "$DURATION" \
    --name "bench-pub-ns" \
    > "$NS_PUB_OUT" 2>&1 &
NS_PUB_PID=$!

# Wait for publishers to finish
wait $OW_PUB_PID || warn "open-wire publisher exited with error"
wait $NS_PUB_PID || warn "nats-server publisher exited with error"

echo "Publishers done. Waiting for subscribers..."
wait $OW_SUB_PID || warn "open-wire subscriber exited with error"
wait $NS_SUB_PID || warn "nats-server subscriber exited with error"

# ── Parse results ─────────────────────────────────────────────────────────────
parse_field() {
    local file="$1" field="$2"
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field','?'))" < "$file" 2>/dev/null || echo "?"
}

OW_PUB_RPS=$(parse_field "$OW_PUB_OUT" msg_per_sec)
NS_PUB_RPS=$(parse_field "$NS_PUB_OUT" msg_per_sec)
OW_SUB_RPS=$(parse_field "$OW_SUB_OUT" msg_per_sec)
NS_SUB_RPS=$(parse_field "$NS_SUB_OUT" msg_per_sec)
OW_P50=$(parse_field "$OW_SUB_OUT" p50_us)
NS_P50=$(parse_field "$NS_SUB_OUT" p50_us)
OW_P99=$(parse_field "$OW_SUB_OUT" p99_us)
NS_P99=$(parse_field "$NS_SUB_OUT" p99_us)

# ── Print summary ─────────────────────────────────────────────────────────────
hdr "Results — ${SCENARIO} / ${ENV} / $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
printf "%-22s  %15s  %15s\n" "" "open-wire :4222" "nats-server :4333"
printf "%-22s  %15s  %15s\n" "$(printf '%0.s─' {1..22})" "$(printf '%0.s─' {1..15})" "$(printf '%0.s─' {1..15})"
printf "%-22s  %15s  %15s\n" "Published (msg/s)"  "$(printf '%.0f' "$OW_PUB_RPS" 2>/dev/null || echo $OW_PUB_RPS)"  "$(printf '%.0f' "$NS_PUB_RPS" 2>/dev/null || echo $NS_PUB_RPS)"
printf "%-22s  %15s  %15s\n" "Delivered (msg/s)"  "$(printf '%.0f' "$OW_SUB_RPS" 2>/dev/null || echo $OW_SUB_RPS)"  "$(printf '%.0f' "$NS_SUB_RPS" 2>/dev/null || echo $NS_SUB_RPS)"
printf "%-22s  %15s  %15s\n" "Latency p50 (µs)"   "$OW_P50"  "$NS_P50"
printf "%-22s  %15s  %15s\n" "Latency p99 (µs)"   "$OW_P99"  "$NS_P99"
echo ""

# ── Save full results ─────────────────────────────────────────────────────────
python3 - "$RESULT_FILE" <<'PYEOF'
import json, sys

result_file = sys.argv[1]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

import os
ow_pub = load(os.environ.get('OW_PUB_OUT',''))
ns_pub = load(os.environ.get('NS_PUB_OUT',''))
ow_sub = load(os.environ.get('OW_SUB_OUT',''))
ns_sub = load(os.environ.get('NS_SUB_OUT',''))

full = {
    "scenario": os.environ.get('SCENARIO'),
    "env":      os.environ.get('ENV'),
    "sha":      os.environ.get('SHA'),
    "open_wire":    {"pub": ow_pub, "sub": ow_sub},
    "nats_server":  {"pub": ns_pub, "sub": ns_sub},
}

with open(result_file, 'w') as f:
    json.dump(full, f, indent=2)
PYEOF

export OW_PUB_OUT NS_PUB_OUT OW_SUB_OUT NS_SUB_OUT SCENARIO ENV SHA
python3 - "$RESULT_FILE" <<'PYEOF' 2>/dev/null || true
import json, sys, os

result_file = sys.argv[1]

def load(path):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return {}

full = {
    "scenario":    os.environ.get("SCENARIO"),
    "env":         os.environ.get("ENV"),
    "sha":         os.environ.get("SHA"),
    "open_wire":   {"pub": load(os.environ["OW_PUB_OUT"]), "sub": load(os.environ["OW_SUB_OUT"])},
    "nats_server": {"pub": load(os.environ["NS_PUB_OUT"]), "sub": load(os.environ["NS_SUB_OUT"])},
}
with open(result_file, "w") as f:
    json.dump(full, f, indent=2)
PYEOF

ok "Results saved to $RESULT_FILE"
