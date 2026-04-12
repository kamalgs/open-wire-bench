output "server_public_ip"  { value = aws_instance.server.public_ip }
output "server_private_ip" { value = aws_instance.server.private_ip }

output "broker_public_ips" {
  value = aws_instance.broker[*].public_ip
}
output "broker_private_ips" {
  value = aws_instance.broker[*].private_ip
}

output "sim_public_ips" {
  value = aws_instance.sim[*].public_ip
}

output "nomad_api_url" {
  value       = "http://${aws_instance.server.public_ip}:4646"
  description = "Nomad HTTP API — open port 4646 or use SSH tunnel"
}

output "ssh_server" {
  value       = "ssh ubuntu@${aws_instance.server.public_ip}"
  description = "SSH to server node (requires key_name set)"
}

output "ssm_server" {
  value       = "aws ssm start-session --target ${aws_instance.server.id}"
  description = "SSM shell access (no key required)"
}
