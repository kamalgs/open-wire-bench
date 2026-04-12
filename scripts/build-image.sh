#!/usr/bin/env bash
# scripts/build-image.sh — build open-wire Docker image from a pre-built binary
#
# For local development only. In CI, the image is built from the nats_rust
# repo and pushed to ghcr.io.
#
# Requires bin/open-wire to exist (copy from nats_rust/target/release/open-wire,
# or run: cp ../nats_rust/target/release/open-wire bin/).
#
# Usage:
#   ./scripts/build-image.sh [TAG]
#   TAG defaults to ghcr.io/kamalgs/open-wire:latest

set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-ghcr.io/kamalgs/open-wire:latest}"
BIN="bin/open-wire"

[[ -f "$BIN" ]] || {
    echo "bin/open-wire not found."
    echo "Copy it from the nats_rust repo:"
    echo "  cp ../nats_rust/target/release/open-wire bin/"
    exit 1
}

echo "Building Docker image: $TAG"
docker build -t "$TAG" -f docker/open-wire.Dockerfile .
echo "Done: $TAG"
