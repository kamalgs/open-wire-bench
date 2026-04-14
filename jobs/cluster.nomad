# jobs/cluster.nomad — hub mesh cluster (open-wire + nats-server in cluster mode)
#
# type=system: Nomad places exactly one allocation per hub node automatically.
# No count to maintain — ASG desired_capacity is the single source of truth.
#
# Ports:
#   open-wire   :4222 client, :4224 binary client, :6222 cluster routes, :7422 leaf acceptor
#   nats-server :4333 client, :6333 cluster routes, :7333 leaf acceptor
#
# Usage:
#   nomad job run \
#     -var="ow_hub_seeds=open-wire-bench-hub-0:6222,open-wire-bench-hub-1:6222" \
#     -var="ns_hub_routes=nats-route://open-wire-bench-hub-0:6333,nats-route://open-wire-bench-hub-1:6333" \
#     jobs/cluster.nomad

variable "ow_version" {
  type    = string
  default = "0.1.0"
}

variable "ns_version" {
  type    = string
  default = "2.10.24"
}

variable "ow_workers" {
  type    = number
  default = 4
}

variable "cluster_name" {
  type    = string
  default = "open-wire-bench"
}

# Comma-separated host:port list — matches Terraform ow_hub_seeds output
variable "ow_hub_seeds" {
  type    = string
  default = "open-wire-bench-hub-0:6222,open-wire-bench-hub-1:6222"
}

# Comma-separated nats-route:// URLs — matches Terraform ns_hub_routes output
variable "ns_hub_routes" {
  type    = string
  default = "nats-route://open-wire-bench-hub-0:6333,nats-route://open-wire-bench-hub-1:6333"
}

# Per-task CPU in MHz.
# t3.medium (~5000 MHz total): 1500 fits two tasks per node.
# c5n.2xlarge (~32000 MHz total): 8000 gives each broker ample headroom.
variable "task_cpu" {
  type    = number
  default = 1500
}

job "cluster" {
  datacenters = ["dc1"]
  type        = "system"   # one allocation per matching node; count/distinct_hosts not needed

  constraint {
    attribute = "${node.class}"
    value     = "hub"
  }

  # ── open-wire mesh cluster ───────────────────────────────────────────────────
  group "open-wire" {
    network {
      mode = "host"
    }

    task "server" {
      driver = "raw_exec"

      artifact {
        source      = "https://github.com/kamalgs/open-wire/releases/download/v${var.ow_version}/open-wire-linux-amd64"
        destination = "local/open-wire"
        mode        = "file"
      }

      # Config file supplies only what CLI flags can't: the leafnodes listen block.
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
          "--config",        "local/ow.conf",
          "--port",          "4222",
          "--binary-port",   "4224",
          "--workers",       "${var.ow_workers}",
          "--metrics-port",  "9101",
          "--cluster-port",  "6222",
          "--cluster-name",  "${var.cluster_name}",
          "--cluster-seeds", "${var.ow_hub_seeds}",
        ]
      }

      resources {
        cpu    = var.task_cpu
        memory = 1024
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }

  # ── nats-server cluster ──────────────────────────────────────────────────────
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

          cluster {
            name: "${var.cluster_name}"
            listen: 0.0.0.0:6333
            routes: [
              ${join("\n              ", split(",", var.ns_hub_routes))}
            ]
          }

          leafnodes {
            listen: 0.0.0.0:7333
          }
        EOF
      }

      config {
        command = "local/nats-server-v${var.ns_version}-linux-amd64/nats-server"
        args    = ["-c", "local/nats.conf"]
      }

      resources {
        cpu    = var.task_cpu
        memory = 1024
      }

      logs {
        max_files     = 3
        max_file_size = 10
      }
    }
  }
}
