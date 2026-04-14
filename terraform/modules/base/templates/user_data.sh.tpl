#!/usr/bin/env bash
# Nomad node bootstrap — installs Tailscale + Nomad on Ubuntu 22.04.
# Rendered by Terraform; variables injected via templatefile().
# Shared by base, hub, leaf, trading-broker, trading-pub, trading-sub modules.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Wait for apt lock ─────────────────────────────────────────────────────────
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

apt-get update -qq
apt-get install -y -qq wget gpg curl lsb-release

# ── Tailscale ─────────────────────────────────────────────────────────────────
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] \
https://pkgs.tailscale.com/stable/ubuntu jammy main" \
    > /etc/apt/sources.list.d/tailscale.list

apt-get update -qq
apt-get install -y -qq tailscale

systemctl enable tailscaled
systemctl start tailscaled

tailscale up \
    --authkey="${tailscale_auth_key}" \
    --hostname="${tailscale_hostname}" \
    --ssh \
    --accept-routes

# ── HashiCorp apt repo ────────────────────────────────────────────────────────
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

%{ if auto_shutdown_hours > 0 ~}
# ── Auto-terminate after ${auto_shutdown_hours}h ──────────────────────────────
systemd-run \
    --on-active="${auto_shutdown_hours}h" \
    --unit=auto-shutdown \
    /bin/systemctl poweroff
%{ endif ~}

echo "Bootstrap complete: Tailscale=${tailscale_hostname} Nomad=${nomad_version} role=${is_server ? "server" : "client (${node_class})"}"
