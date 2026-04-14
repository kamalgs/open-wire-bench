# jobs/observability.nomad — Prometheus + node_exporter for benchmark metric capture
#
# Nomad downloads binaries via artifact stanzas — no pre-placed files needed.
# Prometheus config is rendered inline via template stanza.
#
# Run before starting a benchmark, stop after results are saved.
# Prometheus retains 1 day of data; query the run window via /api/v1/query_range.
#
# Usage:
#   nomad job run jobs/observability.nomad

variable "prom_version" {
  type    = string
  default = "3.2.1"
}

variable "ne_version" {
  type    = string
  default = "1.9.1"
}

# IP of the broker node — Prometheus scrapes open-wire metrics from here.
# Override with the actual broker Tailscale IP or hostname.
variable "broker_addr" {
  type    = string
  default = "localhost"
}

job "observability" {
  datacenters = ["dc1"]
  type        = "service"

  # Run on the server node (not broker) to avoid interfering with broker perf
  constraint {
    attribute = "${node.class}"
    value     = "server"
  }

  # ── node_exporter ─────────────────────────────────────────────────────────────
  group "node-exporter" {
    network {
      mode = "host"
    }

    task "node-exporter" {
      driver = "raw_exec"

      artifact {
        source      = "https://github.com/prometheus/node_exporter/releases/download/v${var.ne_version}/node_exporter-${var.ne_version}.linux-amd64.tar.gz"
        destination = "local/"
      }

      config {
        command = "local/node_exporter-${var.ne_version}.linux-amd64/node_exporter"
        args = [
          "--web.listen-address=:9100",
          "--no-collector.mdadm",
          "--no-collector.zfs",
          "--no-collector.nfs",
          "--no-collector.nfsd",
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }

  # ── Prometheus ────────────────────────────────────────────────────────────────
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

      # Render prometheus.yml into the task's local/ directory
      template {
        destination = "local/prometheus.yml"
        data        = <<-EOT
          global:
            scrape_interval: 5s

          scrape_configs:
            - job_name: node
              static_configs:
                - targets: ['localhost:9100']

            - job_name: open-wire
              static_configs:
                - targets: ['{{ env "NOMAD_VAR_broker_addr" }}:9101']
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
        cpu    = 200
        memory = 256
      }
    }
  }
}
