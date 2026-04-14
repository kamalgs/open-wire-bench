.PHONY: setup observe stop-observe brokers stop-brokers clean \
        trading-smoke trading-local trading-ssh trading-aggregate \
        trading-upload trading-up trading-down trading-bench \
        tf-init-micro tf-init-mini tf-init-full \
        tf-apply-micro tf-apply-mini tf-apply-full \
        tf-destroy-micro tf-destroy-mini tf-destroy-full \
        micro-up micro-bench micro-down \
        mini-up  mini-bench  mini-down \
        full-up  full-bench  full-down

SCENARIO ?= market-feed
DURATION ?=

AWS_REGION ?= us-east-1

# ── Trading bench defaults ────────────────────────────────────────────────────
TRADING_DURATION   ?= 120s
TRADING_USERS      ?= 200
TRADING_SYMBOLS    ?= 500
TRADING_SIZE       ?= 128
TRADING_OW_VERSION ?= 0.1.0
TRADING_PROTOCOLS  ?= binary,nats

TF_MICRO := terraform/envs/micro
TF_MINI  := terraform/envs/mini
TF_FULL  := terraform/envs/full

# ── Setup ─────────────────────────────────────────────────────────────────────
setup:
	bash scripts/setup.sh

# ── Observability (env-independent via EC2 service discovery) ────────────────
# Deploy once per env bring-up; Prometheus auto-discovers new/replaced
# instances by EC2 tag, so bench runs don't need to redeploy observability.
#
# Usage:
#   NOMAD_ADDR=$(terraform -chdir=terraform/envs/micro output -raw nomad_addr) make observe
observe:
	nomad job run jobs/node-exporter.nomad
	nomad job run -var="region=$(AWS_REGION)" jobs/observability.nomad

stop-observe:
	-nomad job stop -purge observability 2>/dev/null || true
	-nomad job stop -purge node-exporter 2>/dev/null || true

# ── Legacy: single-node local brokers job ─────────────────────────────────────
brokers:
	nomad job run jobs/brokers.nomad

stop-brokers:
	-nomad job stop -purge brokers 2>/dev/null || true

# ── trading-sim local ─────────────────────────────────────────────────────────
trading-smoke:
	bin/trading-sim --role all --duration 30s 2>&1 | tee results/trading-smoke.json

trading-local:
	bash simulators/trading-sim/run.sh local $(SCENARIO)

trading-ssh:
	bash simulators/trading-sim/run.sh ssh $(SCENARIO) $(HOSTS)

trading-aggregate:
	python3 simulators/trading-sim/aggregate.py results/trading-*.json

# ── Terraform envs ────────────────────────────────────────────────────────────
# Three independent environments — bring up only ONE at a time.
#
#   micro — single trading-broker node (baseline single-node bench)
#   mini  — 2-node hub mesh cluster (no leaf tier)
#   full  — leaf tier → hub mesh cluster (2-hop production topology)

tf-init-micro:
	terraform -chdir=$(TF_MICRO) init
tf-init-mini:
	terraform -chdir=$(TF_MINI) init
tf-init-full:
	terraform -chdir=$(TF_FULL) init

tf-apply-micro:
	terraform -chdir=$(TF_MICRO) apply
tf-apply-mini:
	terraform -chdir=$(TF_MINI) apply
tf-apply-full:
	terraform -chdir=$(TF_FULL) apply

tf-destroy-micro:
	terraform -chdir=$(TF_MICRO) destroy
tf-destroy-mini:
	terraform -chdir=$(TF_MINI) destroy
tf-destroy-full:
	terraform -chdir=$(TF_FULL) destroy

# ── One-shot: bring up env, run bench, tear down ──────────────────────────────
# Usage (pick the env you want):
#   make micro-up micro-bench micro-down
#   make mini-up mini-bench mini-down  TRADING_DURATION=60s
#   make full-up full-bench full-down  TRADING_PROTOCOLS=binary
#
# Tunable per run: TRADING_USERS, TRADING_SYMBOLS, TRADING_SIZE,
#                  TRADING_DURATION, TRADING_PROTOCOLS, TRADING_OW_VERSION

micro-up: tf-init-micro tf-apply-micro
mini-up:  tf-init-mini  tf-apply-mini
full-up:  tf-init-full  tf-apply-full

BENCH_RUN = bash scripts/bench-trading.sh \
                --env        $(1) \
                --region     $(AWS_REGION) \
                --duration   $(TRADING_DURATION) \
                --users      $(TRADING_USERS) \
                --symbols    $(TRADING_SYMBOLS) \
                --size       $(TRADING_SIZE) \
                --ow-version $(TRADING_OW_VERSION) \
                --protocols  $(TRADING_PROTOCOLS)

micro-bench:
	$(call BENCH_RUN,micro)
mini-bench:
	$(call BENCH_RUN,mini)
full-bench:
	$(call BENCH_RUN,full)

micro-down: tf-destroy-micro
mini-down:  tf-destroy-mini
full-down:  tf-destroy-full

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f bin/trading-sim bin/trading-sim-linux-amd64
