# jobs/observability.nomad — Prometheus + node_exporter for benchmark metric capture
#
# Run before starting a benchmark, stop after results are saved.
# Prometheus retains 1 day of data; query the run window via /api/v1/query_range.
#
# Usage:
#   nomad job run \
#     -var="bin_dir=$(pwd)/bin" \
#     -var="config_dir=$(pwd)/configs" \
#     -var="data_dir=$(pwd)/data" \
#     jobs/observability.nomad

variable "bin_dir" {
  type        = string
  description = "Absolute path to directory containing prometheus and node_exporter"
}

variable "config_dir" {
  type        = string
  description = "Absolute path to configs/ directory (contains prometheus.yml)"
}

variable "data_dir" {
  type        = string
  description = "Absolute path for Prometheus TSDB storage (persists across restarts)"
}

job "observability" {
  datacenters = ["dc1"]
  type        = "service"

  # ── node_exporter ─────────────────────────────────────────────────────────────
  # Exposes host CPU, memory, network, disk, filesystem metrics at :9100.
  # Runs as raw_exec so it can read /proc and /sys without privilege escalation.
  group "node-exporter" {
    network {
      mode = "host"
    }

    task "node-exporter" {
      driver = "raw_exec"

      config {
        command = "${var.bin_dir}/node_exporter"
        args = [
          "--web.listen-address=:9100",
          # Disable collectors that are noisy or irrelevant for benchmarking
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
  # Scrapes node_exporter + open-wire metrics every 5s.
  # Query API at :9090 for post-run analysis.
  group "prometheus" {
    network {
      mode = "host"
    }

    task "prometheus" {
      driver = "raw_exec"

      config {
        command = "${var.bin_dir}/prometheus"
        args = [
          "--config.file=${var.config_dir}/prometheus.yml",
          "--storage.tsdb.path=${var.data_dir}/prometheus",
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
