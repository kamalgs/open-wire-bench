#!/usr/bin/env bash
# Role: hub — runs open-wire + nats-server in mesh-cluster mode.
#
# Assumes bootstrap.sh has already:
#   - synced binaries to /opt/bench/bin/<tool>/<sha>/
#   - enabled bench-sync.timer
#
# This script:
#   1. Syncs hub-specific systemd units
#   2. Points /opt/bench/current/<tool> symlinks at the version in /etc/bench/versions
#   3. Renders broker configs from /etc/bench/env (peer list, cluster name)
#   4. Enables and starts open-wire.service and nats-server.service
set -euo pipefail

source /etc/bench/env
# versions file contains OPEN_WIRE_VER, NATS_VER, TRADING_SIM_VER
source /etc/bench/versions

log() { echo "[role-hub] $*"; }

log "syncing hub systemd units"
aws s3 sync "s3://${BENCH_BUCKET}/cloudinit/systemd/hub/" \
            /etc/systemd/system/ --exclude "*" --include "*.service"

log "updating current-version symlinks"
ln -sfn "/opt/bench/bin/open-wire/${OPEN_WIRE_VER}/open-wire"       /opt/bench/current/open-wire
ln -sfn "/opt/bench/bin/nats-server/${NATS_VER}/nats-server"        /opt/bench/current/nats-server
chmod +x /opt/bench/current/open-wire /opt/bench/current/nats-server

# Render broker configs from the env peer list.
# open-wire needs a conf only for the leafnode listen block; cluster seeds
# go on the CLI. nats-server takes a full conf.
OW_HUB_SEEDS=$(echo "${BENCH_HUB_PEERS}" | tr ',' '\n' | awk '{print $1":6222"}' | paste -sd,)
NS_HUB_ROUTES=$(echo "${BENCH_HUB_PEERS}" | tr ',' '\n' | awk '{print "nats-route://"$1":6333"}' | paste -sd,)

mkdir -p /etc/bench
cat > /etc/bench/ow.conf <<EOF
leafnodes {
  listen: 0.0.0.0:7422
}
EOF

cat > /etc/bench/nats.conf <<EOF
port: 4333
http: 8333

cluster {
  name: "${BENCH_CLUSTER_NAME}"
  listen: 0.0.0.0:6333
  routes: [
$(echo "${NS_HUB_ROUTES}" | tr ',' '\n' | sed 's/^/    /')
  ]
}

leafnodes {
  listen: 0.0.0.0:7333
}
EOF

# Export cluster seeds for the open-wire unit's EnvironmentFile.
cat > /etc/bench/ow.env <<EOF
OW_CLUSTER_SEEDS=${OW_HUB_SEEDS}
OW_CLUSTER_NAME=${BENCH_CLUSTER_NAME}
OW_WORKERS=${BENCH_OW_WORKERS:-2}
OW_SHARDS=${BENCH_OW_SHARDS:-2}
EOF

systemctl daemon-reload
systemctl enable --now open-wire.service nats-server.service

log "role-hub complete"
