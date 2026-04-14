output "iam_instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}

output "security_group_id" {
  value = aws_security_group.common.id
}

output "server_instance_id" {
  value = aws_instance.server.id
}

output "server_private_ip" {
  description = "Private IP used by Nomad clients to reach the server"
  value       = aws_instance.server.private_ip
}

output "server_tailscale_hostname" {
  value = "${var.cluster_name}-server"
}

output "results_bucket" {
  value = aws_s3_bucket.results.id
}

output "ami_id" {
  description = "Ubuntu 22.04 AMI used for all nodes"
  value       = data.aws_ami.ubuntu.id
}

output "user_data_template_path" {
  description = "Absolute path to the shared user_data.sh.tpl — other modules reference this"
  value       = "${path.module}/templates/user_data.sh.tpl"
}

output "ssm_server_session" {
  value = "aws ssm start-session --target ${aws_instance.server.id}"
}
