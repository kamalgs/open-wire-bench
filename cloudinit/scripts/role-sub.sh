#!/usr/bin/env bash
# Role: sub — same as pub. trading-sim launched over SSH per run.
set -euo pipefail

source /etc/bench/env
source /etc/bench/versions

log() { echo "[role-sub] $*"; }

ln -sfn "/opt/bench/bin/trading-sim/${TRADING_SIM_VER}/trading-sim" /opt/bench/current/trading-sim
chmod +x /opt/bench/current/trading-sim

if [[ -n "${NODE_EXPORTER_VER:-}" && "$NODE_EXPORTER_VER" != "unset" ]]; then
  ln -sfn "/opt/bench/bin/node_exporter/${NODE_EXPORTER_VER}/node_exporter" /opt/bench/current/node_exporter
  chmod +x /opt/bench/current/node_exporter
  systemctl restart node-exporter.service 2>/dev/null || systemctl enable --now node-exporter.service
fi

log "role-sub complete"
