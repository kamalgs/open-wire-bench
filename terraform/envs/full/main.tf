# envs/full — leaf + hub topology (production-shape).
#
# Composition:
#   base        → VPC, IAM, SG, Nomad server, S3 results bucket
#   hub         → 2 hub nodes (mesh cluster) + NLB
#   leaf        → leaf ASG + NLB (upstream to hub)
#   trading-pub → ASG (desired=0) — publishers point at leaf NLB
#   trading-sub → ASG (desired=0) — subscribers point at leaf NLB
#
# Total when running: Nomad server + 2 hub + 1+ leaf + 2 trading = 6+ nodes.
#
# Use case: two-hop production topology (clients → leaf → hub mesh). Matches
# how a real deployment fans clients through a leaf tier.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project     = "open-wire-bench"
    Environment = "full"
    ManagedBy   = "terraform"
  }

  cluster_name   = "${var.cluster_name}-full"
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

  cluster_name       = local.cluster_name
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  subnet_ids         = module.vpc.subnet_ids
  results_bucket     = local.results_bucket
  tailscale_auth_key = var.tailscale_auth_key
  tags               = local.tags
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
  tailscale_auth_key        = var.tailscale_auth_key
  auto_shutdown_hours       = var.auto_shutdown_hours
  tags                      = local.tags
}

module "leaf" {
  source = "../../modules/leaf"

  cluster_name              = local.cluster_name
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.subnet_ids
  ami_id                    = module.base.ami_id
  iam_instance_profile_name = module.base.iam_instance_profile_name
  security_group_id         = module.base.security_group_id
  server_private_ip         = module.base.server_private_ip
  user_data_template_path   = module.base.user_data_template_path
  leaf_max_count            = var.leaf_max_count
  leaf_instance_type        = var.leaf_instance_type
  use_spot                  = var.use_spot
  tailscale_auth_key        = var.tailscale_auth_key
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
  tailscale_auth_key        = var.tailscale_auth_key
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
  trading_instance_type     = var.trading_instance_type
  use_spot                  = var.use_spot
  tailscale_auth_key        = var.tailscale_auth_key
  tags                      = local.tags
}
