# jobs/leaf.nomad — leaf tier (open-wire + nats-server as leaf nodes upstream to hub)
#
# type=system: Nomad places exactly one allocation per leaf node automatically.
# No count to maintain — ASG desired_capacity is the single source of truth.
#
# Ports:
#   open-wire   :4222 client, :4224 binary client, :7422 (accept downstream leaf)
#   nats-server :4333 client, :8333 HTTP monitoring
#
# Usage:
#   nomad job run \
#     -var="ow_hub_url=nats://<hub-nlb>:7422" \
#     -var="ns_hub_urls=nats://<hub-nlb>:7333" \
#     jobs/leaf.nomad

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
  default = 4
}

variable "ow_hub_url" {
  type        = string
  description = "open-wire hub upstream URL (hub NLB port 7422)"
}

variable "ns_hub_urls" {
  type        = string
  description = "nats-server hub upstream URLs, comma-separated (hub NLB port 7333)"
}

variable "task_cpu" {
  type    = number
  default = 1500
}

job "leaf" {
  datacenters = ["dc1"]
  type        = "system"

  constraint {
    attribute = "${node.class}"
    value     = "leaf"
  }

  # ── open-wire leaf ───────────────────────────────────────────────────────────
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

      # Accept downstream connections so clients can chain through leaf.
      template {
        destination = "local/ow.conf"
        data        = <<-EOF
          leafnodes {
            listen: 0.0.0.0:7422
          }
        EOF
      }

      config {
        command = "local/open-wire"
        args = [
          "--config",       "local/ow.conf",
          "--port",         "4222",
          "--binary-port",  "4224",
          "--workers",      "${var.ow_workers}",
          "--metrics-port", "9101",
          "--hub",          "${var.ow_hub_url}",
        ]
      }

      resources {
        cpu    = var.task_cpu
        memory = 512
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }

  # ── nats-server leaf ─────────────────────────────────────────────────────────
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

      template {
        destination = "local/nats.conf"
        data        = <<-EOF
          port: 4333
          http: 8333

          leafnodes {
            remotes: [
              {
                urls: [${join(", ", formatlist("%q", split(",", var.ns_hub_urls)))}]
              }
            ]
          }
        EOF
      }

      config {
        command = "local/nats-server-v${var.ns_version}-linux-amd64/nats-server"
        args    = ["-c", "local/nats.conf"]
      }

      resources {
        cpu    = var.task_cpu
        memory = 512
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }
}
