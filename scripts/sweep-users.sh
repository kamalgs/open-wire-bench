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
REPS=1
OW_SHARDS=""
OW_WORKERS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV="$2";         shift 2 ;;
    --protocols)  PROTOCOLS="$2";   shift 2 ;;
    --users)      USER_COUNTS="$2"; shift 2 ;;
    --duration)   DURATION="$2";    shift 2 ;;
    --reps)       REPS="$2";        shift 2 ;;
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
echo "users,rep,protocol,mkt_msg_per_sec,p50_ms,p99_ms,p999_ms,delivery_ratio,gaps,dups" > "$CSV"

collect_result() {
  local users="$1" rep="$2" proto="$3"
  local summary
  summary=$(ls -t "$REPO_ROOT/results/${ENV}-${proto}"-*-summary.json 2>/dev/null | head -1)
  [[ -z "$summary" ]] && { echo "  WARN: no summary for users=$users proto=$proto"; return; }
  python3 - "$summary" "$users" "$rep" "$proto" "$CSV" <<'PY'
import json, sys
f, users, rep, proto, csv = sys.argv[1:]
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
print(f"  rep{rep} {proto:10s}  {mps:>9,.0f} msg/s   p50={p50:5.1f}ms  p99={p99:7.1f}ms  p999={p999:8.1f}ms  delivery={ratio_str}  gaps={gaps}  dups={dups}")
with open(csv, "a") as out:
    out.write(f"{users},{rep},{proto},{mps:.0f},{p50:.2f},{p99:.2f},{p999:.2f},{ratio:.6f},{gaps},{dups}\n")
PY
}

IFS=',' read -ra USER_LIST <<< "$USER_COUNTS"
for users in "${USER_LIST[@]}"; do
  for rep in $(seq 1 "$REPS"); do
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  users=$users  rep=$rep/$REPS  protocols=$PROTOCOLS  duration=$DURATION"
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
        2>&1 | tee "$SWEEP_DIR/u${users}-rep${rep}.log"

    echo "── results (rep $rep) ────────────────────────────────────"
    IFS=',' read -ra PROTO_LIST <<< "$PROTOCOLS"
    for proto in "${PROTO_LIST[@]}"; do
      collect_result "$users" "$rep" "$proto"
    done
  done
done

echo ""
echo "══ Sweep complete ══════════════════════════════════════════════"
echo "  Results: $SWEEP_DIR"
echo "  Raw CSV: $CSV   (reps=$REPS per cell)"
echo ""
python3 - "$CSV" <<'PY'
import csv, math, sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
# key: (users, protocol) → list of metric dicts
groups = defaultdict(list)
for r in rows:
    groups[(r["users"], r["protocol"])].append(r)

def agg(vals):
    n = len(vals)
    if n == 0: return 0, 0
    mean = sum(vals) / n
    if n < 2: return mean, 0
    var = sum((v - mean) ** 2 for v in vals) / (n - 1)
    return mean, math.sqrt(var)

print(f"{'users':>5} {'protocol':10} {'msg/s (mean±σ)':>22} {'p50ms':>14} {'p99ms':>14} {'p999ms':>14} {'del%':>7}")
print("-" * 90)
for (users, proto) in sorted(groups.keys(), key=lambda k: (int(k[0]), k[1])):
    rs = groups[(users, proto)]
    mps_m, mps_s = agg([float(r["mkt_msg_per_sec"]) for r in rs])
    p50_m, p50_s = agg([float(r["p50_ms"]) for r in rs])
    p99_m, p99_s = agg([float(r["p99_ms"]) for r in rs])
    p999_m, p999_s = agg([float(r["p999_ms"]) for r in rs])
    ratio_m, _ = agg([float(r["delivery_ratio"]) for r in rs])
    gap_any = any(int(r["gaps"]) > 0 for r in rs)
    del_str = f"{ratio_m*100:.2f}%" if gap_any else "100%"
    print(f"{users:>5} {proto:10}  {mps_m:>9,.0f} ± {mps_s:>7,.0f}   {p50_m:>5.1f} ± {p50_s:>4.1f}   {p99_m:>5.1f} ± {p99_s:>4.1f}   {p999_m:>6.1f} ± {p999_s:>4.1f}   {del_str:>6}")
PY
