variable "cluster_name" { type = string }
variable "vpc_id"       { type = string }
variable "subnet_ids"   { type = list(string) }

# ── From modules/base ─────────────────────────────────────────────────────────
variable "ami_id"                    { type = string }
variable "iam_instance_profile_name" { type = string }
variable "security_group_id"         { type = string }
variable "server_private_ip"         { type = string }
variable "user_data_template_path"   { type = string }

# ── Hub config ────────────────────────────────────────────────────────────────
variable "hub_count" {
  type        = number
  default     = 2
  description = "Number of hub nodes in the mesh cluster"
}

variable "hub_instance_type" {
  type        = string
  default     = "c5n.xlarge"
  description = "Hub node instance type (4 vCPU, 25 Gbps NIC recommended)"
}

variable "nomad_version" {
  type    = string
  default = "1.11.2"
}

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "tags" {
  type    = map(string)
  default = {}
}
