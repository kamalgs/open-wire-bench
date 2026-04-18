variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "open-wire-bench-mini-simple"
}

variable "operator_cidr" {
  description = "CIDR allowed to SSH into instances. Default 0.0.0.0/0 for a bench; tighten in prod."
  type        = string
  default     = "0.0.0.0/0"
}

variable "operator_ssh_pubkey" {
  description = "Public SSH key installed on all instances. Leave empty to use SSM only."
  type        = string
  default     = ""
}

# Quota-compatible sizing: 6 (3×c5n.large hubs) + 2 (c5.large pub) + 8 (c5.2xlarge sub) = 16 vCPU.
# No Nomad server => fits the 16 vCPU "Running On-Demand Standard" quota with room for 3 hubs + 8-vCPU sub.
variable "hub_count" {
  type    = number
  default = 3
}

variable "hub_instance_type" {
  type    = string
  default = "c5n.large"
}

variable "pub_instance_type" {
  type    = string
  default = "c5.large"
}

variable "sub_instance_type" {
  type    = string
  default = "c5.2xlarge"
}

# Tag-based lifecycle; instances auto-stop after N hours if the env is left up.
variable "auto_shutdown_hours" {
  type    = number
  default = 4
}
