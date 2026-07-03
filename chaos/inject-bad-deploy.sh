#!/usr/bin/env bash
set -euo pipefail

# Simulates a bad deployment: patches the frontend's image to a
# nonexistent tag, causing ImagePullBackOff -- exercises the
# bad-deployment-rollback.md and pod-crashloop.md runbooks, and should
# eventually surface as a probe_success==0 / non-200 alert.
#
# Usage:  ./inject-bad-deploy.sh
# Revert: ./revert-bad-deploy.sh

NAMESPACE=online-boutique
DEPLOYMENT=frontend
CONTAINER=server
STATE_FILE=/tmp/chaos-bad-deploy-original-image.txt

CURRENT_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}")
echo "$CURRENT_IMAGE" > "$STATE_FILE"
echo "Saved original image to $STATE_FILE: $CURRENT_IMAGE"

kubectl set image "deployment/$DEPLOYMENT" "$CONTAINER=${CURRENT_IMAGE%:*}:this-tag-does-not-exist" -n "$NAMESPACE"
echo "Patched $DEPLOYMENT to a nonexistent image tag."
echo "Watch:  kubectl get pods -n $NAMESPACE -w"
echo "Revert: ./revert-bad-deploy.sh"
