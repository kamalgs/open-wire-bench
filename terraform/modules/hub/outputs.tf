output "hub_nlb_dns" {
  description = "Hub NLB DNS — exposes ow-leaf (7422), ns-leaf (7333), ow-client (4222), ow-binary (4224), ns-client (4333)"
  value       = aws_lb.hub.dns_name
}

output "hub_instance_ids" {
  value = aws_instance.hub[*].id
}

output "hub_private_ips" {
  description = "Private IPs of the hub instances (used for mesh seeds + direct access)"
  value       = aws_instance.hub[*].private_ip
}

output "ow_hub_seeds" {
  description = "Comma-separated private IP:port list for open-wire --cluster-seeds"
  value       = local.ow_hub_seeds
}

output "ns_hub_routes" {
  description = "Comma-separated nats-route:// URLs for nats-server cluster routes (using private IPs)"
  value       = local.ns_hub_routes
}
