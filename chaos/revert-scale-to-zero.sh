#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=online-boutique
DEPLOYMENT=frontend
STATE_FILE=/tmp/chaos-scale-original-replicas.txt

if [ ! -f "$STATE_FILE" ]; then
  echo "No saved state at $STATE_FILE -- defaulting to 1 replica." >&2
  ORIGINAL_REPLICAS=1
else
  ORIGINAL_REPLICAS=$(cat "$STATE_FILE")
  rm -f "$STATE_FILE"
fi

kubectl scale "deployment/$DEPLOYMENT" -n "$NAMESPACE" --replicas="$ORIGINAL_REPLICAS"
echo "Reverted $DEPLOYMENT to $ORIGINAL_REPLICAS replica(s)"
