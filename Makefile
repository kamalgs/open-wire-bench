.PHONY: build brokers bench stop clean check

BIN_DIR  := $(shell pwd)/bin
SCENARIO ?= market-feed
ENV      ?= local
DURATION ?=

# ── Build ─────────────────────────────────────────────────────────────────────

build:
	bash scripts/build-local.sh

# ── Broker lifecycle ──────────────────────────────────────────────────────────

brokers:
	nomad job run -var="bin_dir=$(BIN_DIR)" jobs/brokers.nomad

stop:
	-nomad job stop -purge brokers 2>/dev/null || true

# ── Benchmark ─────────────────────────────────────────────────────────────────

bench:
	bash runs/bench.sh \
	    --scenario $(SCENARIO) \
	    --env $(ENV) \
	    $(if $(DURATION),--duration $(DURATION),)

# ── Environment check ─────────────────────────────────────────────────────────

check:
	bash bootstrap/local.sh

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f bin/open-wire bin/nats-server bin/market-sim bin/market-sub
