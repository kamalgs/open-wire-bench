output "trading_broker_instance_id" {
  value = aws_instance.trading_broker.id
}

output "trading_broker_private_ip" {
  description = "Private IP — pub/sub shards connect to this for broker endpoints"
  value       = aws_instance.trading_broker.private_ip
}
