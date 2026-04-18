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

variable "auto_shutdown_hours" {
  type    = number
  default = 4
}

variable "operator_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
