# terraform/iam — bootstrap IAM resources for deployment
#
# Run this ONCE with temporary admin credentials to create the deploy user
# whose keys are then used for all subsequent `terraform apply` runs.
#
# Usage:
#   cd terraform/iam
#   terraform init
#   terraform apply          # uses your current AWS credentials (admin)
#   terraform output -json   # copy access_key_id and secret_access_key

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # No remote backend here intentionally — this is a bootstrap file.
  # State lives locally in terraform/iam/terraform.tfstate (gitignored).
}

provider "aws" {
  region = var.region
}

# ── Deploy user ───────────────────────────────────────────────────────────────
resource "aws_iam_user" "deploy" {
  name = "${var.project}-deploy"
  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_access_key" "deploy" {
  user = aws_iam_user.deploy.name
}

# ── Deploy policy ─────────────────────────────────────────────────────────────
# Principle of least privilege:
#   EC2 + VPC (create/manage benchmark instances and networking)
#   IAM (create instance profile — scoped to project prefix)
#   S3  (Terraform state bucket + results bucket)
#   DynamoDB (Terraform state locking)
#   SSM (for aws ssm start-session — no keys needed for shell access)

resource "aws_iam_user_policy" "deploy" {
  name   = "deploy"
  user   = aws_iam_user.deploy.name
  policy = data.aws_iam_policy_document.deploy.json
}

data "aws_iam_policy_document" "deploy" {
  # EC2 + VPC — full control (needed to create/destroy benchmark infra)
  statement {
    sid     = "EC2andVPC"
    effect  = "Allow"
    actions = ["ec2:*"]
    resources = ["*"]
  }

  # IAM — restricted to resources prefixed with project name
  statement {
    sid    = "IAMInstanceProfile"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [
      "arn:aws:iam::*:role/${var.project}-*",
      "arn:aws:iam::*:instance-profile/${var.project}-*",
    ]
  }

  # S3 — Terraform state + results bucket only
  statement {
    sid    = "S3TfState"
    effect = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${var.state_bucket}",
      "arn:aws:s3:::${var.state_bucket}/*",
      "arn:aws:s3:::${var.project}-results",
      "arn:aws:s3:::${var.project}-results/*",
    ]
  }

  # DynamoDB — Terraform state lock table only
  statement {
    sid     = "DynamoDBTfLock"
    effect  = "Allow"
    actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [
      "arn:aws:dynamodb:*:*:table/${var.state_lock_table}",
    ]
  }

  # SSM — needed to call aws ssm start-session from local machine
  statement {
    sid    = "SSMSession"
    effect = "Allow"
    actions = [
      "ssm:StartSession",
      "ssm:TerminateSession",
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
    ]
    resources = ["*"]
  }
}
