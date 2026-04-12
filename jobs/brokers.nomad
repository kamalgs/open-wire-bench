# jobs/brokers.nomad — run open-wire and nats-server side-by-side for benchmarking
#
# Both brokers run on the same node so benchmark measurements see identical
# hardware. open-wire listens on :4222, nats-server on :4333.
#
# Usage:
#   nomad job run -var="bin_dir=$(pwd)/bin" jobs/brokers.nomad

variable "bin_dir" {
  type        = string
  description = "Absolute path to directory containing open-wire and nats-server binaries"
}

variable "ow_workers" {
  type        = number
  default     = 2
  description = "open-wire worker thread count"
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
        args    = ["--port", "4222", "--workers", "${var.ow_workers}"]
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
        args    = ["-p", "4333"]
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
