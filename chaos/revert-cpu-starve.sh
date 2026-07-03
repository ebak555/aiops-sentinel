#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=online-boutique
DEPLOYMENT=frontend
STATE_FILE=/tmp/chaos-cpu-original-limit.txt

if [ ! -f "$STATE_FILE" ]; then
  echo "No saved state at $STATE_FILE -- defaulting to 200m." >&2
  ORIGINAL_LIMIT=200m
else
  ORIGINAL_LIMIT=$(cat "$STATE_FILE")
  rm -f "$STATE_FILE"
fi

kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=json -p="[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$ORIGINAL_LIMIT\"}
]"
echo "Reverted $DEPLOYMENT CPU limit to $ORIGINAL_LIMIT"
