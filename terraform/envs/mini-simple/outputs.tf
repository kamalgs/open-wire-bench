output "results_bucket" {
  value = aws_s3_bucket.bench.id
}

output "hub_public_ips" {
  value = aws_instance.hub[*].public_ip
}

output "hub_private_ips" {
  value = aws_instance.hub[*].private_ip
}

output "pub_public_ip" {
  value = aws_instance.pub.public_ip
}

output "pub_private_ip" {
  value = aws_instance.pub.private_ip
}

output "sub_public_ip" {
  value = aws_instance.sub.public_ip
}

output "sub_private_ip" {
  value = aws_instance.sub.private_ip
}

output "ssh_hint" {
  value = <<-EOT
    Hubs: ${join(", ", [for i in aws_instance.hub : "ssh ec2-user@${i.public_ip}"])}
    Pub:  ssh ec2-user@${aws_instance.pub.public_ip}
    Sub:  ssh ec2-user@${aws_instance.sub.public_ip}
  EOT
}
