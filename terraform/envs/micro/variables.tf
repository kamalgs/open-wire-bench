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
  description = "4 vCPU, 8 GB, Up to 10 Gbps. c5n.xlarge for 25 Gbps."
}

variable "use_spot" {
  type        = bool
  default     = true
  description = "Use spot instances for trading-pub and trading-sub (broker is always on-demand)"
}

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
