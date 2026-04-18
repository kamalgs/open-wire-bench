variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "open-wire-bench"
}

variable "state_bucket" {
  type    = string
  default = "open-wire-bench-tfstate"
}

variable "state_lock_table" {
  type    = string
  default = "open-wire-bench-tfstate-lock"
}
