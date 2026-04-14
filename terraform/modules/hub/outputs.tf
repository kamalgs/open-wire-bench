output "hub_nlb_dns" {
  description = "Hub NLB DNS — exposes ow-leaf (7422), ns-leaf (7333), ow-client (4222), ow-binary (4224), ns-client (4333)"
  value       = aws_lb.hub.dns_name
}

output "hub_instance_ids" {
  value = aws_instance.hub[*].id
}

output "hub_private_ips" {
  value = aws_instance.hub[*].private_ip
}

output "hub_tailscale_hostnames" {
  value = local.hub_ts_names
}

output "ow_hub_seeds" {
  description = "Comma-separated host:port list for open-wire --cluster-seeds"
  value       = local.ow_hub_seeds
}

output "ns_hub_routes" {
  description = "Comma-separated nats-route:// URLs for nats-server cluster routes"
  value       = local.ns_hub_routes
}
