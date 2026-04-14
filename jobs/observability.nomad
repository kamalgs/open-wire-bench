# jobs/observability.nomad — Prometheus (scrape + store), runs on server node
#
# Targets are passed as comma-separated host:port lists from the bench
# orchestration (reads Terraform outputs).
#
# Deploy `node-exporter.nomad` separately (type=system) for per-node metrics.
#
# Usage:
#   nomad job run \
#     -var='node_targets=hub-0:9100,hub-1:9100,trading-pub:9100,trading-sub:9100' \
#     -var='ow_targets=hub-0:9101,hub-1:9101' \
#     jobs/observability.nomad

variable "prom_version" {
  type    = string
  default = "3.2.1"
}

variable "node_targets" {
  type        = string
  description = "Comma-separated host:9100 list for Prometheus to scrape (node_exporter targets)"
}

variable "ow_targets" {
  type        = string
  description = "Comma-separated host:9101 list for Prometheus to scrape (open-wire metrics)"
}

job "observability" {
  datacenters = ["dc1"]
  type        = "service"

  # Run Prometheus on the trading-pub node. It has spare CPU/mem between
  # bench runs, and its own CPU readings are not the metric we care about
  # (we compare broker-side CPU between protocols).
  constraint {
    attribute = "${node.class}"
    value     = "trading-pub"
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
            - job_name: node
              static_configs:
                - targets: [${join(", ", formatlist("'%s'", split(",", var.node_targets)))}]

            - job_name: open-wire
              static_configs:
                - targets: [${join(", ", formatlist("'%s'", split(",", var.ow_targets)))}]
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
