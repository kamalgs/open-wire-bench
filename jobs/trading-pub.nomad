# jobs/trading-pub.nomad — trading-sim publisher shards (market + accounts)
#
# Batch job: runs for DURATION then exits cleanly.
# Result collection: each shard writes its JSON result to stdout as the
# LAST line; bench-trading.sh uses `nomad alloc logs` to extract it.
#
# Variables:
#   broker_url   — broker address (host:port for binary, nats://host:port for nats)
#   protocol     — "binary" or "nats"
#   sim_binary   — S3 URL for the trading-sim binary (Nomad artifact stanza
#                  uses go-getter's AWS SDK with instance profile creds — no
#                  awscli on the node required)
#
# Usage:
#   nomad job run \
#     -var="broker_url=open-wire-bench-trading-broker:4224" \
#     -var="protocol=binary" \
#     -var="sim_binary=s3::https://s3.amazonaws.com/open-wire-bench-results/binaries/trading-sim" \
#     jobs/trading-pub.nomad

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
variable "market_shards" {
  type    = number
  default = 2
}
variable "account_shards" {
  type    = number
  default = 1
}

job "trading-pub" {
  datacenters = ["dc1"]
  type        = "batch"

  constraint {
    attribute = "${node.class}"
    value     = "trading-pub"
  }

  # ── market shards ────────────────────────────────────────────────────────────
  group "market" {
    count = var.market_shards

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
          # to stdout. Nomad captures both in allocation logs; bench-trading.sh
          # pulls the JSON via `nomad alloc logs <alloc> shard`.
          local/trading-sim \
            --role market \
            --shard-id    "$SHARD_ID" \
            --shard-count ${var.market_shards} \
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

  # ── accounts shard ───────────────────────────────────────────────────────────
  group "accounts" {
    count = var.account_shards

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

          local/trading-sim \
            --role accounts \
            --shard-id    "$SHARD_ID" \
            --shard-count ${var.account_shards} \
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
        cpu    = 300
        memory = 128
      }

      logs {
        max_files     = 2
        max_file_size = 10
      }
    }
  }
}
