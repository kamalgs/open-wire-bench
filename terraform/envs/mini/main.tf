# envs/mini — hub mesh cluster environment (no leaf tier).
#
# Composition:
#   base        → VPC, IAM, SG, Nomad server, S3 results bucket
#   hub         → 2 hub nodes (mesh cluster) + NLB
#   trading-pub → ASG (desired=0) — publishers point at hub NLB directly
#   trading-sub → ASG (desired=0) — subscribers point at hub NLB directly
#
# Total when running: Nomad server + 2 hub + 2 trading = 5 nodes.
#
# Use case: measure throughput/latency against a mesh cluster without the
# additional leaf hop. The trading workload hits the hub client ports
# (4222 / 4224 / 4333) via the internal NLB.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project     = "open-wire-bench"
    Environment = "mini"
    ManagedBy   = "terraform"
  }

  cluster_name   = "${var.cluster_name}-mini"
  results_bucket = "${var.cluster_name}-results"
}

module "vpc" {
  source = "../../modules/vpc"

  name   = local.cluster_name
  region = var.region
  tags   = local.tags
}

module "base" {
  source = "../../modules/base"

  cluster_name   = local.cluster_name
  vpc_id         = module.vpc.vpc_id
  vpc_cidr       = module.vpc.vpc_cidr
  subnet_ids     = module.vpc.subnet_ids
  results_bucket = local.results_bucket
  operator_cidr  = var.operator_cidr
  tags           = local.tags
}

module "hub" {
  source = "../../modules/hub"

  cluster_name              = local.cluster_name
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.subnet_ids
  ami_id                    = module.base.ami_id
  iam_instance_profile_name = module.base.iam_instance_profile_name
  security_group_id         = module.base.security_group_id
  server_private_ip         = module.base.server_private_ip
  user_data_template_path   = module.base.user_data_template_path
  hub_count                 = var.hub_count
  hub_instance_type         = var.hub_instance_type
  auto_shutdown_hours       = var.auto_shutdown_hours
  tags                      = local.tags
}

module "trading_pub" {
  source = "../../modules/trading-pub"

  cluster_name              = local.cluster_name
  subnet_id                 = module.vpc.subnet_ids[0]
  ami_id                    = module.base.ami_id
  iam_instance_profile_name = module.base.iam_instance_profile_name
  security_group_id         = module.base.security_group_id
  server_private_ip         = module.base.server_private_ip
  user_data_template_path   = module.base.user_data_template_path
  trading_instance_type     = var.trading_instance_type
  use_spot                  = var.use_spot
  tags                      = local.tags
}

module "trading_sub" {
  source = "../../modules/trading-sub"

  cluster_name              = local.cluster_name
  subnet_id                 = module.vpc.subnet_ids[0]
  ami_id                    = module.base.ami_id
  iam_instance_profile_name = module.base.iam_instance_profile_name
  security_group_id         = module.base.security_group_id
  server_private_ip         = module.base.server_private_ip
  user_data_template_path   = module.base.user_data_template_path
  # Subscriber side is CPU-bound in the Go shards at high load — use a
  # larger instance so the broker isn't starved. Hub binary throughput
  # is gated by sub CPU on c5.xlarge.
  trading_instance_type     = var.trading_sub_instance_type
  use_spot                  = var.use_spot
  tags                      = local.tags
}
