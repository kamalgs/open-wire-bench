# jobs/brokers.nomad — run open-wire and nats-server side-by-side for benchmarking
#
# Both brokers use host networking so there is no CNI overhead.
# open-wire on :4222 (metrics :9101), nats-server on :4333 (monitoring :8333).
#
# Usage:
#   nomad job run \
#     -var="open_wire_image=ghcr.io/kamalgs/open-wire:latest" \
#     jobs/brokers.nomad
#
# Or load variables from an env file:
#   nomad job run -var-file=envs/local.vars jobs/brokers.nomad

variable "open_wire_image" {
  type        = string
  description = "Full open-wire Docker image reference (registry/repo:tag)"
}

variable "nats_server_image" {
  type        = string
  default     = "nats:latest"
  description = "nats-server Docker image (Docker Hub official)"
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
    task "server" {
      driver = "docker"

      config {
        image        = var.open_wire_image
        network_mode = "host"
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
    task "server" {
      driver = "docker"

      config {
        image        = var.nats_server_image
        network_mode = "host"
        args = [
          "-p",  "4333",   # client port
          "-m",  "8333",   # HTTP monitoring (/varz /healthz)
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
