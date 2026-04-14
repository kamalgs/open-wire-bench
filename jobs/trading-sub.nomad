# jobs/trading-sub.nomad — trading-sim subscriber shards (users)
#
# Batch job: runs for DURATION then exits cleanly.
# Result collection: each shard writes its JSON result to stdout as the
# LAST line; bench-trading.sh uses `nomad alloc logs` to extract it.

variable "broker_url" {
  type = string
}

variable "protocol" {
  type    = string
  default = "binary"
}

variable "sim_binary" {
  type = string
}

variable "users" {
  type    = number
  default = 200
}
variable "algo_users" {
  type    = number
  default = 20
}
variable "symbols" {
  type    = number
  default = 500
}
variable "visible" {
  type    = number
  default = 20
}
variable "size" {
  type    = number
  default = 128
}
variable "duration" {
  type    = string
  default = "120s"
}
variable "user_shards" {
  type    = number
  default = 4
}

job "trading-sub" {
  datacenters = ["dc1"]
  type        = "batch"

  constraint {
    attribute = "${node.class}"
    value     = "trading-sub"
  }

  group "users" {
    count = var.user_shards

    network { mode = "host" }

    task "shard" {
      driver = "raw_exec"

      artifact {
        source      = var.sim_binary
        destination = "local/trading-sim"
        mode        = "file"
      }

      config {
        command = "bash"
        args = ["-c", <<-EOF
          set -euo pipefail
          chmod +x local/trading-sim
          SHARD_ID=$${NOMAD_ALLOC_INDEX}

          # trading-sim writes heartbeats to stderr and the final JSON result
          # to stdout. Nomad captures both; bench-trading.sh collects the JSON
          # via `nomad alloc logs <alloc> shard`.
          local/trading-sim \
            --role users \
            --shard-id    "$SHARD_ID" \
            --shard-count ${var.user_shards} \
            --url         "${var.broker_url}" \
            --protocol    "${var.protocol}" \
            --users       ${var.users} \
            --algo-users  ${var.algo_users} \
            --symbols     ${var.symbols} \
            --visible     ${var.visible} \
            --size        ${var.size} \
            --duration    ${var.duration}
        EOF
        ]
      }

      resources {
        cpu    = 500
        memory = 256
      }

      logs {
        max_files     = 2
        max_file_size = 10
      }
    }
  }
}
