variable "cluster_name" {
  type        = string
  description = "Name prefix for all resources"
}

variable "vpc_id"      { type = string }
variable "vpc_cidr"    { type = string }
variable "subnet_ids"  { type = list(string) }
variable "region"      { type = string }

variable "nomad_version" {
  type    = string
  default = "1.11.2"
}

variable "server_instance_type" {
  type    = string
  default = "t3.medium"
  description = "Nomad server + observability node"
}

variable "broker_instance_type" {
  type    = string
  default = "c5n.2xlarge"
  description = "Broker nodes — high network throughput (c5n = 25 Gbps)"
}

variable "sim_instance_type" {
  type    = string
  default = "c5.2xlarge"
  description = "Simulator (pub/sub) nodes"
}

variable "broker_count" {
  type    = number
  default = 3
}

variable "sim_count" {
  type    = number
  default = 2
}

variable "key_name" {
  type        = string
  default     = null
  description = "EC2 key pair name for SSH access. Null = SSM-only access."
}

variable "allowed_cidr" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach broker ports (4222/4333) and Nomad API (4646)"
}

variable "results_bucket" {
  type        = string
  description = "S3 bucket name for benchmark results"
}

variable "tags" {
  type    = map(string)
  default = {}
}
