# These are the credentials to export for all subsequent terraform apply runs.
# Store them in a password manager or CI secret — never commit to git.

output "access_key_id" {
  value       = aws_iam_access_key.deploy.id
  description = "AWS_ACCESS_KEY_ID for the deploy user"
}

output "secret_access_key" {
  value       = aws_iam_access_key.deploy.secret
  description = "AWS_SECRET_ACCESS_KEY for the deploy user"
  sensitive   = true
}

output "export_block" {
  description = "Paste into your shell (or CI secret config)"
  sensitive   = true
  value       = <<-EOT
    export AWS_ACCESS_KEY_ID="${aws_iam_access_key.deploy.id}"
    export AWS_SECRET_ACCESS_KEY="${aws_iam_access_key.deploy.secret}"
    export AWS_DEFAULT_REGION="${var.region}"
  EOT
}
