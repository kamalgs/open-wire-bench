#!/usr/bin/env bash
# bench-cost.sh — query AWS Cost Explorer for spend tagged to a specific
# experiment. Requires one-time activation of the `Experiment` cost
# allocation tag in AWS Billing Console (Billing -> Cost Allocation Tags).
#
# Cost Explorer data has ~24-48h lag. Querying the same day as the bench
# typically returns $0.00 even if costs were incurred.
#
# Usage:
#   ./scripts/bench-cost.sh --experiment my-run-id
#   ./scripts/bench-cost.sh --experiment my-run-id --since 2026-04-15
#
# Defaults: since = 7 days ago, until = tomorrow.
set -euo pipefail

EXPERIMENT=""
SINCE=""
UNTIL=""
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiment) EXPERIMENT="$2"; shift 2 ;;
    --since)      SINCE="$2";      shift 2 ;;
    --until)      UNTIL="$2";      shift 2 ;;
    --region)     REGION="$2";     shift 2 ;;
    -h|--help) sed -n '1,15p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$EXPERIMENT" ]]; then
  echo "Missing --experiment <tag-value>" >&2
  exit 1
fi

: "${SINCE:=$(date -d '7 days ago' +%Y-%m-%d)}"
: "${UNTIL:=$(date -d 'tomorrow' +%Y-%m-%d)}"

echo "==> Cost for Experiment=$EXPERIMENT ($SINCE to $UNTIL)"

FILTER=$(cat <<JSON
{"Tags":{"Key":"Experiment","Values":["$EXPERIMENT"]}}
JSON
)

RAW=$(aws ce get-cost-and-usage \
    --region "$REGION" \
    --time-period "Start=$SINCE,End=$UNTIL" \
    --granularity DAILY \
    --metrics BlendedCost UsageQuantity \
    --filter "$FILTER" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json)

python3 - "$RAW" <<'PY'
import json, sys
d = json.loads(sys.argv[1])

svc_totals = {}
daily = []
for day in d.get("ResultsByTime", []):
    start = day["TimePeriod"]["Start"]
    day_total = 0.0
    for g in day.get("Groups", []):
        svc  = g["Keys"][0]
        cost = float(g["Metrics"]["BlendedCost"]["Amount"])
        svc_totals[svc] = svc_totals.get(svc, 0.0) + cost
        day_total += cost
    daily.append((start, day_total))

print()
print("  By service:")
if not svc_totals:
    print("    (no costs — tag may not be activated yet, or data lag; try again 24-48h after bench)")
else:
    for svc, cost in sorted(svc_totals.items(), key=lambda x: -x[1]):
        if cost > 0.001:
            print(f"    {cost:8.4f}  {svc}")
    total = sum(svc_totals.values())
    print(f"    {'-'*40}")
    print(f"    {total:8.4f}  TOTAL")

print()
print("  By day:")
for start, day_total in daily:
    if day_total > 0.001:
        print(f"    {start}  ${day_total:7.4f}")
PY
