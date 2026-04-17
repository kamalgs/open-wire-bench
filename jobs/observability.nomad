# jobs/observability.nomad — Prometheus with EC2 service discovery.
#
# Prometheus auto-discovers scrape targets by querying the AWS EC2 API
# for running instances tagged Project=open-wire-bench. No static target
# lists to maintain, no redeploy when ASG instances are replaced.
#
# Two scrape jobs:
#   node      → every node on :9100 (node_exporter from node-exporter.nomad)
#   open-wire → hub + leaf + trading-broker nodes on :9101 (open-wire --metrics-port)
#
# Runs on the trading-pub class (spare capacity between bench runs). If
# the host node gets replaced, Nomad reschedules Prometheus — its local
# TSDB is ephemeral so historical data is lost on migration. For
# long-lived metrics, add a remote_write sink.
#
# Usage:
#   nomad job run -var="region=us-east-1" jobs/observability.nomad

variable "prom_version" {
  type    = string
  default = "3.2.1"
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for EC2 service discovery"
}

variable "project_tag" {
  type        = string
  default     = "open-wire-bench"
  description = "EC2 tag:Project value used as a discovery filter"
}

job "observability" {
  datacenters = ["dc1"]
  type        = "service"

  # Lands on the first always-up class Nomad finds: trading-broker (micro),
  # hub (mini / full), or leaf (full). Regexp lets one job manifest work
  # across all envs without passing env-specific vars.
  constraint {
    attribute = "${node.class}"
    operator  = "regexp"
    value     = "^(trading-broker|hub|leaf)$"
  }

  group "prometheus" {
    network {
      mode = "host"
    }

    task "prometheus" {
      driver = "raw_exec"

      artifact {
        source      = "https://github.com/prometheus/prometheus/releases/download/v${var.prom_version}/prometheus-${var.prom_version}.linux-amd64.tar.gz"
        destination = "local/"
      }

      template {
        destination = "local/prometheus.yml"
        data = <<-EOT
          global:
            scrape_interval: 5s
            evaluation_interval: 5s

          scrape_configs:
            # node_exporter on every bench CLIENT instance (not the
            # Nomad server — it doesn't run node_exporter). Filters
            # require all conditions to match.
            - job_name: node
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9100
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-broker', 'hub', 'leaf', 'trading-pub', 'trading-sub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - source_labels: [__meta_ec2_tag_Role]
                  target_label: role
                - source_labels: [__meta_ec2_tag_Environment]
                  target_label: env

            # open-wire self-reported metrics (runs only on hub / leaf /
            # trading-broker nodes — filter by Role tag).
            - job_name: open-wire
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9101
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['hub', 'leaf', 'trading-broker']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - source_labels: [__meta_ec2_tag_Role]
                  target_label: role
                - source_labels: [__meta_ec2_tag_Environment]
                  target_label: env

            # trading-sim metrics (publishers + subscribers).
            # Shards bind distinct ports on one host:
            #   market:   9102 + shard_id (up to 4)
            #   accounts: 9112 + shard_id (up to 2)
            #   users:    9122 + shard_id (up to 4)
            # Unused ports return scrape errors; Prometheus tolerates silently.
            - job_name: trading-market-0
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9102
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-pub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'market'
            - job_name: trading-market-1
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9103
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-pub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'market'
            - job_name: trading-accounts-0
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9112
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-pub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'accounts'
            - job_name: trading-users-0
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9122
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-sub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'users'
            - job_name: trading-users-1
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9123
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-sub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'users'
            - job_name: trading-users-2
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9124
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-sub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'users'
            - job_name: trading-users-3
              ec2_sd_configs:
                - region: ${var.region}
                  port: 9125
                  filters:
                    - name: 'tag:Project'
                      values: ['${var.project_tag}']
                    - name: 'tag:Role'
                      values: ['trading-sub']
                    - name: 'instance-state-name'
                      values: ['running']
              relabel_configs:
                - source_labels: [__meta_ec2_tag_Name]
                  target_label: instance
                - target_label: role
                  replacement: 'users'
        EOT
      }

      config {
        command = "local/prometheus-${var.prom_version}.linux-amd64/prometheus"
        args = [
          "--config.file=local/prometheus.yml",
          "--storage.tsdb.path=local/data",
          "--storage.tsdb.retention.time=1d",
          "--web.listen-address=:9092",
          "--log.level=warn",
        ]
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
