#!/usr/bin/env bash
# Role: hub — runs open-wire + nats-server in mesh-cluster mode.
#
# Peer discovery is runtime via EC2 tags, not baked into /etc/bench/env.
# This avoids a terraform circular dep (peer IPs -> user-data -> instances)
# and makes the mesh self-healing if a hub is replaced.
set -euo pipefail

source /etc/bench/env
source /etc/bench/versions

log() { echo "[role-hub] $*"; }

log "syncing hub systemd units"
aws s3 sync "s3://${BENCH_BUCKET}/cloudinit/systemd/hub/" \
            /etc/systemd/system/ --exclude "*" --include "*.service"

log "updating current-version symlinks"
ln -sfn "/opt/bench/bin/open-wire/${OPEN_WIRE_VER}/open-wire"   /opt/bench/current/open-wire
ln -sfn "/opt/bench/bin/nats-server/${NATS_VER}/nats-server"    /opt/bench/current/nats-server
chmod +x /opt/bench/current/open-wire /opt/bench/current/nats-server

# Discover hub peers at runtime (requires ec2:DescribeInstances on the
# instance role — already granted by the base IAM policy). AL2023 enforces
# IMDSv2, so use a session token.
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -sH "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
PEERS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=open-wire-bench" \
            "Name=tag:Environment,Values=${BENCH_ENV}" \
            "Name=tag:Role,Values=hub" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '[:space:]' '\n' | grep -v '^$' | sort)

if [[ -z "$PEERS" ]]; then
  log "ERROR: no hub peers discovered via EC2 tags"
  exit 1
fi

log "discovered hub peers:"
echo "$PEERS" | sed 's/^/  /'

OW_CLUSTER_SEEDS=$(echo "$PEERS" | awk '{print $1":6222"}' | paste -sd,)
NS_HUB_ROUTES=$(echo "$PEERS"    | awk '{print "nats-route://"$1":6333"}' | paste -sd,)

mkdir -p /etc/bench
cat > /etc/bench/ow.conf <<EOF
leafnodes {
  listen: 0.0.0.0:7422
}
EOF

{
  echo "port: 4333"
  echo "http: 8333"
  echo ""
  echo "cluster {"
  echo "  name: \"${BENCH_CLUSTER_NAME}\""
  echo "  listen: 0.0.0.0:6333"
  echo "  routes: ["
  echo "$PEERS" | awk '{print "    nats-route://"$1":6333"}'
  echo "  ]"
  echo "}"
  echo ""
  echo "leafnodes {"
  echo "  listen: 0.0.0.0:7333"
  echo "}"
} > /etc/bench/nats.conf

cat > /etc/bench/ow.env <<EOF
OW_CLUSTER_SEEDS=${OW_CLUSTER_SEEDS}
OW_CLUSTER_NAME=${BENCH_CLUSTER_NAME}
OW_WORKERS=${BENCH_OW_WORKERS:-2}
OW_SHARDS=${BENCH_OW_SHARDS:-2}
EOF

systemctl daemon-reload
systemctl enable --now open-wire.service nats-server.service

log "role-hub complete (peers=$(echo "$PEERS" | wc -l))"
