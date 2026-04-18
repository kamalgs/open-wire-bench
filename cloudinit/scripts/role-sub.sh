#!/usr/bin/env bash
# Role: sub — same as pub. trading-sim launched over SSH per run.
set -euo pipefail

source /etc/bench/env
source /etc/bench/versions

log() { echo "[role-sub] $*"; }

ln -sfn "/opt/bench/bin/trading-sim/${TRADING_SIM_VER}/trading-sim" /opt/bench/current/trading-sim
chmod +x /opt/bench/current/trading-sim

log "role-sub complete"
