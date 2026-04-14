# jobs/node-exporter.nomad — node_exporter on every Nomad client node.
#
# Runs as type=system, so Nomad places exactly one allocation per matching
# client and auto-scales as nodes come and go. Exposes :9100/metrics.
#
# Deploy alongside jobs/observability.nomad (which runs Prometheus).
#
# Usage:
#   nomad job run jobs/node-exporter.nomad

variable "ne_version" {
  type    = string
  default = "1.9.1"
}

job "node-exporter" {
  datacenters = ["dc1"]
  type        = "system"

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
}
