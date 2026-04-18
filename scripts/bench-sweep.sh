#!/usr/bin/env bash
# bench-sweep.sh — hand-rolled (no Nomad) sweep runner for mini env.
#
# Prereqs:
#   1. terraform apply on terraform/envs/mini/
#   2. deploy-cloudinit.sh (uploads cloudinit/ tree to S3)
#   3. deploy-binaries.sh  (uploads binaries to S3)
#
# Flow per protocol/user-count run:
#   1. ssh hubs: write /etc/bench/versions, re-run role-hub.sh (picks new
#      binaries, restarts services).
#   2. ssh pub: kill any running trading-sim; start pub shards.
#   3. ssh sub: kill any running trading-sim; start sub shards.
#   4. Wait duration + drain.
#   5. aws s3 sync s3://bucket/results/<run-id>/ ./results/<run-id>/
#   6. Aggregate via simulators/trading-sim/aggregate.py.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/envs/mini"

DURATION="60s"
USERS=4000
ALGO_USERS=20
SYMBOLS=500
SIZE=128
PROTOCOLS="binary,nats"
REPS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)   DURATION="$2";   shift 2 ;;
    --users)      USERS="$2";      shift 2 ;;
    --symbols)    SYMBOLS="$2";    shift 2 ;;
    --size)       SIZE="$2";       shift 2 ;;
    --protocols)  PROTOCOLS="$2";  shift 2 ;;
    --reps)       REPS="$2";       shift 2 ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[$(date +%H:%M:%S)] $*"; }
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

BUCKET=$(tf_out results_bucket)
HUB_IPS=($(terraform -chdir="$TF_DIR" output -json hub_public_ips | python3 -c 'import json,sys; [print(ip) for ip in json.load(sys.stdin)]'))
PUB_IP=$(tf_out pub_public_ip)
SUB_IP=$(tf_out sub_public_ip)
PUB_PRIV=$(tf_out pub_private_ip)

HUB0_PRIV=$(terraform -chdir="$TF_DIR" output -json hub_private_ips | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')

log "env: bucket=$BUCKET hubs=${HUB_IPS[*]} pub=$PUB_IP sub=$SUB_IP"

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 ec2-user@"

# ── 1. Deploy binaries, capture version pointers ─────────────────────────
log "building + uploading binaries"
VERSIONS=$("$REPO_ROOT/scripts/deploy-binaries.sh" --bucket "$BUCKET")
echo "$VERSIONS" | sed 's/^/    /'

# ── 2. Roll new binary onto each hub (sequential, mesh-tolerant) ─────────
for hub in "${HUB_IPS[@]}"; do
  log "rolling hub $hub to new version"
  # shellcheck disable=SC2086
  ${SSH}${hub} "sudo tee /etc/bench/versions > /dev/null" <<< "$VERSIONS"
  ${SSH}${hub} "sudo bash /opt/bench/cloudinit/scripts/role-hub.sh"
  # brief health wait: open-wire :4222 + :6222 listening
  for i in {1..30}; do
    if ${SSH}${hub} "ss -tln | grep -q ':4222' && ss -tln | grep -q ':6222'"; then
      log "  hub $hub healthy"
      break
    fi
    sleep 1
  done
done

# ── 3. Update pub/sub version pointers (no service to restart — idle) ────
for n in "$PUB_IP" "$SUB_IP"; do
  ${SSH}${n} "sudo tee /etc/bench/versions > /dev/null" <<< "$VERSIONS"
  ${SSH}${n} "sudo bash /opt/bench/cloudinit/scripts/role-$(${SSH}${n} cat /etc/bench/role).sh"
done

# ── 4. Per-protocol run loop ──────────────────────────────────────────────
IFS=',' read -ra PROTO_LIST <<< "$PROTOCOLS"
for rep in $(seq 1 "$REPS"); do
  for proto in "${PROTO_LIST[@]}"; do
    RUN_ID="$(date +%Y%m%dT%H%M%S)-${proto}-u${USERS}-rep${rep}"
    case "$proto" in
      binary)   PORT=4224; SIM_PROTO=binary ;;
      ow-nats)  PORT=4222; SIM_PROTO=nats ;;
      nats)     PORT=4333; SIM_PROTO=nats ;;
      *) echo "unknown protocol: $proto" >&2; exit 1 ;;
    esac
    # Build a per-shard URL array so trading-sim instances distribute
    # across all mesh hubs. With hub_count=3 and market 2 shards +
    # accounts 1 shard + users 4 shards, shards round-robin hub_ips.
    readarray -t HUB_PRIVS <<< "$(terraform -chdir="$TF_DIR" output -json hub_private_ips | python3 -c 'import json,sys; [print(ip) for ip in json.load(sys.stdin)]')"
    HUB_COUNT=${#HUB_PRIVS[@]}
    if [[ "$SIM_PROTO" == "binary" ]]; then
      URL_PREFIX=""
    else
      URL_PREFIX="nats://"
    fi
    shard_url() {
      local shard_idx=$1
      echo "${URL_PREFIX}${HUB_PRIVS[$(( shard_idx % HUB_COUNT ))]}:${PORT}"
    }

    log "=== run $RUN_ID proto=$proto hubs=${HUB_COUNT} port=$PORT ==="

    # Sub --duration must cover warmup + pub run so subs don't expire
    # mid-bench. Pubs run for the configured --duration; subs for
    # warmup + duration + drain buffer.
    SUB_WARMUP=$(( (USERS / 100) + 10 ))  # e.g. 4000u -> 50s
    PUB_DUR_SEC=${DURATION%s}
    SUB_DUR_SEC=$(( SUB_WARMUP + PUB_DUR_SEC + 30 ))

    # Launch sub shards first (each shard → distinct hub)
    SUB_URL_0=$(shard_url 0); SUB_URL_1=$(shard_url 1); SUB_URL_2=$(shard_url 2); SUB_URL_3=$(shard_url 3)
    ${SSH}${SUB_IP} bash -s <<SUB
      sudo pkill -f trading-sim || true
      sleep 1
      sudo mkdir -p /tmp/bench-results/${RUN_ID}
      sudo chmod 777 /tmp/bench-results/${RUN_ID}
      declare -a URLS=("$SUB_URL_0" "$SUB_URL_1" "$SUB_URL_2" "$SUB_URL_3")
      for shard in 0 1 2 3; do
        nohup /opt/bench/current/trading-sim \
          --role users \
          --shard-id \$shard --shard-count 4 \
          --url "\${URLS[\$shard]}" --protocol $SIM_PROTO \
          --users $USERS --algo-users $ALGO_USERS \
          --symbols $SYMBOLS --size $SIZE \
          --duration ${SUB_DUR_SEC}s \
          --output /tmp/bench-results/${RUN_ID}/sub-\$shard.json \
          > /tmp/bench-results/${RUN_ID}/sub-\$shard.log 2>&1 &
      done
SUB

    # Wait for subs to finish registering before pubs start.
    # 4000 users × 20 visible = ~80K subs per shard; on AL2023 c5.2xlarge
    # this takes ~20-30s. Overestimate to be safe.
    log "warming subs for ${SUB_WARMUP}s"
    sleep "$SUB_WARMUP"
    # Each pub shard → distinct hub for load spread across mesh
    MKT0_URL=$(shard_url 0); MKT1_URL=$(shard_url 1); ACC0_URL=$(shard_url 2)
    ${SSH}${PUB_IP} bash -s <<PUB
      sudo pkill -f trading-sim || true
      sleep 1
      sudo mkdir -p /tmp/bench-results/${RUN_ID}
      sudo chmod 777 /tmp/bench-results/${RUN_ID}
      /opt/bench/current/trading-sim \
        --role market --shard-id 0 --shard-count 2 \
        --url "$MKT0_URL" --protocol $SIM_PROTO \
        --users $USERS --algo-users $ALGO_USERS \
        --symbols $SYMBOLS --size $SIZE \
        --duration $DURATION \
        --output /tmp/bench-results/${RUN_ID}/pub-market-0.json \
        > /tmp/bench-results/${RUN_ID}/pub-market-0.log 2>&1 &
      /opt/bench/current/trading-sim \
        --role market --shard-id 1 --shard-count 2 \
        --url "$MKT1_URL" --protocol $SIM_PROTO \
        --users $USERS --algo-users $ALGO_USERS \
        --symbols $SYMBOLS --size $SIZE \
        --duration $DURATION \
        --output /tmp/bench-results/${RUN_ID}/pub-market-1.json \
        > /tmp/bench-results/${RUN_ID}/pub-market-1.log 2>&1 &
      /opt/bench/current/trading-sim \
        --role accounts --shard-id 0 --shard-count 1 \
        --url "$ACC0_URL" --protocol $SIM_PROTO \
        --users $USERS --algo-users $ALGO_USERS \
        --symbols $SYMBOLS --size $SIZE \
        --duration $DURATION \
        --output /tmp/bench-results/${RUN_ID}/pub-accounts-0.json \
        > /tmp/bench-results/${RUN_ID}/pub-accounts-0.log 2>&1 &
PUB

    # Wait for pubs to finish + subs to drain + write final output.
    # pub runs for PUB_DUR_SEC, subs for SUB_DUR_SEC (warmup + pub + buffer),
    # then 15s default drain, then JSON write.
    # Poll every 5s until no trading-sim processes remain on sub node, cap
    # at SUB_DUR_SEC + drain + 30s tolerance.
    MAX_WAIT=$(( SUB_DUR_SEC - SUB_WARMUP + 30 + 30 ))
    log "waiting up to ${MAX_WAIT}s for subs to finish and write output"
    WAITED=0
    while (( WAITED < MAX_WAIT )); do
      if ! ${SSH}${SUB_IP} "pgrep -fa trading-sim > /dev/null 2>&1"; then
        log "  subs exited at t=${WAITED}s"
        break
      fi
      sleep 5
      WAITED=$(( WAITED + 5 ))
    done

    # Ensure a final sync happens
    ${SSH}${PUB_IP} "sudo systemctl start bench-sync.service" &
    ${SSH}${SUB_IP} "sudo systemctl start bench-sync.service" &
    wait
    sleep 3

    # Pull results locally + aggregate
    OUT_DIR="$REPO_ROOT/results/$RUN_ID"
    mkdir -p "$OUT_DIR"
    aws s3 sync "s3://$BUCKET/results/$RUN_ID/" "$OUT_DIR/" --quiet

    if ls "$OUT_DIR"/*.json >/dev/null 2>&1; then
      python3 "$REPO_ROOT/simulators/trading-sim/aggregate.py" "$OUT_DIR"/*.json \
        > "$OUT_DIR-summary.json"
      python3 - "$OUT_DIR-summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = d.get("market", {})
print(f"  market: {m.get('msg_per_sec',0):,.0f} msg/s  "
      f"p99={m.get('p99_us',0)/1000:.1f}ms  "
      f"p999={m.get('p999_us',0)/1000:.1f}ms  "
      f"delivery={m.get('delivery_ratio',1)*100:.2f}%")
PY
    else
      log "  WARN: no result files for $RUN_ID"
    fi
  done
done

log "=== sweep complete ==="
