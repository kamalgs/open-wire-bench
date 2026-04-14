# modules/hub — mesh cluster tier (N hub instances + NLB).
#
# Hub nodes run both open-wire (route protocol on 6222) and nats-server
# (route protocol on 6333) forming a full mesh. Clients can connect
# directly (4222 / 4224 / 4333) or via a leaf layer (7422 / 7333).
#
# Uses plain aws_instance (not ASG) for seed stability: mesh seeds are
# the private IPs of these instances, which stay fixed for the lifetime
# of the instance. For small N (2-3) this is fine.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── Hub instances ─────────────────────────────────────────────────────────────
resource "aws_instance" "hub" {
  count                  = var.hub_count
  ami                    = var.ami_id
  instance_type          = var.hub_instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  iam_instance_profile   = var.iam_instance_profile_name
  vpc_security_group_ids = [var.security_group_id]

  user_data = base64encode(templatefile(var.user_data_template_path, {
    nomad_version       = var.nomad_version
    is_server           = false
    server_ip           = var.server_private_ip
    node_class          = "hub"
    node_hostname       = "${var.cluster_name}-hub-${count.index}"
    auto_shutdown_hours = var.auto_shutdown_hours
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-hub-${count.index}"
    Role = "hub"
  })
}

# ── NLB (internal) ────────────────────────────────────────────────────────────
resource "aws_lb" "hub" {
  name               = "${var.cluster_name}-hub"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.cluster_name}-hub" })
}

# ── Target groups ─────────────────────────────────────────────────────────────
# 5 ports exposed: ow-leaf (7422), ns-leaf (7333), ow-client (4222),
# ow-binary (4224), ns-client (4333).
locals {
  hub_ports = {
    ow_leaf   = { port = 7422, suffix = "ow-leaf" }
    ns_leaf   = { port = 7333, suffix = "ns-leaf" }
    ow_client = { port = 4222, suffix = "ow-cl" }
    ow_binary = { port = 4224, suffix = "ow-bin" }
    ns_client = { port = 4333, suffix = "ns-cl" }
  }
}

resource "aws_lb_target_group" "hub" {
  for_each = local.hub_ports

  name     = "${substr(var.cluster_name, 0, 19)}-hub-${each.value.suffix}"
  port     = each.value.port
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_listener" "hub" {
  for_each = local.hub_ports

  load_balancer_arn = aws_lb.hub.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hub[each.key].arn
  }
}

locals {
  hub_attachments = {
    for pair in setproduct(keys(local.hub_ports), range(var.hub_count)) :
    "${pair[0]}-${pair[1]}" => {
      port_key  = pair[0]
      hub_index = pair[1]
    }
  }

  # Mesh seeds use the hub instances' private IPs directly. Private IPs
  # are stable for the lifetime of an aws_instance (unlike ASG instances),
  # so we can hardcode them into the Nomad cluster job variables.
  hub_private_ips = aws_instance.hub[*].private_ip
  ow_hub_seeds    = join(",", [for ip in local.hub_private_ips : "${ip}:6222"])
  ns_hub_routes   = join(",", [for ip in local.hub_private_ips : "nats-route://${ip}:6333"])
}

resource "aws_lb_target_group_attachment" "hub" {
  for_each = local.hub_attachments

  target_group_arn = aws_lb_target_group.hub[each.value.port_key].arn
  target_id        = aws_instance.hub[each.value.hub_index].id
  port             = local.hub_ports[each.value.port_key].port
}
