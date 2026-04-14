# modules/leaf — client-facing leaf tier (ASG + NLB).
#
# Leaf nodes expose client ports (4222 / 4224 / 4333) to publishers and
# subscribers. Outbound, they upstream to a hub cluster via the leaf
# protocol (7422 for open-wire, 7333 for nats-server).
#
# Uses an ASG so leaf count scales independently of hub count.
# Starts at desired=0 for cost control; scale up with `aws autoscaling
# set-desired-capacity` before a bench run.
#
# The upstream URL is NOT baked in here — it's passed to the Nomad leaf
# job as a var at deploy time (from the hub module's hub_nlb_dns output).

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── Launch template ───────────────────────────────────────────────────────────
resource "aws_launch_template" "leaf" {
  name_prefix            = "${var.cluster_name}-leaf-"
  image_id               = var.ami_id
  instance_type          = var.leaf_instance_type
  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
    }
  }

  instance_initiated_shutdown_behavior = "terminate"

  user_data = base64encode(templatefile(var.user_data_template_path, {
    nomad_version       = var.nomad_version
    is_server           = false
    server_ip           = var.server_private_ip
    node_class          = "leaf"
    tailscale_auth_key  = var.tailscale_auth_key
    tailscale_hostname  = "${var.cluster_name}-leaf"
    auto_shutdown_hours = 0
  }))

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-leaf"
      Role = "leaf"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── ASG ───────────────────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "leaf" {
  name                = "${var.cluster_name}-leaf"
  min_size            = 0
  max_size            = var.leaf_max_count
  desired_capacity    = 0
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.leaf.id
    version = "$Latest"
  }

  target_group_arns = [
    for tg in aws_lb_target_group.leaf : tg.arn
  ]

  health_check_type         = "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "Role"
    value               = "leaf"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# ── NLB (internal, client-facing) ─────────────────────────────────────────────
resource "aws_lb" "leaf" {
  name               = "${var.cluster_name}-leaf"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.cluster_name}-leaf" })
}

locals {
  leaf_ports = {
    ow_client = { port = 4222, suffix = "ow-cl" }
    ow_binary = { port = 4224, suffix = "ow-bin" }
    ns_client = { port = 4333, suffix = "ns-cl" }
  }
}

resource "aws_lb_target_group" "leaf" {
  for_each = local.leaf_ports

  name     = "${substr(var.cluster_name, 0, 19)}-lf-${each.value.suffix}"
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

resource "aws_lb_listener" "leaf" {
  for_each = local.leaf_ports

  load_balancer_arn = aws_lb.leaf.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.leaf[each.key].arn
  }
}
