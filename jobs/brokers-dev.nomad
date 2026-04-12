# jobs/brokers-dev.nomad — local development variant using raw_exec
#
# For use when the open-wire Docker image is not yet published.
# Requires bin/open-wire and bin/nats-server to exist (see scripts/setup.sh
# and scripts/build-image.sh for how to populate bin/).
#
# For cloud deployments where images are published, use jobs/brokers.nomad.
#
# Usage:
#   nomad job run -var="bin_dir=$(pwd)/bin" jobs/brokers-dev.nomad

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
