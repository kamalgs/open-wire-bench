provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project     = "open-wire-bench"
    Environment = "aws"
    ManagedBy   = "terraform"
  }

  results_bucket = "${var.cluster_name}-results"
}

# ── S3 bucket for benchmark results ──────────────────────────────────────────
resource "aws_s3_bucket" "results" {
  bucket        = local.results_bucket
  force_destroy = true  # allow destroy even if results exist
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id
  versioning_configuration { status = "Enabled" }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  name   = var.cluster_name
  region = var.region
  tags   = local.tags
}

# ── Nomad cluster ─────────────────────────────────────────────────────────────
module "cluster" {
  source = "../../modules/nomad-aws"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  vpc_cidr             = module.vpc.vpc_cidr
  subnet_ids           = module.vpc.subnet_ids
  region               = var.region
  broker_count         = var.broker_count
  sim_count            = var.sim_count
  broker_instance_type = var.broker_instance_type
  sim_instance_type    = var.sim_instance_type
  key_name             = var.key_name
  allowed_cidr         = var.allowed_cidr
  results_bucket       = local.results_bucket
  tags                 = local.tags
}
