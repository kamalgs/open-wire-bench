#!/usr/bin/env bash
# Role: pub — idle at boot. trading-sim is launched on demand by the
# bench sweep script over SSH.
#
# Keeping this file present (even if mostly empty) so:
#   - the contract "every role has a role-*.sh" holds
#   - future pub-specific sidecars (tracing, profiling) have a home
set -euo pipefail

source /etc/bench/env
source /etc/bench/versions

log() { echo "[role-pub] $*"; }

ln -sfn "/opt/bench/bin/trading-sim/${TRADING_SIM_VER}/trading-sim" /opt/bench/current/trading-sim
chmod +x /opt/bench/current/trading-sim

log "role-pub complete (trading-sim available at /opt/bench/current/trading-sim)"
