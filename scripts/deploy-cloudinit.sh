#!/usr/bin/env bash
# Deploy the cloudinit/ tree to S3 so EC2 instances can pull it on boot
# (or via bench-sync.timer for running instances).
#
# Usage:
#   ./scripts/deploy-cloudinit.sh --bucket open-wire-bench-results
set -euo pipefail

BUCKET=""
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help) sed -n '1,10p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
  echo "Missing --bucket" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDINIT="$REPO_ROOT/cloudinit"

if [[ ! -d "$CLOUDINIT" ]]; then
  echo "cloudinit/ not found at $CLOUDINIT" >&2
  exit 1
fi

SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

echo "==> Deploying cloudinit/ from $REPO_ROOT (sha=$SHA) to s3://$BUCKET/cloudinit/"
aws s3 sync --region "$REGION" "$CLOUDINIT/" "s3://$BUCKET/cloudinit/" --size-only

# Record what was deployed (auditable; bootstrap.sh can assert match if desired).
echo "$SHA" | aws s3 cp --region "$REGION" - "s3://$BUCKET/cloudinit/DEPLOYED_SHA"

echo "==> Done."
