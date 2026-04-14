variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "open-wire-bench"
}

variable "trading_instance_type" {
  type        = string
  default     = "c5.xlarge"
  description = "4 vCPU, 8 GB. c5n.xlarge for 25 Gbps."
}

variable "use_spot" {
  type        = bool
  default     = false
  description = "Use spot for trading-pub and trading-sub (broker is always on-demand). Default off — flip on for longer runs where churn is acceptable."
}

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "operator_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed to reach the Nomad server HTTP API on 4646"
}
