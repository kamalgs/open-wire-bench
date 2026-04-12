# modules/nomad-aws — EC2-based Nomad cluster for benchmarking
#
# Topology:
#   1 server node  (t3.medium)    — Nomad server + Prometheus + Grafana
#   N broker nodes (c5n.2xlarge)  — open-wire + nats-server, node_class=broker
#   M sim nodes    (c5.2xlarge)   — market-sim + market-sub, node_class=sim

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

# ── IAM instance profile (SSM + S3 results) ───────────────────────────────────
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

# SSM Session Manager — shell access without bastion or SSH keys
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 — read/write benchmark results
resource "aws_iam_role_policy" "results_s3" {
  name = "results-s3"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.results_bucket}",
        "arn:aws:s3:::${var.results_bucket}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}

# ── Security groups ───────────────────────────────────────────────────────────

# Common: internal cluster communication
resource "aws_security_group" "common" {
  name        = "${var.cluster_name}-common"
  description = "Intra-cluster: Nomad + Prometheus + node_exporter"
  vpc_id      = var.vpc_id

  # All traffic within the VPC
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "intra-VPC"
  }

  # Outbound: unrestricted (downloading binaries, apt packages)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-common" })
}

# Server: Nomad API + SSH (operator access)
resource "aws_security_group" "server" {
  name        = "${var.cluster_name}-server"
  description = "Nomad server — HTTP API and SSH for operator access"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
    description = "Nomad HTTP API"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
    description = "SSH"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-server" })
}

# Broker: NATS client ports (open-wire :4222, nats-server :4333)
resource "aws_security_group" "broker" {
  name        = "${var.cluster_name}-broker"
  description = "Broker nodes — NATS client ports accessible from operator"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 4222
    to_port     = 4222
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
    description = "open-wire NATS"
  }

  ingress {
    from_port   = 4333
    to_port     = 4333
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr
    description = "nats-server NATS"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-broker" })
}

# ── EC2: server node ──────────────────────────────────────────────────────────
resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.server_instance_type
  subnet_id              = var.subnet_ids[0]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name
  vpc_security_group_ids = [aws_security_group.common.id, aws_security_group.server.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    nomad_version = var.nomad_version
    is_server     = true
    server_ip     = ""        # server advertises its own private IP from metadata
    node_class    = "server"
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-server", Role = "server" })
}

# ── EC2: broker nodes ─────────────────────────────────────────────────────────
resource "aws_instance" "broker" {
  count                  = var.broker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.broker_instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name
  vpc_security_group_ids = [aws_security_group.common.id, aws_security_group.broker.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    nomad_version = var.nomad_version
    is_server     = false
    server_ip     = aws_instance.server.private_ip
    node_class    = "broker"
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-broker-${count.index}", Role = "broker" })
  depends_on = [aws_instance.server]
}

# ── EC2: sim nodes ────────────────────────────────────────────────────────────
resource "aws_instance" "sim" {
  count                  = var.sim_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.sim_instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name
  vpc_security_group_ids = [aws_security_group.common.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    nomad_version = var.nomad_version
    is_server     = false
    server_ip     = aws_instance.server.private_ip
    node_class    = "sim"
  }))

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-sim-${count.index}", Role = "sim" })
  depends_on = [aws_instance.server]
}
