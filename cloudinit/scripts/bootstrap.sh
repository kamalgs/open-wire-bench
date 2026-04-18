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

log "env: BUCKET=${BENCH_BUCKET} ENV=${BENCH_ENV} ROLE=${BENCH_ROLE}"

mkdir -p /opt/bench/bin /opt/bench/current /tmp/bench-results

log "syncing binaries from s3://${BENCH_BUCKET}/bin/"
aws s3 sync "s3://${BENCH_BUCKET}/bin/" /opt/bench/bin/ --size-only

log "syncing common systemd units"
aws s3 sync "s3://${BENCH_BUCKET}/cloudinit/systemd/common/" \
            /etc/systemd/system/ --exclude "*" --include "*.service" --include "*.timer"

systemctl daemon-reload
systemctl enable --now bench-sync.timer

log "bootstrap complete"
