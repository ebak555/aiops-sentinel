#!/usr/bin/env bash
set -euo pipefail

# Simulates CPU throttling: drops the frontend's CPU limit to 20m (from
# 200m), exercising the "CPU throttling" cause in
# frontend-latency-degradation.md.
#
# Honest caveat: this project removed Online Boutique's loadgenerator in
# Phase 2 to fit the free-tier disk quota, so there's no sustained traffic
# generating real CPU pressure -- the blackbox prober alone (one request
# per 30s) may not generate enough load to visibly throttle. This still
# exercises the real Kubernetes-level mechanism (verify with `kubectl top
# pod` / CPU throttling events) even if it doesn't always show up as a
# probe_duration_seconds spike.
#
# Usage:  ./inject-cpu-starve.sh
# Revert: ./revert-cpu-starve.sh

NAMESPACE=online-boutique
DEPLOYMENT=frontend
CONTAINER=server
STATE_FILE=/tmp/chaos-cpu-original-limit.txt

CURRENT_LIMIT=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].resources.limits.cpu}")
echo "$CURRENT_LIMIT" > "$STATE_FILE"
echo "Saved original CPU limit to $STATE_FILE: $CURRENT_LIMIT"

kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=json -p="[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"20m\"}
]"
echo "Patched $DEPLOYMENT CPU limit to 20m."
echo "Watch:  kubectl top pod -n $NAMESPACE -l app=frontend"
echo "Revert: ./revert-cpu-starve.sh"
