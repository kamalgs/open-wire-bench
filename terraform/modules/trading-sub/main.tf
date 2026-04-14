# modules/trading-sub — trading-sim subscriber ASG (users shards).
#
# Single-node ASG (desired=0 until a bench run). Nomad job runs multiple
# allocations on the single instance — 4 users shards by default
# (configurable in the Nomad job vars, not here).
#
# No NLB. The instance joins the tailnet as `$cluster_name-trading-sub`.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "aws_launch_template" "trading_sub" {
  name_prefix            = "${var.cluster_name}-trading-sub-"
  image_id               = var.ami_id
  instance_type          = var.trading_instance_type
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
    node_class          = "trading-sub"
    tailscale_auth_key  = var.tailscale_auth_key
    tailscale_hostname  = "${var.cluster_name}-trading-sub"
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
      Name = "${var.cluster_name}-trading-sub"
      Role = "trading-sub"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "trading_sub" {
  name                = "${var.cluster_name}-trading-sub"
  min_size            = 0
  max_size            = 1
  desired_capacity    = 0
  vpc_zone_identifier = [var.subnet_id]

  launch_template {
    id      = aws_launch_template.trading_sub.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "Role"
    value               = "trading-sub"
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
