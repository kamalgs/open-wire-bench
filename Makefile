.PHONY: setup brokers observe bench stop clean check

BIN_DIR    := $(shell pwd)/bin
CONFIG_DIR := $(shell pwd)/configs
DATA_DIR   := $(shell pwd)/data
SCENARIO   ?= market-feed
ENV        ?= local
DURATION   ?=

# ── Setup ─────────────────────────────────────────────────────────────────────
# Downloads all binaries and builds Go simulators.
# For open-wire: downloads from GitHub releases, or warns to copy manually
# if the release is not yet published (local dev workflow).

setup:
	bash scripts/setup.sh

# ── Broker lifecycle ──────────────────────────────────────────────────────────

brokers:
	nomad job run -var="bin_dir=$(BIN_DIR)" jobs/brokers.nomad

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

run: brokers observe bench stop-observe

stop: stop-brokers stop-observe

# ── Environment check ─────────────────────────────────────────────────────────

check:
	bash bootstrap/local.sh

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f bin/prometheus bin/node_exporter bin/market-sim bin/market-sub
	rm -rf data/prometheus
