.PHONY: up down deploy bench clean cost

TF_DIR := terraform/envs/mini
AWS_REGION ?= us-east-1
SSH_PUBKEY ?= $(shell cat ~/.ssh/id_ed25519.pub 2>/dev/null)
# Experiment identifier stamped on every AWS resource as `Experiment=<value>`.
# Auto-generate a timestamp-based one if the user hasn't set EXPERIMENT.
EXPERIMENT ?= bench-$(shell date +%Y%m%dT%H%M%S)

# ── Cluster lifecycle ─────────────────────────────────────────────────────
up:
	terraform -chdir=$(TF_DIR) init -upgrade
	terraform -chdir=$(TF_DIR) apply -auto-approve \
	    -var "operator_ssh_pubkey=$(SSH_PUBKEY)" \
	    -var "experiment=$(EXPERIMENT)"
	@echo "==> Experiment tag: $(EXPERIMENT)"

down:
	terraform -chdir=$(TF_DIR) destroy -auto-approve \
	    -var "operator_ssh_pubkey=$(SSH_PUBKEY)" \
	    -var "experiment=$(EXPERIMENT)"

# ── Cost attribution ──────────────────────────────────────────────────────
# Query Cost Explorer for a given experiment tag. Requires one-time setup:
# AWS Billing Console -> Cost Allocation Tags -> activate `Experiment`.
# Data lag ~24-48h.
cost:
	@bash scripts/bench-cost.sh --experiment "$(EXPERIMENT)"

# ── Deploy (cloudinit + binaries) ─────────────────────────────────────────
deploy:
	@BUCKET=$$(terraform -chdir=$(TF_DIR) output -raw results_bucket); \
	bash scripts/deploy-cloudinit.sh --bucket $$BUCKET; \
	bash scripts/deploy-binaries.sh  --bucket $$BUCKET

# ── Bench (SSH-driven sweep) ─────────────────────────────────────────────
# Variables: USERS, DURATION, PROTOCOLS, REPS
USERS     ?= 4000
DURATION  ?= 60s
PROTOCOLS ?= binary,nats
REPS      ?= 1

bench:
	bash scripts/bench-sweep.sh \
	    --users     $(USERS) \
	    --duration  $(DURATION) \
	    --protocols $(PROTOCOLS) \
	    --reps      $(REPS)

clean:
	rm -rf results/[0-9]*
