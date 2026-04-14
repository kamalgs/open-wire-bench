# envs/micro — minimal single-node broker environment.
#
# Composition:
#   base           → VPC, IAM, SG, Nomad server, S3 results bucket
#   trading-broker → single c5.xlarge running open-wire + nats-server
#   trading-pub    → ASG (desired=0)  — 2 market shards + 1 accounts shard
#   trading-sub    → ASG (desired=0)  — 4 user shards
#
# Total: 4 nodes when the bench is running, ~$0.70/hr on-demand.
#
# Use case: baseline single-node throughput/latency, open-wire vs nats-server.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project     = "open-wire-bench"
    Environment = "micro"
    ManagedBy   = "terraform"
  }

  cluster_name   = "${var.cluster_name}-micro"
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

module "trading_broker" {
  source = "../../modules/trading-broker"

  cluster_name              = local.cluster_name
  subnet_id                 = module.vpc.subnet_ids[0]
  ami_id                    = module.base.ami_id
  iam_instance_profile_name = module.base.iam_instance_profile_name
  security_group_id         = module.base.security_group_id
  server_private_ip         = module.base.server_private_ip
  user_data_template_path   = module.base.user_data_template_path
  trading_instance_type     = var.trading_instance_type
  tailscale_auth_key        = var.tailscale_auth_key
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
