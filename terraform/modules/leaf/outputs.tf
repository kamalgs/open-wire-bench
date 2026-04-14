output "leaf_nlb_dns" {
  description = "Leaf NLB DNS — exposes ow-client (4222), ow-binary (4224), ns-client (4333) to bench publishers/subscribers"
  value       = aws_lb.leaf.dns_name
}

output "leaf_asg_name" {
  description = "ASG name — used to scale 0→N before a bench run"
  value       = aws_autoscaling_group.leaf.name
}
