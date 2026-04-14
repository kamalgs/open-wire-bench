# S3 backend for micro env state.
#
# Bootstrap (one-time, before first `terraform init` in any env):
#   aws s3api create-bucket \
#     --bucket open-wire-bench-tfstate \
#     --region us-east-1
#   aws s3api put-bucket-versioning \
#     --bucket open-wire-bench-tfstate \
#     --versioning-configuration Status=Enabled
#   aws dynamodb create-table \
#     --table-name open-wire-bench-tfstate-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region us-east-1
#
# Each env (micro / mini / full) uses a distinct state key so they can be
# brought up independently.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "open-wire-bench-tfstate"
    key            = "envs/micro/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "open-wire-bench-tfstate-lock"
    encrypt        = true
  }
}
