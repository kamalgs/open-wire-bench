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

variable "operator_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed to reach the Nomad server HTTP API on 4646. Default is open; narrow to your IP for production use."
}

variable "tags" {
  type    = map(string)
  default = {}
}
