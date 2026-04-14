variable "cluster_name" { type = string }
variable "subnet_id"    { type = string }

variable "ami_id"                    { type = string }
variable "iam_instance_profile_name" { type = string }
variable "security_group_id"         { type = string }
variable "server_private_ip"         { type = string }
variable "user_data_template_path"   { type = string }

variable "trading_instance_type" {
  type        = string
  default     = "c5.xlarge"
  description = "4 vCPU, 8 GB, Up to 10 Gbps network"
}

variable "use_spot" {
  type        = bool
  default     = false
  description = "Use spot instances. Default on-demand — flip to true for longer runs."
}

variable "nomad_version" {
  type    = string
  default = "1.11.2"
}

variable "tags" {
  type    = map(string)
  default = {}
}
