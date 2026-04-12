# jobs/brokers.nomad — run open-wire and nats-server side-by-side for benchmarking
#
# Both brokers run as raw_exec tasks with pre-downloaded binaries.
# open-wire on :4222 (Prometheus metrics :9101)
# nats-server on :4333 (HTTP monitoring :8333)
#
# Binaries come from bin/ — populated by scripts/setup.sh which downloads
# pinned versions from GitHub Releases (same pattern as prometheus/node_exporter).
#
# Usage:
#   nomad job run -var="bin_dir=$(pwd)/bin" jobs/brokers.nomad

variable "bin_dir" {
  type        = string
  description = "Absolute path to directory containing open-wire and nats-server binaries"
}

variable "ow_workers" {
  type    = number
  default = 2
}

job "brokers" {
  datacenters = ["dc1"]
  type        = "service"

  # ── open-wire ────────────────────────────────────────────────────────────────
  group "open-wire" {
    network {
      mode = "host"
    }

    task "server" {
      driver = "raw_exec"

      config {
        command = "${var.bin_dir}/open-wire"
        args = [
          "--port",         "4222",
          "--workers",      "${var.ow_workers}",
          "--metrics-port", "9101",
        ]
      }

      resources {
        cpu    = 2000
        memory = 512
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }

  # ── nats-server ──────────────────────────────────────────────────────────────
  group "nats-server" {
    network {
      mode = "host"
    }

    task "server" {
      driver = "raw_exec"

      config {
        command = "${var.bin_dir}/nats-server"
        args = [
          "-p", "4333",
          "-m", "8333",
        ]
      }

      resources {
        cpu    = 2000
        memory = 512
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }
}
