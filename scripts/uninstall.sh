#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Remove Robot Shop =="
helm uninstall robot-shop -n robot-shop || true

echo "== Remove load generator =="
kubectl delete -f robot-shop/loadgen.yaml -n robot-shop --ignore-not-found

echo "== Remove monitoring =="
helm uninstall kube-prometheus-stack -n monitoring || true

echo "== Remove Loki =="
helm uninstall loki -n monitoring || true

echo "== Remove Fluent Bit =="
helm uninstall fluent-bit -n monitoring || true

echo "== Remove Jaeger =="
helm uninstall jaeger -n tracing || true

echo "== Remove namespaces =="
kubectl delete namespace robot-shop monitoring tracing --ignore-not-found

echo "Uninstallation complete."