#!/usr/bin/env bash
# scripts/bench-trading.sh — Run the trading-sim bench against an AWS env.
#
# The env (micro / mini / full) determines which broker topology is used:
#
#   micro — single trading-broker node (open-wire + nats-server side-by-side)
#   mini  — hub mesh cluster (2 hub nodes, pub/sub hit hub NLB directly)
#   full  — leaf tier → hub mesh cluster (2 hops)
#
# Workflow:
#   1. Read broker URLs + ASG names from `terraform output`
#   2. Scale up trading-pub + trading-sub ASGs (and leaf ASG for `full`)
#   3. Wait for nodes to register with Nomad
#   4. Deploy the broker/cluster job for this env
#   5. For each protocol: run trading-sub + trading-pub, wait, collect
#      results via `nomad alloc logs` (no S3, no awscli)
#   6. Stop broker, scale ASGs back to 0
#
# Usage:
#   ./scripts/bench-trading.sh --env micro
#   ./scripts/bench-trading.sh --env mini --protocols binary --duration 60s
#   ./scripts/bench-trading.sh --env full --users 400 --symbols 1000
#
# Prereqs: aws CLI (on this machine only), nomad CLI with NOMAD_ADDR set or
#          reachable via Tailscale, trading-sim binary uploaded to the env's
#          results bucket (see upload-trading-sim.sh).
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
ENV=""
REGION="us-east-1"
DURATION="120s"
USERS=200
ALGO_USERS=20
SYMBOLS=500
VISIBLE=20
SIZE=128
OW_VERSION="0.1.0"
PROTOCOLS="binary,nats"
MARKET_SHARDS=2
ACCOUNT_SHARDS=1
USER_SHARDS=4
# Number of open-wire worker threads per hub/broker. Set to match the
# hub instance's vCPU count — oversubscribing workers vs cores on the
# 2-vCPU c5n.large tier cuts delivered throughput roughly in half.
OW_WORKERS=""
SCALE_DOWN=true
SKIP_UPLOAD=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)           ENV="$2";           shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --duration)      DURATION="$2";      shift 2 ;;
    --users)         USERS="$2";         shift 2 ;;
    --algo-users)    ALGO_USERS="$2";    shift 2 ;;
    --symbols)       SYMBOLS="$2";       shift 2 ;;
    --visible)       VISIBLE="$2";       shift 2 ;;
    --size)          SIZE="$2";          shift 2 ;;
    --ow-version)    OW_VERSION="$2";    shift 2 ;;
    --protocols)     PROTOCOLS="$2";     shift 2 ;;
    --market-shards) MARKET_SHARDS="$2"; shift 2 ;;
    --account-shards) ACCOUNT_SHARDS="$2"; shift 2 ;;
    --user-shards)   USER_SHARDS="$2";   shift 2 ;;
    --ow-workers)    OW_WORKERS="$2";    shift 2 ;;
    --no-scale-down) SCALE_DOWN=false;   shift ;;
    --skip-upload)   SKIP_UPLOAD=true;   shift ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENV" ]]; then
  echo "ERROR: --env is required (micro|mini|full)" >&2
  exit 1
fi
case "$ENV" in
  micro|mini|full) ;;
  *) echo "ERROR: --env must be one of: micro, mini, full" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TF_DIR="$REPO_ROOT/terraform/envs/$ENV"
RESULTS_DIR="$REPO_ROOT/results"
mkdir -p "$RESULTS_DIR"

if [[ ! -d "$TF_DIR" ]]; then
  echo "ERROR: terraform env not found: $TF_DIR" >&2
  exit 1
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

parse_duration() {
  local d="$1"
  if   [[ "$d" =~ ^([0-9]+)s$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$d" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]} * 60 ))
  else                                  echo 120
  fi
}

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

# ── Read env outputs from Terraform ───────────────────────────────────────────
log "Reading terraform outputs from envs/$ENV..."
RESULTS_BUCKET=$(tf_out results_bucket)
NOMAD_ADDR_OUT=$(tf_out nomad_addr)
TRADING_PUB_ASG=$(tf_out trading_pub_asg)
TRADING_SUB_ASG=$(tf_out trading_sub_asg)

export NOMAD_ADDR="${NOMAD_ADDR:-$NOMAD_ADDR_OUT}"
log "  NOMAD_ADDR=$NOMAD_ADDR"
log "  results bucket: $RESULTS_BUCKET"

# Env-specific outputs (broker URLs, optional leaf/hub data). All addresses
# are now IP-based via terraform outputs — no Tailscale hostnames anywhere.
case "$ENV" in
  micro)
    BROKER_BIN_URL=$(tf_out broker_binary_url)       # priv_ip:4224
    BROKER_NS_URL=$(tf_out broker_ns_url)            # nats://priv_ip:4333
    ;;
  mini)
    HUB_NLB=$(tf_out hub_nlb_dns)
    OW_HUB_SEEDS=$(tf_out ow_hub_seeds)              # priv_ip:6222,priv_ip:6222
    NS_HUB_ROUTES=$(tf_out ns_hub_routes)
    ;;
  full)
    HUB_NLB=$(tf_out hub_nlb_dns)
    OW_HUB_SEEDS=$(tf_out ow_hub_seeds)
    NS_HUB_ROUTES=$(tf_out ns_hub_routes)
    LEAF_NLB=$(tf_out leaf_nlb_dns)
    LEAF_ASG=$(tf_out leaf_asg_name)
    ;;
esac

SIM_BINARY="s3::https://s3.amazonaws.com/${RESULTS_BUCKET}/binaries/trading-sim"
OW_BINARY="s3::https://s3.amazonaws.com/${RESULTS_BUCKET}/binaries/open-wire-linux-amd64"

# Default open-wire worker count per env. Over-subscribing workers vs
# cores on the small c5n.large (2 vCPU) tier halves delivered throughput
# under load. For micro (trading-broker on c5.xlarge = 4 vCPU) the
# cluster job isn't used, so this only matters for mini / full.
if [[ -z "$OW_WORKERS" ]]; then
  case "$ENV" in
    mini|full) OW_WORKERS=2 ;;  # c5n.large temp sizing until on-demand quota bumps
    *)         OW_WORKERS=4 ;;
  esac
fi
log "  ow_workers=$OW_WORKERS"

# ── Helpers: broker URL per protocol ──────────────────────────────────────────
broker_url_for() {
  local proto="$1"
  case "$ENV" in
    micro)
      if [[ "$proto" == "binary" ]]; then echo "$BROKER_BIN_URL"
      else                                 echo "$BROKER_NS_URL"
      fi
      ;;
    mini|full)
      local endpoint
      if [[ "$ENV" == "mini" ]]; then endpoint="$HUB_NLB"; else endpoint="$LEAF_NLB"; fi
      if [[ "$proto" == "binary" ]]; then echo "${endpoint}:4224"
      else                                 echo "nats://${endpoint}:4333"
      fi
      ;;
  esac
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log "ERROR: bench-trading.sh failed (exit $rc)"
  fi
  if [[ "$SCALE_DOWN" == "true" ]]; then
    log "Scaling down ASGs..."
    aws autoscaling set-desired-capacity \
        --region "$REGION" \
        --auto-scaling-group-name "$TRADING_PUB_ASG" \
        --desired-capacity 0 2>/dev/null || true
    aws autoscaling set-desired-capacity \
        --region "$REGION" \
        --auto-scaling-group-name "$TRADING_SUB_ASG" \
        --desired-capacity 0 2>/dev/null || true
    if [[ "$ENV" == "full" && -n "${LEAF_ASG:-}" ]]; then
      aws autoscaling set-desired-capacity \
          --region "$REGION" \
          --auto-scaling-group-name "$LEAF_ASG" \
          --desired-capacity 0 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

# ── Step 1: Upload binary ─────────────────────────────────────────────────────
if [[ "$SKIP_UPLOAD" == "false" ]]; then
  log "Building and uploading trading-sim binary to $RESULTS_BUCKET..."
  bash "$SCRIPT_DIR/upload-trading-sim.sh" --bucket "$RESULTS_BUCKET" --region "$REGION"
fi

# ── Step 2: Scale up ASGs ─────────────────────────────────────────────────────
log "Scaling up trading-pub and trading-sub ASGs..."
aws autoscaling set-desired-capacity \
    --region "$REGION" \
    --auto-scaling-group-name "$TRADING_PUB_ASG" \
    --desired-capacity 1
aws autoscaling set-desired-capacity \
    --region "$REGION" \
    --auto-scaling-group-name "$TRADING_SUB_ASG" \
    --desired-capacity 1

EXPECTED_CLASSES=("trading-pub" "trading-sub")
if [[ "$ENV" == "full" ]]; then
  log "Scaling up leaf ASG..."
  aws autoscaling set-desired-capacity \
      --region "$REGION" \
      --auto-scaling-group-name "$LEAF_ASG" \
      --desired-capacity 1
  EXPECTED_CLASSES+=("leaf")
fi

# ── Step 3: Wait for Nomad node registration ──────────────────────────────────
log "Waiting for nodes to register with Nomad..."
for class in "${EXPECTED_CLASSES[@]}"; do
  attempts=0
  while true; do
    count=$(nomad node status 2>/dev/null \
              | awk -v c="$class" '$5==c && $8=="ready"' \
              | wc -l)
    if [[ "$count" -ge 1 ]]; then
      log "  $class: $count node(s) ready"
      break
    fi
    attempts=$((attempts + 1))
    if [[ $attempts -ge 30 ]]; then
      log "ERROR: $class node never became ready after 5 min" >&2
      exit 1
    fi
    sleep 10
  done
done

# ── Step 4: Deploy the broker/cluster job for this env ────────────────────────
log "Deploying broker topology for env=$ENV..."

case "$ENV" in
  micro)
    nomad job run \
        -var="ow_version=${OW_VERSION}" \
        -var="ow_binary=${OW_BINARY}" \
        -var="ow_workers=${OW_WORKERS}" \
        "$REPO_ROOT/jobs/trading-broker.nomad"
    BROKER_JOBS=("trading-broker")
    ;;
  mini)
    nomad job run \
        -var="ow_version=${OW_VERSION}" \
        -var="ow_binary=${OW_BINARY}" \
        -var="ow_workers=${OW_WORKERS}" \
        -var="ow_hub_seeds=${OW_HUB_SEEDS}" \
        -var="ns_hub_routes=${NS_HUB_ROUTES}" \
        "$REPO_ROOT/jobs/cluster.nomad"
    BROKER_JOBS=("cluster")
    ;;
  full)
    nomad job run \
        -var="ow_version=${OW_VERSION}" \
        -var="ow_binary=${OW_BINARY}" \
        -var="ow_workers=${OW_WORKERS}" \
        -var="ow_hub_seeds=${OW_HUB_SEEDS}" \
        -var="ns_hub_routes=${NS_HUB_ROUTES}" \
        "$REPO_ROOT/jobs/cluster.nomad"
    nomad job run \
        -var="ow_version=${OW_VERSION}" \
        -var="ow_binary=${OW_BINARY}" \
        -var="ow_workers=${OW_WORKERS}" \
        -var="ow_hub_url=nats://${HUB_NLB}:7422" \
        -var="ns_hub_urls=nats://${HUB_NLB}:7333" \
        "$REPO_ROOT/jobs/leaf.nomad"
    BROKER_JOBS=("cluster" "leaf")
    ;;
esac

# Wait for NLB target health to converge after the cluster (re)deploy.
# A fixed sleep isn't enough: NLB needs ~20-30s of consecutive successful
# TCP health checks before a target becomes healthy, and bench connections
# that land during the window get black-holed. Poll until both hub targets
# report healthy on the open-wire binary port (4224).
#
# Micro env has no hub NLB (broker is directly reachable via private IP),
# so this is a no-op there. For full env we'd also wait on the leaf NLB.
wait_for_nlb_health() {
  local env="$1"
  [[ "$env" == "micro" ]] && return 0
  # mini / full: wait on the hub ow-binary target group
  local tg_arn
  tg_arn=$(aws elbv2 describe-target-groups \
      --region "$REGION" \
      --names "$(cluster_name_for_env "$env")-hub-ow-bin" \
      --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null) || return 0
  local deadline=$((SECONDS + 90))
  log "  Waiting for hub NLB ow-binary targets to become healthy..."
  while true; do
    # `--output text` uses tab separators. Count tokens vs healthy tokens.
    # Word-level match (not substring) so "unhealthy" doesn't count as healthy.
    local states total healthy_count token
    states=$(aws elbv2 describe-target-health --region "$REGION" \
        --target-group-arn "$tg_arn" \
        --query "TargetHealthDescriptions[*].TargetHealth.State" --output text 2>/dev/null)
    total=0
    healthy_count=0
    # shellcheck disable=SC2086
    for token in $states; do
      total=$((total + 1))
      [[ "$token" == "healthy" ]] && healthy_count=$((healthy_count + 1))
    done
    if [[ "$total" -gt 0 && "$healthy_count" -eq "$total" ]]; then
      log "  NLB targets healthy ($healthy_count/$total): $states"
      return 0
    fi
    if [[ $SECONDS -ge $deadline ]]; then
      log "  WARNING: NLB targets still not healthy after 90s: $states"
      return 0
    fi
    sleep 3
  done
}

# Clusters are named ${cluster_name}-${env}; derive the target-group name
# prefix from tfvars so we don't rely on knowing the cluster_name value.
cluster_name_for_env() {
  case "$1" in
    micro) echo "open-wire-bench-micro" ;;
    mini)  echo "open-wire-bench-min" ;;   # TG names use 19-char substring
    full)  echo "open-wire-bench-ful" ;;
  esac
}

wait_for_nlb_health "$ENV"

# ── Step 5: Run bench for each protocol ───────────────────────────────────────
IFS=',' read -ra PROTO_LIST <<< "$PROTOCOLS"

for proto in "${PROTO_LIST[@]}"; do
  RUN_ID="${ENV}-${proto}-$(date +%Y%m%dT%H%M%S)"
  BROKER_URL=$(broker_url_for "$proto")

  log "=== env=$ENV protocol=$proto ==="
  log "    broker_url: $BROKER_URL"
  log "    run_id:     $RUN_ID"

  # Stop any leftover jobs from a previous run
  nomad job stop -purge trading-pub 2>/dev/null || true
  nomad job stop -purge trading-sub 2>/dev/null || true
  sleep 2

  # Start subscribers first (5s head start to subscribe before pub publishes)
  log "  Starting trading-sub..."
  nomad job run \
      -var="broker_url=${BROKER_URL}" \
      -var="protocol=${proto}" \
      -var="sim_binary=${SIM_BINARY}" \
      -var="users=${USERS}" \
      -var="algo_users=${ALGO_USERS}" \
      -var="symbols=${SYMBOLS}" \
      -var="visible=${VISIBLE}" \
      -var="size=${SIZE}" \
      -var="duration=${DURATION}" \
      -var="user_shards=${USER_SHARDS}" \
      "$REPO_ROOT/jobs/trading-sub.nomad"

  sleep 5

  log "  Starting trading-pub..."
  nomad job run \
      -var="broker_url=${BROKER_URL}" \
      -var="protocol=${proto}" \
      -var="sim_binary=${SIM_BINARY}" \
      -var="users=${USERS}" \
      -var="algo_users=${ALGO_USERS}" \
      -var="symbols=${SYMBOLS}" \
      -var="visible=${VISIBLE}" \
      -var="size=${SIZE}" \
      -var="duration=${DURATION}" \
      -var="market_shards=${MARKET_SHARDS}" \
      -var="account_shards=${ACCOUNT_SHARDS}" \
      "$REPO_ROOT/jobs/trading-pub.nomad"

  WAIT_SECS=$(parse_duration "$DURATION")
  WAIT_TOTAL=$((WAIT_SECS + 90))
  log "  Waiting up to ${WAIT_TOTAL}s for both batch jobs to complete..."

  deadline=$((SECONDS + WAIT_TOTAL))
  while true; do
    pub_status=$(nomad job status trading-pub 2>/dev/null \
                   | awk '/^Status/{print $3}' || echo "unknown")
    sub_status=$(nomad job status trading-sub 2>/dev/null \
                   | awk '/^Status/{print $3}' || echo "unknown")
    if [[ "$pub_status" == "dead" && "$sub_status" == "dead" ]]; then
      log "  Both batch jobs completed"
      break
    fi
    if [[ $SECONDS -ge $deadline ]]; then
      log "WARNING: jobs did not finish within ${WAIT_TOTAL}s — proceeding anyway"
      break
    fi
    sleep 15
  done

  # ── Collect results via `nomad alloc logs` ──────────────────────────────────
  OUT_DIR="$RESULTS_DIR/${RUN_ID}"
  mkdir -p "$OUT_DIR"
  log "  Collecting results to $OUT_DIR..."

  collect_allocs() {
    local job="$1" role="$2"
    # List completed allocs (one per task group / shard)
    nomad job allocs -json "$job" 2>/dev/null \
        | python3 -c '
import json, sys
for a in json.load(sys.stdin):
    if a.get("ClientStatus") == "complete":
        print(a["ID"], a.get("TaskGroup", ""))
' \
        | while read -r alloc_id group; do
      out="$OUT_DIR/${role}-${group}-${alloc_id:0:8}.json"
      if nomad alloc logs "$alloc_id" shard > "$out" 2>/dev/null; then
        # Verify the last non-empty line parses as JSON (trading-sim prints the
        # result as a single JSON line at the end of stdout).
        if [[ -s "$out" ]] && awk 'NF' "$out" | tail -1 | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
          echo "    $out ($(wc -c < "$out") bytes)"
        else
          echo "    WARN: $out last line is not valid JSON"
        fi
      else
        echo "    WARN: failed to get logs for $alloc_id"
      fi
    done
  }

  collect_allocs trading-pub pub
  collect_allocs trading-sub sub

  # ── Aggregate ───────────────────────────────────────────────────────────────
  JSON_FILES=("$OUT_DIR"/*.json)
  if [[ ! -f "${JSON_FILES[0]}" ]]; then
    log "WARNING: no result JSON files found in $OUT_DIR"
  else
    log "  Aggregating ${#JSON_FILES[@]} shard results..."
    python3 "$REPO_ROOT/simulators/trading-sim/aggregate.py" \
        "${JSON_FILES[@]}" \
        | tee "$RESULTS_DIR/${RUN_ID}-summary.json"
    log "  Summary: $RESULTS_DIR/${RUN_ID}-summary.json"
  fi
done

# ── Step 6: Stop broker jobs ──────────────────────────────────────────────────
for job in "${BROKER_JOBS[@]}"; do
  log "Stopping $job..."
  nomad job stop -purge "$job" 2>/dev/null || true
done

log "=== bench-trading.sh complete (env=$ENV) ==="
log "    Results in: $RESULTS_DIR/"
