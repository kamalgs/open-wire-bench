output "nomad_addr" {
  description = "Operator-facing Nomad HTTP API — export as NOMAD_ADDR"
  value       = "http://${module.base.server_public_ip}:4646"
}

output "server_public_ip" { value = module.base.server_public_ip }
output "ssm_server"       { value = module.base.ssm_server_session }
output "results_bucket"   { value = module.base.results_bucket }

# ── Broker endpoints for the trading bench ────────────────────────────────────
output "broker_binary_url" {
  description = "open-wire binary protocol — host:port"
  value       = "${module.trading_broker.trading_broker_private_ip}:4224"
}

output "broker_ow_nats_url" {
  description = "open-wire NATS protocol — nats://host:port"
  value       = "nats://${module.trading_broker.trading_broker_private_ip}:4222"
}

output "broker_ns_url" {
  description = "nats-server NATS protocol — nats://host:port"
  value       = "nats://${module.trading_broker.trading_broker_private_ip}:4333"
}

output "trading_pub_asg" { value = module.trading_pub.trading_pub_asg_name }
output "trading_sub_asg" { value = module.trading_sub.trading_sub_asg_name }

output "env_exports" {
  description = "Shell exports for bench-trading.sh convenience"
  value       = <<-EOT
    export NOMAD_ADDR=http://${module.base.server_public_ip}:4646
    export BROKER_BINARY_URL=${module.trading_broker.trading_broker_private_ip}:4224
    export BROKER_NS_URL=nats://${module.trading_broker.trading_broker_private_ip}:4333
    export TRADING_PUB_ASG=${module.trading_pub.trading_pub_asg_name}
    export TRADING_SUB_ASG=${module.trading_sub.trading_sub_asg_name}
  EOT
}
