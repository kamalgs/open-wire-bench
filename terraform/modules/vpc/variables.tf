variable "name"   { type = string }
variable "region" { type = string }

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["a", "b"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
