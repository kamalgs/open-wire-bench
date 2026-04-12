#!/usr/bin/env bash
# Nomad node bootstrap — installs and configures Nomad on Ubuntu 22.04.
# Rendered by Terraform; variables injected via templatefile().

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Wait for apt lock ─────────────────────────────────────────────────────────
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

# ── HashiCorp apt repo ────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq wget gpg lsb-release

wget -qO- https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list

apt-get update -qq
apt-get install -y -qq nomad=${nomad_version}*

# ── Nomad data directory ──────────────────────────────────────────────────────
mkdir -p /opt/nomad/data
chown nomad:nomad /opt/nomad/data

# ── Nomad configuration ───────────────────────────────────────────────────────
PRIVATE_IP=$(curl -sf http://169.254.169.254/latest/meta-data/local-ipv4)

cat > /etc/nomad.d/nomad.hcl <<CONF
data_dir  = "/opt/nomad/data"
log_level = "INFO"
bind_addr = "0.0.0.0"

advertise {
  http = "$${PRIVATE_IP}"
  rpc  = "$${PRIVATE_IP}"
  serf = "$${PRIVATE_IP}"
}

%{ if is_server ~}
server {
  enabled          = true
  bootstrap_expect = 1
}
%{ else ~}
client {
  enabled = true
  servers = ["${server_ip}:4647"]

  # Node class used by job constraints to separate broker and sim workloads
  node_class = "${node_class}"

  options = {
    "driver.raw_exec.enable" = "1"
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}
%{ endif ~}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
}
CONF

# ── Start Nomad ───────────────────────────────────────────────────────────────
systemctl enable nomad
systemctl start nomad

echo "Nomad ${nomad_version} started as ${is_server ? "server" : "client (${node_class})"}"
