# modules/trading-broker — single EC2 instance running open-wire +
# nats-server side-by-side. Reachable via Tailscale hostname
# `$cluster_name-trading-broker` (no NLB).
#
# Used by the micro env (single-node broker bench). For mini/full envs
# the hub cluster serves the same role — don't include this module there.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_instance" "trading_broker" {
  ami                    = var.ami_id
  instance_type          = var.trading_instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = var.iam_instance_profile_name
  vpc_security_group_ids = [var.security_group_id]

  user_data = base64encode(templatefile(var.user_data_template_path, {
    nomad_version       = var.nomad_version
    is_server           = false
    server_ip           = var.server_private_ip
    node_class          = "trading-broker"
    tailscale_auth_key  = var.tailscale_auth_key
    tailscale_hostname  = "${var.cluster_name}-trading-broker"
    auto_shutdown_hours = var.auto_shutdown_hours
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-trading-broker"
    Role = "trading-broker"
  })
}
