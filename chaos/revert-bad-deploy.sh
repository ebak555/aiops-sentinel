#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=online-boutique
DEPLOYMENT=frontend
CONTAINER=server
STATE_FILE=/tmp/chaos-bad-deploy-original-image.txt

if [ ! -f "$STATE_FILE" ]; then
  echo "No saved state at $STATE_FILE -- nothing to revert (or already reverted)." >&2
  exit 1
fi

ORIGINAL_IMAGE=$(cat "$STATE_FILE")
kubectl set image "deployment/$DEPLOYMENT" "$CONTAINER=$ORIGINAL_IMAGE" -n "$NAMESPACE"
rm -f "$STATE_FILE"
echo "Reverted $DEPLOYMENT to $ORIGINAL_IMAGE"
