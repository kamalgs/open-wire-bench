variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "open-wire-bench"
}

variable "broker_count" {
  type    = number
  default = 3
}

variable "sim_count" {
  type    = number
  default = 2
}

variable "broker_instance_type" {
  type    = string
  default = "c5n.2xlarge"
}

variable "sim_instance_type" {
  type    = string
  default = "c5.2xlarge"
}

variable "key_name" {
  type        = string
  default     = null
  description = "EC2 key pair for SSH. Null = SSM-only access."
}

# Restrict broker ports + Nomad API to your IP.
# Find yours: curl -s ifconfig.me
variable "allowed_cidr" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
