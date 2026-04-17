#!/usr/bin/env bash
# sweep-users.sh — run bench-trading.sh at multiple user counts and print a
# throughput / latency comparison table across all three broker protocols.
#
# Each user count is one bench-trading.sh invocation: cluster deploys once,
# all protocols run sequentially within it, then results are collected.
#
# Usage:
#   ./scripts/sweep-users.sh --env mini [--users 500,1000,2000,4000] \
#       [--protocols binary,ow-nats,nats] [--duration 60s] [--ow-shards 4]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV=mini
PROTOCOLS="binary,ow-nats,nats"
USER_COUNTS="500,1000,2000,4000"
DURATION=60s
OW_SHARDS=""
OW_WORKERS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV="$2";         shift 2 ;;
    --protocols)  PROTOCOLS="$2";   shift 2 ;;
    --users)      USER_COUNTS="$2"; shift 2 ;;
    --duration)   DURATION="$2";    shift 2 ;;
    --ow-shards)  OW_SHARDS="$2";   shift 2 ;;
    --ow-workers) OW_WORKERS="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SWEEP_DIR="$REPO_ROOT/results/sweep-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$SWEEP_DIR"

SHARDS_ARG=(); [[ -n "$OW_SHARDS" ]]  && SHARDS_ARG+=(--ow-shards "$OW_SHARDS")
WORKERS_ARG=(); [[ -n "$OW_WORKERS" ]] && WORKERS_ARG+=(--ow-workers "$OW_WORKERS")

CSV="$SWEEP_DIR/summary.csv"
echo "users,protocol,mkt_msg_per_sec,p50_ms,p99_ms,p999_ms,delivery_ratio,gaps,dups" > "$CSV"

collect_result() {
  local users="$1" proto="$2"
  local summary
  summary=$(ls -t "$REPO_ROOT/results/${ENV}-${proto}"-*-summary.json 2>/dev/null | head -1)
  [[ -z "$summary" ]] && { echo "  WARN: no summary for users=$users proto=$proto"; return; }
  python3 - "$summary" "$users" "$proto" "$CSV" <<'PY'
import json, sys
f, users, proto, csv = sys.argv[1:]
d = json.load(open(f))
m = d.get("market", {})
mps   = m.get("msg_per_sec", 0)
p50   = m.get("p50_us",  0) / 1000
p99   = m.get("p99_us",  0) / 1000
p999  = m.get("p999_us", 0) / 1000
ratio = m.get("delivery_ratio", 1.0)
gaps  = m.get("gaps", 0)
dups  = m.get("dups", 0)
ratio_str = f"{ratio*100:.2f}%" if (gaps or dups) else "100%"
print(f"  {proto:10s}  {mps:>9,.0f} msg/s   p50={p50:5.1f}ms  p99={p99:7.1f}ms  p999={p999:8.1f}ms  delivery={ratio_str}  gaps={gaps}  dups={dups}")
with open(csv, "a") as out:
    out.write(f"{users},{proto},{mps:.0f},{p50:.2f},{p99:.2f},{p999:.2f},{ratio:.6f},{gaps},{dups}\n")
PY
}

IFS=',' read -ra USER_LIST <<< "$USER_COUNTS"
for users in "${USER_LIST[@]}"; do
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  users=$users   protocols=$PROTOCOLS   duration=$DURATION"
  echo "══════════════════════════════════════════════════════════════"

  bash "$REPO_ROOT/scripts/bench-trading.sh" \
      --env "$ENV" \
      --users "$users" \
      --duration "$DURATION" \
      --protocols "$PROTOCOLS" \
      "${SHARDS_ARG[@]}" \
      "${WORKERS_ARG[@]}" \
      --no-scale-down \
      --skip-upload \
      2>&1 | tee "$SWEEP_DIR/u${users}.log"

  echo "── results ──────────────────────────────────────────────────"
  IFS=',' read -ra PROTO_LIST <<< "$PROTOCOLS"
  for proto in "${PROTO_LIST[@]}"; do
    collect_result "$users" "$proto"
  done
done

echo ""
echo "══ Sweep complete ══════════════════════════════════════════════"
echo "  Results: $SWEEP_DIR"
echo ""
echo "users | protocol   | msg/s       | p50ms | p99ms  | p999ms  | delivery | gaps"
echo "------|------------|-------------|-------|--------|---------|----------|-----"
tail -n +2 "$CSV" | awk -F',' '{
  proto=$2; mps=$3+0; p50=$4+0; p99=$5+0; p999=$6+0; ratio=$7+0; gaps=$8+0
  del = (gaps>0) ? sprintf("%.2f%%", ratio*100) : "100%"
  printf "%-5s | %-10s | %11s | %5s | %6s | %7s | %8s | %s\n", $1, proto, mps, p50, p99, p999, del, gaps
}'
