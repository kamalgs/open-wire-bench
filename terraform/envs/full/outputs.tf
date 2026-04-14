output "nomad_addr" {
  description = "Operator-facing Nomad HTTP API — export as NOMAD_ADDR"
  value       = "http://${module.base.server_public_ip}:4646"
}

output "server_public_ip" { value = module.base.server_public_ip }
output "ssm_server"       { value = module.base.ssm_server_session }
output "results_bucket"   { value = module.base.results_bucket }

# ── Hub cluster ───────────────────────────────────────────────────────────────
output "hub_nlb_dns"     { value = module.hub.hub_nlb_dns }
output "hub_private_ips" { value = module.hub.hub_private_ips }
output "ow_hub_seeds"    { value = module.hub.ow_hub_seeds }
output "ns_hub_routes"   { value = module.hub.ns_hub_routes }

# ── Leaf tier ─────────────────────────────────────────────────────────────────
output "leaf_nlb_dns"  { value = module.leaf.leaf_nlb_dns }
output "leaf_asg_name" { value = module.leaf.leaf_asg_name }

# ── Broker endpoints (point at leaf NLB — full 2-hop topology) ────────────────
output "broker_binary_url" {
  description = "open-wire binary protocol via leaf NLB"
  value       = "${module.leaf.leaf_nlb_dns}:4224"
}

output "broker_ow_nats_url" {
  description = "open-wire NATS protocol via leaf NLB"
  value       = "nats://${module.leaf.leaf_nlb_dns}:4222"
}

output "broker_ns_url" {
  description = "nats-server NATS protocol via leaf NLB"
  value       = "nats://${module.leaf.leaf_nlb_dns}:4333"
}

output "trading_pub_asg" { value = module.trading_pub.trading_pub_asg_name }
output "trading_sub_asg" { value = module.trading_sub.trading_sub_asg_name }

output "env_exports" {
  value = <<-EOT
    export NOMAD_ADDR=http://${module.base.server_public_ip}:4646
    export HUB_NLB=${module.hub.hub_nlb_dns}
    export LEAF_NLB=${module.leaf.leaf_nlb_dns}
    export OW_HUB_SEEDS=${module.hub.ow_hub_seeds}
    export NS_HUB_ROUTES=${module.hub.ns_hub_routes}
    export BROKER_BINARY_URL=${module.leaf.leaf_nlb_dns}:4224
    export BROKER_NS_URL=nats://${module.leaf.leaf_nlb_dns}:4333
    export LEAF_ASG=${module.leaf.leaf_asg_name}
    export TRADING_PUB_ASG=${module.trading_pub.trading_pub_asg_name}
    export TRADING_SUB_ASG=${module.trading_sub.trading_sub_asg_name}
  EOT
}
