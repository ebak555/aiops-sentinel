#!/usr/bin/env bash
set -euo pipefail

# Simulates a full outage: scales the frontend to 0 replicas, which
# should cause probe_success==0 within one probe interval (30s) and fire
# the "frontend probe failing" alert -- exercises frontend-unavailable.md.
#
# Usage:  ./inject-scale-to-zero.sh
# Revert: ./revert-scale-to-zero.sh

NAMESPACE=online-boutique
DEPLOYMENT=frontend
STATE_FILE=/tmp/chaos-scale-original-replicas.txt

CURRENT_REPLICAS=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
echo "$CURRENT_REPLICAS" > "$STATE_FILE"
echo "Saved original replica count to $STATE_FILE: $CURRENT_REPLICAS"

kubectl scale "deployment/$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
echo "Scaled $DEPLOYMENT to 0 replicas."
echo "Watch:  kubectl get pods -n $NAMESPACE -w"
echo "Revert: ./revert-scale-to-zero.sh"
