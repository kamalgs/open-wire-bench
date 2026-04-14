#!/usr/bin/env bash
# scripts/upload-trading-sim.sh — cross-compile trading-sim for linux/amd64 and upload to S3.
#
# Usage:
#   ./scripts/upload-trading-sim.sh --bucket open-wire-bench-results [--region us-east-1]
#
# The binary is uploaded to:
#   s3://<bucket>/binaries/trading-sim
#
# The Nomad artifact stanza downloads it with:
#   source = "s3::https://s3.amazonaws.com/<bucket>/binaries/trading-sim"
set -euo pipefail

BUCKET=""
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)  BUCKET="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
  echo "Usage: $0 --bucket <s3-bucket> [--region <region>]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SIM_DIR="$REPO_ROOT/simulators/trading-sim"
BIN_DIR="$REPO_ROOT/bin"
OUT="$BIN_DIR/trading-sim-linux-amd64"

echo "==> Building trading-sim for linux/amd64..."
cd "$SIM_DIR"
GOOS=linux GOARCH=amd64 go build -o "$OUT" .
echo "    Built: $OUT ($(du -sh "$OUT" | cut -f1))"

echo "==> Uploading to s3://$BUCKET/binaries/trading-sim..."
aws s3 cp "$OUT" "s3://$BUCKET/binaries/trading-sim" \
    --region "$REGION" \
    --no-progress
echo "    Done."

echo ""
echo "Nomad artifact source:"
echo "  s3::https://s3.amazonaws.com/$BUCKET/binaries/trading-sim"
