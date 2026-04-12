.PHONY: setup brokers observe bench stop clean check

BIN_DIR    := $(shell pwd)/bin
CONFIG_DIR := $(shell pwd)/configs
DATA_DIR   := $(shell pwd)/data
SCENARIO   ?= market-feed
ENV        ?= local
DURATION   ?=

# ── Setup ─────────────────────────────────────────────────────────────────────
# Downloads observability binaries and builds Go simulators.
# open-wire and nats-server are pulled as Docker images by Nomad.

setup:
	bash scripts/setup.sh

# ── Broker lifecycle ──────────────────────────────────────────────────────────

# Local dev uses raw_exec with binaries in bin/ (image not required).
# Cloud targets use the Docker image job (set ENV=aws or similar).
brokers:
ifeq ($(ENV),local)
	nomad job run -var="bin_dir=$(BIN_DIR)" jobs/brokers-dev.nomad
else
	nomad job run -var-file=envs/$(ENV).vars jobs/brokers.nomad
endif

stop-brokers:
	-nomad job stop -purge brokers 2>/dev/null || true

# ── Observability lifecycle ───────────────────────────────────────────────────

observe:
	mkdir -p $(DATA_DIR)
	nomad job run \
	    -var="bin_dir=$(BIN_DIR)" \
	    -var="config_dir=$(CONFIG_DIR)" \
	    -var="data_dir=$(DATA_DIR)" \
	    jobs/observability.nomad

stop-observe:
	-nomad job stop -purge observability 2>/dev/null || true

# ── Benchmark ─────────────────────────────────────────────────────────────────

bench:
	bash runs/bench.sh \
	    --scenario $(SCENARIO) \
	    --env $(ENV) \
	    $(if $(DURATION),--duration $(DURATION),)

# ── Convenience ───────────────────────────────────────────────────────────────

# Start everything, run the default scenario, stop observability.
run: brokers observe bench stop-observe

stop: stop-brokers stop-observe

# ── Environment check ─────────────────────────────────────────────────────────

check:
	bash bootstrap/local.sh

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f bin/prometheus bin/node_exporter bin/market-sim bin/market-sub
	rm -rf data/prometheus
