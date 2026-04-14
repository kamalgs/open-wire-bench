# modules/base — shared foundation for all bench environments.
#
# Creates:
#   - IAM role + instance profile (SSM + S3 results + ec2:Describe*)
#   - Security group (intra-VPC, plus Nomad 4646 from operator_cidr)
#   - Nomad server node (single instance, on-demand, public IP)
#   - S3 bucket for benchmark results + binary distribution
#
# Access model: operator reaches Nomad server via its public IP
# (NOMAD_ADDR=http://<public_ip>:4646). SG rule restricts port 4646
# to the operator_cidr. Worker nodes are reachable via SSM Session
# Manager for diagnostics.

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

# Prometheus EC2 service discovery queries the AWS API for running
# instances. Grants every node read-only ec2:Describe*; Prometheus only
# needs DescribeInstances but narrowing the IAM policy isn't worth the
# maintenance cost for a bench rig.
resource "aws_iam_role_policy" "ec2_describe" {
  name = "ec2-describe"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
      Resource = "*"
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
  description = "Intra-VPC + operator Nomad access"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "intra-VPC"
  }

  # Operator access to the Nomad server HTTP API.
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
    description = "Nomad HTTP from operator"
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
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.server_instance_type
  subnet_id                   = var.subnet_ids[0]
  iam_instance_profile        = aws_iam_instance_profile.node.name
  vpc_security_group_ids      = [aws_security_group.common.id]
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    nomad_version       = var.nomad_version
    is_server           = true
    server_ip           = ""
    node_class          = "server"
    node_hostname       = "${var.cluster_name}-server"
    auto_shutdown_hours = 0
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-server", Role = "server" })
}
