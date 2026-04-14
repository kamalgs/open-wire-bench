output "trading_broker_instance_id" {
  value = aws_instance.trading_broker.id
}

output "trading_broker_private_ip" {
  value = aws_instance.trading_broker.private_ip
}

output "trading_broker_tailscale_hostname" {
  description = "Tailscale DNS name — trading pub/sub nodes reach the broker here"
  value       = "${var.cluster_name}-trading-broker"
}
