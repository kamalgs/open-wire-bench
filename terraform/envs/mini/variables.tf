variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "open-wire-bench"
}

variable "hub_count" {
  type    = number
  default = 2
}

variable "hub_instance_type" {
  type        = string
  default     = "c5n.xlarge"
  description = "4 vCPU, 10.5 GB, 25 Gbps NIC"
}

variable "trading_instance_type" {
  type    = string
  default = "c5.xlarge"
}

variable "trading_sub_instance_type" {
  type        = string
  default     = "c5.2xlarge"
  description = "Subscriber instance type — default 8 vCPU so the Go user-shard loop doesn't cap the broker"
}

variable "use_spot" {
  type        = bool
  default     = false
  description = "Default on-demand; flip to true for longer runs."
}

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "operator_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
