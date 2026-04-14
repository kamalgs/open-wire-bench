variable "cluster_name" {
  type        = string
  description = "Name prefix for all resources in this environment"
}

variable "vpc_id"     { type = string }
variable "vpc_cidr"   { type = string }
variable "subnet_ids" { type = list(string) }

variable "nomad_version" {
  type    = string
  default = "1.11.2"
}

variable "server_instance_type" {
  type        = string
  default     = "t3.small"
  description = "Nomad server node (control plane only — 2 vCPU / 2 GB is enough)"
}

variable "results_bucket" {
  type        = string
  description = "S3 bucket name for benchmark results + binary distribution"
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  description = "Tailscale pre-auth key (generate at https://login.tailscale.com/admin/settings/keys)"
}

variable "tags" {
  type    = map(string)
  default = {}
}
