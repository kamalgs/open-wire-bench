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
  default = 3
  # 3 peers = 1-per-AZ spread and N*(N-1)/2 = 3 mesh edges, so every subject can
  # reach a peer via multiple paths. This exercises the RS+/RS- dedup and
  # one-hop-forwarding invariants; 2 peers have a single edge and skip those.
}

variable "hub_instance_type" {
  type    = string
  default = "c5n.xlarge"
}

variable "leaf_max_count" {
  type        = number
  default     = 1
  description = "Max leaf nodes in the ASG (desired starts at 0)"
}

variable "leaf_instance_type" {
  type    = string
  default = "c5n.xlarge"
}

variable "trading_instance_type" {
  type    = string
  default = "c5.xlarge"
}

variable "trading_sub_instance_type" {
  type    = string
  default = "c5.2xlarge"
}

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "operator_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
