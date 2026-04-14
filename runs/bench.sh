#!/usr/bin/env bash
# runs/bench.sh — run a benchmark scenario against open-wire and nats-server
#
# Usage:
#   ./runs/bench.sh [--scenario SCENARIO] [--env ENV] [--duration DURATION]
#                   [--ow-url URL] [--nats-url URL] [--binary-url HOST:PORT]
#                   [--gateway-leaf-url HOST:PORT]
#
# Scenarios:
#   market-feed              NATS protocol — open-wire vs nats-server (default)
#   market-feed-binary       binary protocol — open-wire only, direct to cluster
#   market-feed-binary-leaf  binary protocol via local leaf relay: sim→leaf→gateway→hub
#
# Envs:      local (default), aws
# Duration:  e.g. 30s, 3m (default: from env vars file)
#
# Broker URLs default to localhost. Override for remote clusters:
#   --ow-url            nats://1.2.3.4:4222   open-wire NATS endpoint
#   --nats-url          nats://1.2.3.4:4333   nats-server endpoint
#   --binary-url        1.2.3.4:4224          open-wire binary endpoint (host:port)
#   --gateway-leaf-url  1.2.3.4:7422          gateway leaf acceptor (for binary-leaf scenario)
#
# Prerequisite: brokers job must be running on the target cluster.

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
OW_URL=""
NATS_URL=""
BINARY_URL=""
GATEWAY_LEAF_URL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario)          SCENARIO="$2";          shift 2 ;;
        --env)               ENV="$2";               shift 2 ;;
        --duration)          DURATION="$2";          shift 2 ;;
        --ow-url)            OW_URL="$2";            shift 2 ;;
        --nats-url)          NATS_URL="$2";          shift 2 ;;
        --binary-url)        BINARY_URL="$2";        shift 2 ;;
        --gateway-leaf-url)  GATEWAY_LEAF_URL="$2";  shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Load env vars ─────────────────────────────────────────────────────────────
VARS_FILE="envs/${ENV}.vars"
[[ -f "$VARS_FILE" ]] || fail "env vars file not found: $VARS_FILE"

# Parse key = value lines (ignore comments and blank lines)
eval "$(grep -E '^[a-z_]+ *= *' "$VARS_FILE" | sed 's/ *= */=/' | sed 's/^/declare /')"

[[ -n "$DURATION" ]] || DURATION="${duration:-30s}"

# Default broker URLs — override with --ow-url / --nats-url for remote clusters
[[ -n "$OW_URL"           ]] || OW_URL="nats://localhost:4222"
[[ -n "$NATS_URL"         ]] || NATS_URL="nats://localhost:4333"
[[ -n "$BINARY_URL"       ]] || BINARY_URL="localhost:4224"
[[ -n "$GATEWAY_LEAF_URL" ]] || GATEWAY_LEAF_URL="localhost:7422"

# Extract host:port for TCP health check
OW_HOST=$(echo "$OW_URL"   | sed 's|nats://||' | cut -d: -f1)
OW_PORT=$(echo "$OW_URL"   | sed 's|nats://||' | cut -d: -f2)
NS_HOST=$(echo "$NATS_URL" | sed 's|nats://||' | cut -d: -f1)
NS_PORT=$(echo "$NATS_URL" | sed 's|nats://||' | cut -d: -f2)
BIN_HOST=$(echo "$BINARY_URL" | cut -d: -f1)
BIN_PORT=$(echo "$BINARY_URL" | cut -d: -f2)

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

wait_ready() {
    local host="$1" port="$2" label="$3"
    for i in $(seq 1 30); do
        if bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
            ok "$label (${host}:${port})"
            return 0
        fi
        sleep 0.5
    done
    fail "$label not reachable at ${host}:${port} (is the brokers job running?)"
}

parse_field() {
    local file="$1" field="$2"
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field','?'))" < "$file" 2>/dev/null || echo "?"
}

# ── market-feed-binary-leaf scenario (3-hop: sim → local leaf → gateway → hub) ─
# Starts a local open-wire instance as a leaf pointing at --gateway-leaf-url,
# then runs the binary benchmark tools against localhost:4224.
# Topology: market-sim-bin → localhost:4224 → [local OW leaf] → gateway:7422 → hub.
if [[ "$SCENARIO" == "market-feed-binary-leaf" ]]; then
    [[ -x "$BIN/market-sim-bin" ]] || fail "bin/market-sim-bin missing — run: make setup"
    [[ -x "$BIN/market-sub-bin" ]] || fail "bin/market-sub-bin missing — run: make setup"
    [[ -x "$BIN/open-wire"      ]] || fail "bin/open-wire missing — run: make setup"
    ok "market-sim-bin, market-sub-bin, open-wire"

    GW_HOST=$(echo "$GATEWAY_LEAF_URL" | cut -d: -f1)
    GW_PORT=$(echo "$GATEWAY_LEAF_URL" | cut -d: -f2)
    echo ""
    echo "Checking gateway leaf acceptor..."
    wait_ready "$GW_HOST" "$GW_PORT" "gateway leaf"

    hdr "Starting local open-wire leaf → $GATEWAY_LEAF_URL ..."
    LOCAL_OW_LOG=$(mktemp)
    trap "rm -f $LOCAL_OW_LOG" EXIT
    "$BIN/open-wire" \
        --binary-port 4224 \
        --hub "nats://${GATEWAY_LEAF_URL}" \
        > "$LOCAL_OW_LOG" 2>&1 &
    LOCAL_OW_PID=$!
    # wait for local leaf to connect
    for i in $(seq 1 20); do
        if bash -c "echo > /dev/tcp/127.0.0.1/4224" 2>/dev/null; then break; fi
        sleep 0.5
    done
    bash -c "echo > /dev/tcp/127.0.0.1/4224" 2>/dev/null || fail "local open-wire leaf did not start"
    ok "local open-wire leaf ready (binary :4224)"

    # Now run exactly the same binary benchmark, but against localhost:4224
    BINARY_URL="127.0.0.1:4224"
    BIN_HOST="127.0.0.1"
    BIN_PORT="4224"

    hdr "Running ${SCENARIO}..."

    PUB_CONNS=8
    SUB_CONNS=8
    DRAIN_S=30
    SUB_DUR=$(( dur_s + DRAIN_S ))s
    OW_SUB_OUT=$(mktemp)
    OW_PUB_OUT=$(mktemp)
    trap "rm -f $OW_SUB_OUT $OW_PUB_OUT $LOCAL_OW_LOG; kill $LOCAL_OW_PID 2>/dev/null || true" EXIT

    echo ""
    BENCH_START=$(date +%s)
    echo "Starting subscribers (${SUB_DUR}, ${SUB_CONNS} conns × $((symbols / SUB_CONNS)) symbols each)..."

    "$BIN/market-sub-bin" \
        --url "$BINARY_URL" \
        --symbols "$symbols" \
        --conns "$SUB_CONNS" \
        --duration "$SUB_DUR" \
        > "$OW_SUB_OUT" 2>&1 &
    OW_SUB_PID=$!

    sleep 1

    echo "Starting publishers (${DURATION}, rate=${pub_rate} msg/s, symbols=${symbols}, size=${msg_size}B, ${PUB_CONNS} conns)..."

    "$BIN/market-sim-bin" \
        --url "$BINARY_URL" \
        --symbols "$symbols" \
        --conns "$PUB_CONNS" \
        --rate "$pub_rate" \
        --size "$msg_size" \
        --duration "$DURATION" \
        > "$OW_PUB_OUT" 2>&1 &
    OW_PUB_PID=$!

    wait $OW_PUB_PID || warn "publisher exited with error"
    echo "Publishers done. Waiting for subscribers..."
    wait $OW_SUB_PID || warn "subscriber exited with error"
    BENCH_END=$(date +%s)

    kill $LOCAL_OW_PID 2>/dev/null || true

    OW_PUB_RPS=$(parse_field "$OW_PUB_OUT" msg_per_sec)
    OW_SUB_RPS=$(parse_field "$OW_SUB_OUT" msg_per_sec)
    OW_P50=$(parse_field "$OW_SUB_OUT" p50_us)
    OW_P99=$(parse_field "$OW_SUB_OUT" p99_us)

    hdr "Results — ${SCENARIO} / ${ENV} / $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    printf "%-22s  %15s\n" "" "open-wire (leaf→gw)"
    printf "%-22s  %15s\n" "$(printf '%0.s─' {1..22})" "$(printf '%0.s─' {1..15})"
    printf "%-22s  %15s\n" "Published (msg/s)" "$(printf '%.0f' "$OW_PUB_RPS" 2>/dev/null || echo $OW_PUB_RPS)"
    printf "%-22s  %15s\n" "Delivered (msg/s)" "$(printf '%.0f' "$OW_SUB_RPS" 2>/dev/null || echo $OW_SUB_RPS)"
    printf "%-22s  %15s\n" "Latency p50 (µs)"  "$OW_P50"
    printf "%-22s  %15s\n" "Latency p99 (µs)"  "$OW_P99"
    echo ""

    export OW_PUB_OUT OW_SUB_OUT SCENARIO ENV SHA BENCH_START BENCH_END
    RESULT_FILE="$RESULTS_DIR/${ENV}-${SCENARIO}-${SHA}-${TS}.json"
    python3 - "$RESULT_FILE" <<'PYEOF' 2>/dev/null || true
import json, sys, os
def load(path):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return {}
full = {
    "scenario":    os.environ.get("SCENARIO"),
    "env":         os.environ.get("ENV"),
    "sha":         os.environ.get("SHA"),
    "bench_start": int(os.environ.get("BENCH_START", 0)),
    "bench_end":   int(os.environ.get("BENCH_END", 0)),
    "open_wire":   {"pub": load(os.environ["OW_PUB_OUT"]), "sub": load(os.environ["OW_SUB_OUT"])},
}
with open(sys.argv[1], "w") as f:
    json.dump(full, f, indent=2)
PYEOF
    ok "Results saved to $RESULT_FILE"
    exit 0
fi

# ── market-feed-binary scenario (open-wire only, binary protocol) ─────────────
if [[ "$SCENARIO" == "market-feed-binary" ]]; then
    [[ -x "$BIN/market-sim-bin" ]] || fail "bin/market-sim-bin missing — run: make setup"
    [[ -x "$BIN/market-sub-bin" ]] || fail "bin/market-sub-bin missing — run: make setup"
    ok "market-sim-bin, market-sub-bin"

    echo ""
    echo "Checking broker..."
    wait_ready "$BIN_HOST" "$BIN_PORT" "open-wire binary"

    hdr "Running ${SCENARIO}..."

    PUB_CONNS=8
    SUB_CONNS=8
    # Drain window: enough time for broker buffers to empty at delivered rate.
    # p99=5ms, buffers tiny at steady state — 30s drain is conservative.
    DRAIN_S=30
    SUB_DUR=$(( dur_s + DRAIN_S ))s
    OW_SUB_OUT=$(mktemp)
    OW_PUB_OUT=$(mktemp)
    trap "rm -f $OW_SUB_OUT $OW_PUB_OUT" EXIT

    echo ""
    BENCH_START=$(date +%s)
    echo "Starting subscribers (${SUB_DUR}, ${SUB_CONNS} conns × $((symbols / SUB_CONNS)) symbols each)..."

    "$BIN/market-sub-bin" \
        --url "$BINARY_URL" \
        --symbols "$symbols" \
        --conns "$SUB_CONNS" \
        --duration "$SUB_DUR" \
        > "$OW_SUB_OUT" 2>&1 &
    OW_SUB_PID=$!

    sleep 1

    echo "Starting publishers (${DURATION}, rate=${pub_rate} msg/s, symbols=${symbols}, size=${msg_size}B, ${PUB_CONNS} conns)..."

    "$BIN/market-sim-bin" \
        --url "$BINARY_URL" \
        --symbols "$symbols" \
        --conns "$PUB_CONNS" \
        --rate "$pub_rate" \
        --size "$msg_size" \
        --duration "$DURATION" \
        > "$OW_PUB_OUT" 2>&1 &
    OW_PUB_PID=$!

    wait $OW_PUB_PID || warn "open-wire publisher exited with error"
    echo "Publishers done. Waiting for subscribers..."
    wait $OW_SUB_PID || warn "open-wire subscriber exited with error"
    BENCH_END=$(date +%s)

    OW_PUB_RPS=$(parse_field "$OW_PUB_OUT" msg_per_sec)
    OW_SUB_RPS=$(parse_field "$OW_SUB_OUT" msg_per_sec)
    OW_P50=$(parse_field "$OW_SUB_OUT" p50_us)
    OW_P99=$(parse_field "$OW_SUB_OUT" p99_us)

    hdr "Results — ${SCENARIO} / ${ENV} / $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    printf "%-22s  %15s\n" "" "open-wire :${BIN_PORT}"
    printf "%-22s  %15s\n" "$(printf '%0.s─' {1..22})" "$(printf '%0.s─' {1..15})"
    printf "%-22s  %15s\n" "Published (msg/s)" "$(printf '%.0f' "$OW_PUB_RPS" 2>/dev/null || echo $OW_PUB_RPS)"
    printf "%-22s  %15s\n" "Delivered (msg/s)" "$(printf '%.0f' "$OW_SUB_RPS" 2>/dev/null || echo $OW_SUB_RPS)"
    printf "%-22s  %15s\n" "Latency p50 (µs)"  "$OW_P50"
    printf "%-22s  %15s\n" "Latency p99 (µs)"  "$OW_P99"
    echo ""

    export OW_PUB_OUT OW_SUB_OUT SCENARIO ENV SHA BENCH_START BENCH_END
    RESULT_FILE="$RESULTS_DIR/${ENV}-${SCENARIO}-${SHA}-${TS}.json"
    python3 - "$RESULT_FILE" <<'PYEOF' 2>/dev/null || true
import json, sys, os
def load(path):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return {}
full = {
    "scenario":    os.environ.get("SCENARIO"),
    "env":         os.environ.get("ENV"),
    "sha":         os.environ.get("SHA"),
    "bench_start": int(os.environ.get("BENCH_START", 0)),
    "bench_end":   int(os.environ.get("BENCH_END", 0)),
    "open_wire":   {"pub": load(os.environ["OW_PUB_OUT"]), "sub": load(os.environ["OW_SUB_OUT"])},
}
with open(sys.argv[1], "w") as f:
    json.dump(full, f, indent=2)
PYEOF
    ok "Results saved to $RESULT_FILE"
    exit 0
fi

# ── market-feed scenario (NATS protocol, open-wire vs nats-server) ────────────
[[ -x "$BIN/market-sim" ]] || fail "bin/market-sim missing — run: make setup"
[[ -x "$BIN/market-sub" ]] || fail "bin/market-sub missing — run: make setup"
ok "market-sim, market-sub"

# ── Verify brokers ───────────────────────────────────────────────────────────
echo ""
echo "Checking brokers..."

wait_ready "$OW_HOST" "$OW_PORT" "open-wire"
wait_ready "$NS_HOST" "$NS_PORT" "nats-server"

# ── Run benchmark ─────────────────────────────────────────────────────────────
hdr "Running ${SCENARIO}..."

SUB_DUR=$(( dur_s + 5 ))s  # sub runs slightly longer to catch all in-flight msgs

OW_SUB_OUT=$(mktemp)
NS_SUB_OUT=$(mktemp)
OW_PUB_OUT=$(mktemp)
NS_PUB_OUT=$(mktemp)
trap "rm -f $OW_SUB_OUT $NS_SUB_OUT $OW_PUB_OUT $NS_PUB_OUT" EXIT

echo ""
BENCH_START=$(date +%s)
echo "Starting subscribers (${SUB_DUR})..."

"$BIN/market-sub" \
    --url "$OW_URL" \
    --duration "$SUB_DUR" \
    --name "bench-sub-ow" \
    > "$OW_SUB_OUT" 2>&1 &
OW_SUB_PID=$!

"$BIN/market-sub" \
    --url "$NATS_URL" \
    --duration "$SUB_DUR" \
    --name "bench-sub-ns" \
    > "$NS_SUB_OUT" 2>&1 &
NS_SUB_PID=$!

# Give subs a moment to connect and subscribe
sleep 1

echo "Starting publishers (${DURATION}, rate=${pub_rate} msg/s, symbols=${symbols}, size=${msg_size}B)..."

"$BIN/market-sim" \
    --url "$OW_URL" \
    --symbols "$symbols" \
    --rate "$pub_rate" \
    --size "$msg_size" \
    --duration "$DURATION" \
    --name "bench-pub-ow" \
    > "$OW_PUB_OUT" 2>&1 &
OW_PUB_PID=$!

"$BIN/market-sim" \
    --url "$NATS_URL" \
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
BENCH_END=$(date +%s)

# ── Parse results ─────────────────────────────────────────────────────────────
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
export OW_PUB_OUT NS_PUB_OUT OW_SUB_OUT NS_SUB_OUT SCENARIO ENV SHA BENCH_START BENCH_END
python3 - "$RESULT_FILE" <<'PYEOF' 2>/dev/null || true
import json, sys, os, urllib.request

result_file = sys.argv[1]

def load(path):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return {}

def prom_query(expr, start, end):
    """Query Prometheus range; return list of (ts, value) or None if unavailable."""
    try:
        url = (f"http://localhost:9092/api/v1/query_range"
               f"?query={urllib.parse.quote(expr)}&start={start}&end={end}&step=5")
        with urllib.request.urlopen(url, timeout=3) as r:
            data = json.loads(r.read())
        return data["data"]["result"]
    except Exception:
        return None

import urllib.parse

start = int(os.environ.get("BENCH_START", 0))
end   = int(os.environ.get("BENCH_END", 0))

# Snapshot key Prometheus metrics for the run window (optional — skipped if Prometheus not running)
prom = {}
if start and end:
    cpu = prom_query('1 - avg(rate(node_cpu_seconds_total{mode="idle"}[30s]))', start, end)
    net_rx = prom_query('rate(node_network_receive_bytes_total{device!="lo"}[30s])', start, end)
    net_tx = prom_query('rate(node_network_transmit_bytes_total{device!="lo"}[30s])', start, end)
    if cpu is not None:
        prom["prometheus_window"] = {"start": start, "end": end}
        prom["cpu_util_samples"]  = [[v[0], float(v[1])] for r in (cpu or []) for v in r["values"]]
        prom["net_rx_samples"]    = [[v[0], float(v[1])] for r in (net_rx or []) for v in r["values"]]
        prom["net_tx_samples"]    = [[v[0], float(v[1])] for r in (net_tx or []) for v in r["values"]]

full = {
    "scenario":    os.environ.get("SCENARIO"),
    "env":         os.environ.get("ENV"),
    "sha":         os.environ.get("SHA"),
    "bench_start": start,
    "bench_end":   end,
    "open_wire":   {"pub": load(os.environ["OW_PUB_OUT"]), "sub": load(os.environ["OW_SUB_OUT"])},
    "nats_server": {"pub": load(os.environ["NS_PUB_OUT"]), "sub": load(os.environ["NS_SUB_OUT"])},
    **prom,
}
with open(result_file, "w") as f:
    json.dump(full, f, indent=2)
PYEOF

ok "Results saved to $RESULT_FILE"
