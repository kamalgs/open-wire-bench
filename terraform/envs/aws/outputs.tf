output "nomad_api_url"    { value = module.cluster.nomad_api_url }
output "ssm_server"       { value = module.cluster.ssm_server }
output "ssh_server"       { value = module.cluster.ssh_server }
output "broker_public_ips" { value = module.cluster.broker_public_ips }
output "results_bucket"   { value = local.results_bucket }

output "env_exports" {
  description = "Export these before running make bench against the cluster"
  value = <<-EOT
    export NOMAD_ADDR=${module.cluster.nomad_api_url}
    # Broker IPs (pick one for single-node bench, or round-robin):
    %{for i, ip in module.cluster.broker_public_ips~}
    # broker-${i}: open-wire nats://${ip}:4222   nats-server nats://${ip}:4333
    %{endfor~}
  EOT
}
