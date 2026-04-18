# envs/mini — hand-rolled (no Nomad) hub mesh bench env.
#
# Nodes:
#   - 3× hub (c5n.large)  runs open-wire + nats-server via systemd
#   - 1× pub (c5.large)   idle; trading-sim launched via SSH per run
#   - 1× sub (c5.2xlarge) idle; trading-sim launched via SSH per run
#
# Total: 16 vCPU (fits "Running On-Demand Standard" quota).
#
# Flow:
#   1. Operator runs scripts/deploy-cloudinit.sh + scripts/deploy-binaries.sh
#      to populate s3://bucket/cloudinit/ and s3://bucket/bin/.
#   2. terraform apply brings up instances with user-data that pulls
#      /opt/bench/cloudinit/ from S3 and runs bootstrap.sh + role-<role>.sh.
#   3. Role scripts start systemd units (hub) or leave the node idle (pub/sub).
#   4. Operator runs scripts/bench-sweep.sh to drive benchmark runs via SSH.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "open-wire-bench"
      Environment = "mini"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  cluster_name   = var.cluster_name
  results_bucket = "${var.cluster_name}-results"
}

module "vpc" {
  source = "../../modules/vpc"

  name   = local.cluster_name
  region = var.region

  tags = {
    Project     = "open-wire-bench"
    Environment = "mini"
  }
}

# ── S3 bucket (binaries + cloudinit + results) ──────────────────────────────
resource "aws_s3_bucket" "bench" {
  bucket        = local.results_bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "bench" {
  bucket = aws_s3_bucket.bench.id
  versioning_configuration { status = "Enabled" }
}

# ── IAM ───────────────────────────────────────────────────────────────────
resource "aws_iam_role" "node" {
  name = "${local.cluster_name}-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM Session Manager (no SSH keys required for ops access)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bench_s3" {
  name = "bench-s3"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.bench.arn, "${aws_s3_bucket.bench.arn}/*"]
      },
      {
        # trading-sim uploads results via the bench-sync timer
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.bench.arn}/results/*"]
      },
    ]
  })
}

# Peer discovery via EC2 tags (hubs query each other's private IPs)
resource "aws_iam_role_policy" "ec2_describe" {
  name = "ec2-describe"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.cluster_name}-node"
  role = aws_iam_role.node.name
}

# ── Security group ───────────────────────────────────────────────────────
resource "aws_security_group" "bench" {
  name        = "${local.cluster_name}-bench"
  description = "Bench intra-VPC + operator SSH"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.vpc.vpc_cidr]
    description = "intra-VPC"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
    description = "operator SSH"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── SSH key pair (optional) ──────────────────────────────────────────────
resource "aws_key_pair" "operator" {
  count      = var.operator_ssh_pubkey == "" ? 0 : 1
  key_name   = "${local.cluster_name}-operator"
  public_key = var.operator_ssh_pubkey
}

# ── AMI: latest AL2023 (awscli + systemd preinstalled) ───────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-kernel-6.1-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── user_data template rendering ─────────────────────────────────────────
locals {
  # One cloud-init template, parameterized per role.
  user_data_template = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/bench-user-data.log 2>&1

    # Write per-node bench config that bootstrap/role scripts rely on
    mkdir -p /etc/bench /opt/bench/cloudinit
    cat > /etc/bench/env <<ENV
    BENCH_BUCKET=${local.results_bucket}
    BENCH_ENV=mini
    BENCH_ROLE=$${ROLE}
    BENCH_CLUSTER_NAME=${local.cluster_name}
    BENCH_OW_WORKERS=$${OW_WORKERS}
    BENCH_OW_SHARDS=$${OW_SHARDS}
    ENV

    # Placeholder versions file; bench script updates via SSH before
    # running a sweep. role-*.sh sources this to pick binary versions.
    cat > /etc/bench/versions <<VER
    OPEN_WIRE_VER=unset
    NATS_VER=unset
    TRADING_SIM_VER=unset
    VER

    echo "$${ROLE}" > /etc/bench/role

    # Pull cloudinit tree + run bootstrap + role script
    aws s3 sync "s3://${local.results_bucket}/cloudinit/" /opt/bench/cloudinit/
    chmod +x /opt/bench/cloudinit/scripts/*.sh

    # bootstrap first (common), role second
    bash /opt/bench/cloudinit/scripts/bootstrap.sh || true
    bash /opt/bench/cloudinit/scripts/role-$${ROLE}.sh || true
  EOT
}

# ── Hub instances (3× c5n.large) ─────────────────────────────────────────
resource "aws_instance" "hub" {
  count                = var.hub_count
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.hub_instance_type
  subnet_id            = element(module.vpc.subnet_ids, count.index)
  vpc_security_group_ids = [aws_security_group.bench.id]
  iam_instance_profile = aws_iam_instance_profile.node.name
  key_name             = length(aws_key_pair.operator) > 0 ? aws_key_pair.operator[0].key_name : null
  associate_public_ip_address = true

  user_data = replace(replace(replace(local.user_data_template,
    "$${ROLE}",       "hub"),
    "$${OW_WORKERS}", "2"),
    "$${OW_SHARDS}",  "2")

  tags = {
    Name        = "${local.cluster_name}-hub-${count.index}"
    Role        = "hub"
    Environment = "mini"
  }
}

# ── Pub (c5.large) ───────────────────────────────────────────────────────
resource "aws_instance" "pub" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.pub_instance_type
  subnet_id            = module.vpc.subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bench.id]
  iam_instance_profile = aws_iam_instance_profile.node.name
  key_name             = length(aws_key_pair.operator) > 0 ? aws_key_pair.operator[0].key_name : null
  associate_public_ip_address = true

  user_data = replace(replace(replace(local.user_data_template,
    "$${ROLE}",       "pub"),
    "$${OW_WORKERS}", "1"),
    "$${OW_SHARDS}",  "1")

  tags = {
    Name        = "${local.cluster_name}-pub"
    Role        = "pub"
    Environment = "mini"
  }
}

# ── Sub (c5.2xlarge) ─────────────────────────────────────────────────────
resource "aws_instance" "sub" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.sub_instance_type
  subnet_id            = module.vpc.subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bench.id]
  iam_instance_profile = aws_iam_instance_profile.node.name
  key_name             = length(aws_key_pair.operator) > 0 ? aws_key_pair.operator[0].key_name : null
  associate_public_ip_address = true

  user_data = replace(replace(replace(local.user_data_template,
    "$${ROLE}",       "sub"),
    "$${OW_WORKERS}", "1"),
    "$${OW_SHARDS}",  "1")

  tags = {
    Name        = "${local.cluster_name}-sub"
    Role        = "sub"
    Environment = "mini"
  }
}
