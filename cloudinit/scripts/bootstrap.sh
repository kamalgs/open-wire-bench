#!/usr/bin/env bash
# Common bootstrap: runs on every node regardless of role.
#
# Responsibilities:
#   1. Create bench directories
#   2. Sync binaries from S3 into /opt/bench/bin/<tool>/<sha>/
#   3. Sync common systemd units from S3 into /etc/systemd/system/
#   4. Enable bench-sync.timer so binaries + units stay current
#
# Idempotent: safe to re-run on an existing node.
set -euo pipefail

source /etc/bench/env

log() { echo "[bootstrap] $*"; }

# Versions file is written by user-data with placeholders; the real
# pinned versions are set by bench-sweep.sh via SSH before each run.
# Source it if it exists so node-exporter symlink can be set on boot.
[[ -f /etc/bench/versions ]] && source /etc/bench/versions || true

log "env: BUCKET=${BENCH_BUCKET} ENV=${BENCH_ENV} ROLE=${BENCH_ROLE}"

mkdir -p /opt/bench/bin /opt/bench/current /tmp/bench-results

log "syncing binaries from s3://${BENCH_BUCKET}/bin/"
aws s3 sync "s3://${BENCH_BUCKET}/bin/" /opt/bench/bin/ --size-only

log "syncing common systemd units"
aws s3 sync "s3://${BENCH_BUCKET}/cloudinit/systemd/common/" \
            /etc/systemd/system/ --exclude "*" --include "*.service" --include "*.timer"

# Point /opt/bench/current/node_exporter at pinned version (if set).
# Version "unset" means bench-sweep.sh hasn't rolled a real version yet;
# node-exporter won't start, but bench-sync.timer will refresh when it does.
if [[ -n "${NODE_EXPORTER_VER:-}" && "$NODE_EXPORTER_VER" != "unset" ]]; then
  ln -sfn "/opt/bench/bin/node_exporter/${NODE_EXPORTER_VER}/node_exporter" \
          /opt/bench/current/node_exporter
  chmod +x /opt/bench/current/node_exporter
fi

systemctl daemon-reload
systemctl enable --now bench-sync.timer

# node-exporter runs on every node (common unit), scrape :9100.
# Only enable if the current symlink exists — otherwise systemd restart
# loops until the binary arrives via sync timer.
if [[ -x /opt/bench/current/node_exporter ]]; then
  systemctl enable --now node-exporter.service
fi

log "bootstrap complete"
