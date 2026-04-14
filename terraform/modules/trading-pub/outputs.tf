output "trading_pub_asg_name" {
  value = aws_autoscaling_group.trading_pub.name
}

output "trading_pub_tailscale_hostname" {
  value = "${var.cluster_name}-trading-pub"
}
