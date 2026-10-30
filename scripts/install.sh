#!/usr/bin/env bash

set -uo pipefail

echo "== Storage class =="
kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=300s
kubectl apply -f platform/storageclass-gp3.yaml
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi