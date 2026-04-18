#!/usr/bin/env bash
# Role: pub — idle broker-side at boot (trading-sim starts on demand via SSH).
#
# Hosts the Prometheus instance (co-tenant to avoid an extra EC2 node).
# Pub runs at ~2% CPU during benches, so Prometheus overhead is lost in
# the noise and doesn't skew hub/sub CPU measurements.
set -euo pipefail

source /etc/bench/env
source /etc/bench/versions

log() { echo "[role-pub] $*"; }

# trading-sim symlink for this node's runs
ln -sfn "/opt/bench/bin/trading-sim/${TRADING_SIM_VER}/trading-sim" /opt/bench/current/trading-sim
chmod +x /opt/bench/current/trading-sim

# node_exporter (common to all roles)
if [[ -n "${NODE_EXPORTER_VER:-}" && "$NODE_EXPORTER_VER" != "unset" ]]; then
  ln -sfn "/opt/bench/bin/node_exporter/${NODE_EXPORTER_VER}/node_exporter" /opt/bench/current/node_exporter
  chmod +x /opt/bench/current/node_exporter
  systemctl restart node-exporter.service 2>/dev/null || systemctl enable --now node-exporter.service
fi

# Prometheus symlink + config + unit
if [[ -n "${PROMETHEUS_VER:-}" && "$PROMETHEUS_VER" != "unset" ]]; then
  log "setting up Prometheus (version $PROMETHEUS_VER)"
  ln -sfn "/opt/bench/bin/prometheus/${PROMETHEUS_VER}/prometheus" /opt/bench/current/prometheus
  chmod +x /opt/bench/current/prometheus

  mkdir -p /opt/bench/prometheus/data
  aws s3 cp "s3://${BENCH_BUCKET}/cloudinit/config/prometheus.yml" /etc/bench/prometheus.yml

  aws s3 sync "s3://${BENCH_BUCKET}/cloudinit/systemd/pub/" \
              /etc/systemd/system/ --exclude "*" --include "*.service"

  systemctl daemon-reload
  systemctl enable --now prometheus.service
  log "prometheus enabled on :9092"
fi

log "role-pub complete"
