terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "open-wire-bench-tfstate"
    key            = "envs/full/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "open-wire-bench-tfstate-lock"
    encrypt        = true
  }
}
