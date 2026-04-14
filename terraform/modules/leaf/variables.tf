variable "cluster_name" { type = string }
variable "vpc_id"       { type = string }
variable "subnet_ids"   { type = list(string) }

# ── From modules/base ─────────────────────────────────────────────────────────
variable "ami_id"                    { type = string }
variable "iam_instance_profile_name" { type = string }
variable "security_group_id"         { type = string }
variable "server_private_ip"         { type = string }
variable "user_data_template_path"   { type = string }

# ── Leaf config ───────────────────────────────────────────────────────────────
variable "leaf_max_count" {
  type        = number
  default     = 1
  description = "Max instances in the leaf ASG (desired starts at 0)"
}

variable "leaf_instance_type" {
  type        = string
  default     = "c5n.xlarge"
  description = "Leaf node instance type (4 vCPU, 25 Gbps NIC recommended)"
}

variable "nomad_version" {
  type    = string
  default = "1.11.2"
}

variable "tags" {
  type    = map(string)
  default = {}
}
