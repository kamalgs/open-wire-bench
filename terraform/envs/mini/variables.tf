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

variable "use_spot" {
  type    = bool
  default = true
}

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
