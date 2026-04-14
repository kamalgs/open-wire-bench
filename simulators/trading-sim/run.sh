#!/usr/bin/env bash
# run.sh — launch trading-sim processes for a scenario.
#
# Modes:
#   local   — run all shards on this machine (background processes)
#   ssh     — distribute shards across remote hosts via SSH
#   print   — print the commands without running them
#
# Usage:
#   ./run.sh local  scenarios/smoke.env
#   ./run.sh ssh    scenarios/mesh-10x.env host1 host2 host3
#   ./run.sh print  scenarios/mesh-10x.env
#
# The scenario env file must export these variables (all optional, defaults shown):
#
#   URL=localhost:4224          broker endpoint for this scenario
#   USERS=200                   total users
#   ALGO_USERS=20               algo users
#   SYMBOLS=500                 total market symbols
#   VISIBLE=20                  visible symbols per user
#   ALPHA=1.0                   Zipf exponent
#   SCREENS=                    screen spec (empty = default)
#   SCROLL_INTERVAL=10s         scroll interval
#   SCROLL_COUNT=5              symbols swapped per scroll
#   TICK_CLASSES=               tick class spec (empty = default)
#   ALGO_TIERS=                 algo tier spec (empty = default)
#   SIZE=128                    payload bytes
#   DURATION=60s                run duration
#
#   USER_SHARDS=1               number of user shard processes
#   MARKET_SHARDS=1             number of market shard processes
#   ACCOUNT_SHARDS=1            number of account shard processes
#
#   BINARY=bin/trading-sim      path to trading-sim binary (local mode)
#   REMOTE_BINARY=/opt/bench/bin/trading-sim  binary path on remote hosts (ssh mode)
#   RESULTS_DIR=results         directory for per-shard JSON output files

set -euo pipefail

MODE="${1:-local}"
SCENARIO="${2:-}"
shift 2 2>/dev/null || true
HOSTS=("$@")

# ── Defaults ──────────────────────────────────────────────────────────────────
URL="${URL:-localhost:4224}"
USERS="${USERS:-200}"
ALGO_USERS="${ALGO_USERS:-20}"
SYMBOLS="${SYMBOLS:-500}"
VISIBLE="${VISIBLE:-20}"
ALPHA="${ALPHA:-1.0}"
SCREENS="${SCREENS:-}"
SCROLL_INTERVAL="${SCROLL_INTERVAL:-10s}"
SCROLL_COUNT="${SCROLL_COUNT:-5}"
TICK_CLASSES="${TICK_CLASSES:-}"
ALGO_TIERS="${ALGO_TIERS:-}"
SIZE="${SIZE:-128}"
DURATION="${DURATION:-60s}"
PROTOCOL="${PROTOCOL:-binary}"
USER_SHARDS="${USER_SHARDS:-1}"
MARKET_SHARDS="${MARKET_SHARDS:-1}"
ACCOUNT_SHARDS="${ACCOUNT_SHARDS:-1}"
BINARY="${BINARY:-$(dirname "$0")/../../bin/trading-sim}"
REMOTE_BINARY="${REMOTE_BINARY:-/opt/bench/bin/trading-sim}"
RESULTS_DIR="${RESULTS_DIR:-$(dirname "$0")/../../results}"

# Load scenario file (overrides defaults above).
if [[ -n "${SCENARIO}" && -f "${SCENARIO}" ]]; then
    # shellcheck source=/dev/null
    source "${SCENARIO}"
fi

mkdir -p "${RESULTS_DIR}"

# ── Build the flags common to all shards ──────────────────────────────────────
common_flags() {
    echo -n "--url ${URL}"
    echo -n " --users ${USERS}"
    echo -n " --algo-users ${ALGO_USERS}"
    echo -n " --symbols ${SYMBOLS}"
    echo -n " --visible ${VISIBLE}"
    echo -n " --popularity-alpha ${ALPHA}"
    echo -n " --scroll-interval ${SCROLL_INTERVAL}"
    echo -n " --scroll-count ${SCROLL_COUNT}"
    echo -n " --size ${SIZE}"
    echo -n " --duration ${DURATION}"
    echo -n " --protocol ${PROTOCOL}"
    [[ -z "${SCREENS}" ]]       || echo -n " --screens \"${SCREENS}\""
    [[ -z "${TICK_CLASSES}" ]]  || echo -n " --tick-classes \"${TICK_CLASSES}\""
    [[ -z "${ALGO_TIERS}" ]]    || echo -n " --algo-tiers \"${ALGO_TIERS}\""
}

# ── Generate one command per shard ────────────────────────────────────────────
declare -a CMDS
declare -a LABELS

add_shards() {
    local role=$1
    local total=$2
    for (( i=0; i<total; i++ )); do
        local label="${role}-${i}"
        local out="${RESULTS_DIR}/${label}.json"
        local cmd
        cmd="${BINARY} --role ${role} --shard-id ${i} --shard-count ${total} $(common_flags) > ${out} 2>> ${RESULTS_DIR}/${label}.log"
        CMDS+=("$cmd")
        LABELS+=("$label")
    done
}

add_shards market  "${MARKET_SHARDS}"
add_shards accounts "${ACCOUNT_SHARDS}"
add_shards users   "${USER_SHARDS}"

# ── Execute ───────────────────────────────────────────────────────────────────
case "${MODE}" in

  print)
    for cmd in "${CMDS[@]}"; do
        echo "$cmd"
    done
    ;;

  local)
    echo "Launching ${#CMDS[@]} trading-sim processes locally..."
    PIDS=()
    for i in "${!CMDS[@]}"; do
        eval "${CMDS[$i]}" &
        PIDS+=($!)
        echo "  ${LABELS[$i]} pid=$!"
    done
    echo ""
    echo "Running for ${DURATION}. Results will appear in ${RESULTS_DIR}/"
    # Wait for all; ignore individual non-zero exits (process killed by signal).
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    echo ""
    echo "Done. Aggregate results with:"
    echo "  python3 aggregate.py ${RESULTS_DIR}/*.json"
    ;;

  ssh)
    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        echo "ssh mode requires at least one host argument" >&2
        exit 1
    fi
    NHOSTS=${#HOSTS[@]}
    echo "Distributing ${#CMDS[@]} shards across ${NHOSTS} hosts..."
    PIDS=()
    for i in "${!CMDS[@]}"; do
        host="${HOSTS[$((i % NHOSTS))]}"
        # Replace local binary path with remote path.
        remote_cmd="${CMDS[$i]/${BINARY}/${REMOTE_BINARY}}"
        # Send stdout/stderr back to local results dir.
        label="${LABELS[$i]}"
        echo "  ${label} → ${host}"
        ssh -o StrictHostKeyChecking=no "${host}" "${remote_cmd}" \
            > "${RESULTS_DIR}/${label}.json" 2>"${RESULTS_DIR}/${label}.log" &
        PIDS+=($!)
    done
    echo ""
    echo "Running for ${DURATION} on remote hosts. Waiting..."
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    echo ""
    echo "Done. Aggregate results with:"
    echo "  python3 aggregate.py ${RESULTS_DIR}/*.json"
    ;;

  *)
    echo "Unknown mode '${MODE}'. Use: local | ssh | print" >&2
    exit 1
    ;;
esac
