# jobs/trading-broker.nomad — standalone broker for trading-sim bench
#
# Runs open-wire and nats-server side-by-side on a single trading-broker node:
#   open-wire   :4222 (NATS protocol)  :4224 (binary protocol)  :9101 (metrics)
#   nats-server :4333 (NATS protocol)  :8333 (HTTP monitoring)
#
# Benchmark against open-wire:   --protocol binary --url <broker>:4224
# Benchmark against nats-server: --protocol nats   --url nats://<broker>:4333
#
# Usage:
#   nomad job run jobs/trading-broker.nomad

variable "ow_version" {
  type    = string
  default = "0.1.0"
}

variable "ow_binary" {
  type    = string
  default = ""
}

variable "ns_version" {
  type    = string
  default = "2.10.24"
}

variable "ow_workers" {
  type    = number
  default = 2
}

job "trading-broker" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${node.class}"
    value     = "trading-broker"
  }

  # ── open-wire ────────────────────────────────────────────────────────────────
  group "open-wire" {
    network {
      mode = "host"
    }

    task "server" {
      driver = "raw_exec"

      artifact {
        source      = var.ow_binary != "" ? var.ow_binary : "https://github.com/kamalgs/open-wire/releases/download/v${var.ow_version}/open-wire-linux-amd64"
        destination = "local/open-wire"
        mode        = "file"
      }

      config {
        command = "local/open-wire"
        args = [
          "--port",         "4222",
          "--binary-port",  "4224",
          "--workers",      "${var.ow_workers}",
          "--metrics-port", "9101",
        ]
      }

      resources {
        cpu    = 2000
        memory = 1024
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

      artifact {
        source      = "https://github.com/nats-io/nats-server/releases/download/v${var.ns_version}/nats-server-v${var.ns_version}-linux-amd64.tar.gz"
        destination = "local/"
      }

      config {
        command = "local/nats-server-v${var.ns_version}-linux-amd64/nats-server"
        args    = ["-p", "4333", "-m", "8333"]
      }

      resources {
        cpu    = 2000
        memory = 1024
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }
}
