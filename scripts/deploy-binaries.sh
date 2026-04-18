#!/usr/bin/env bash
# Build and upload binaries to s3://bucket/bin/<tool>/<version>/<tool>.
#
# Versions are content-addressed:
#   - open-wire    → git sha of the nats_rust repo (sibling to this one)
#   - trading-sim  → git sha of this repo
#   - nats-server  → --nats-version flag (from release tarball)
#
# After upload, writes /etc/bench/versions content to stdout — caller
# (bench-sweep.sh) uses this to SSH-update the version pointers on each
# node before running a sweep.
set -euo pipefail

BUCKET=""
REGION="us-east-1"
NATS_VERSION="2.10.20"
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)        BUCKET="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --nats-version)  NATS_VERSION="$2"; shift 2 ;;
    --skip-build)    SKIP_BUILD=true; shift ;;
    -h|--help) sed -n '1,15p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BUCKET" ]] && { echo "Missing --bucket" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OW_REPO="$(cd "$REPO_ROOT/../nats_rust" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ── open-wire ──────────────────────────────────────────────────────────────
OW_SHA=$(git -C "$OW_REPO" rev-parse --short=12 HEAD)
if [[ "$SKIP_BUILD" != "true" ]]; then
  log "building open-wire ($OW_SHA) in $OW_REPO"
  cargo build --release --manifest-path "$OW_REPO/Cargo.toml" --quiet
fi
mkdir -p "$STAGE/open-wire/$OW_SHA"
cp "$OW_REPO/target/release/open-wire" "$STAGE/open-wire/$OW_SHA/open-wire"

# ── trading-sim ────────────────────────────────────────────────────────────
SIM_SHA=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)
if [[ "$SKIP_BUILD" != "true" ]]; then
  log "building trading-sim ($SIM_SHA)"
  (cd "$REPO_ROOT/simulators/trading-sim" && \
   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$STAGE/trading-sim/$SIM_SHA/trading-sim" .)
else
  mkdir -p "$STAGE/trading-sim/$SIM_SHA"
  cp "$REPO_ROOT/bin/trading-sim-linux-amd64" "$STAGE/trading-sim/$SIM_SHA/trading-sim"
fi

# ── nats-server ────────────────────────────────────────────────────────────
log "fetching nats-server v$NATS_VERSION"
NATS_URL="https://github.com/nats-io/nats-server/releases/download/v$NATS_VERSION/nats-server-v$NATS_VERSION-linux-amd64.tar.gz"
mkdir -p "$STAGE/nats-server/v$NATS_VERSION"
curl -sSL "$NATS_URL" | tar -xz -C "$STAGE/nats-server/v$NATS_VERSION" --strip-components=1 "nats-server-v$NATS_VERSION-linux-amd64/nats-server"

# ── upload ─────────────────────────────────────────────────────────────────
log "uploading to s3://$BUCKET/bin/"
aws s3 sync --region "$REGION" "$STAGE/" "s3://$BUCKET/bin/" --size-only

# ── emit versions snippet ──────────────────────────────────────────────────
cat <<VERSIONS
OPEN_WIRE_VER=$OW_SHA
NATS_VER=v$NATS_VERSION
TRADING_SIM_VER=$SIM_SHA
VERSIONS
