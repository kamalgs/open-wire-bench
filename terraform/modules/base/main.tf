# modules/base — shared foundation for all bench environments.
#
# Creates:
#   - IAM role + instance profile (SSM + S3 results access)
#   - Security group (intra-VPC unrestricted, no public ingress; operator
#     access flows over Tailscale)
#   - Nomad server node (single instance, on-demand, Tailscale-addressed)
#   - S3 bucket for benchmark results + binary distribution
#
# Every environment (micro / mini / full) composes on top of this.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── AMI ───────────────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── S3 bucket for results + binary distribution ───────────────────────────────
resource "aws_s3_bucket" "results" {
  bucket        = var.results_bucket
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id
  versioning_configuration { status = "Enabled" }
}

# ── IAM: instance profile ─────────────────────────────────────────────────────
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Nomad artifact stanza uses the instance profile to pull binaries from S3
# via go-getter's built-in AWS SDK (no awscli on the node required).
resource "aws_iam_role_policy" "results_s3" {
  name = "results-s3"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.results.arn,
        "${aws_s3_bucket.results.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}

# ── Security group ────────────────────────────────────────────────────────────
resource "aws_security_group" "common" {
  name        = "${var.cluster_name}-common"
  description = "Intra-VPC only; operator access via Tailscale"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "intra-VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-common" })

  lifecycle {
    ignore_changes = [description]
  }
}

# ── Nomad server node ─────────────────────────────────────────────────────────
resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.server_instance_type
  subnet_id              = var.subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  vpc_security_group_ids = [aws_security_group.common.id]

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    nomad_version       = var.nomad_version
    is_server           = true
    server_ip           = ""
    node_class          = "server"
    tailscale_auth_key  = var.tailscale_auth_key
    tailscale_hostname  = "${var.cluster_name}-server"
    auto_shutdown_hours = 0
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-server", Role = "server" })
}
