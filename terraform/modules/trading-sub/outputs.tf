output "trading_sub_asg_name" {
  value = aws_autoscaling_group.trading_sub.name
}

output "trading_sub_tailscale_hostname" {
  value = "${var.cluster_name}-trading-sub"
}
