#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Remove Ingress and ALB =="
kubectl delete -f robot-shop/ingress.yaml \
  --ignore-not-found

echo "Waiting for ALB cleanup..."
for i in {1..30}; do
  if ! kubectl get ingress -n robot-shop 2>/dev/null | grep -q robot-shop; then
    break
  fi
  sleep 10
done

echo "== Remove load generator =="
kubectl delete -f robot-shop/loadgen.yaml \
  -n robot-shop --ignore-not-found

echo "== Remove Robot Shop =="
helm uninstall robot-shop -n robot-shop || true

echo "== Remove Fluent Bit =="
helm uninstall fluent-bit -n monitoring || true

echo "== Remove Loki =="
helm uninstall loki -n monitoring || true

echo "== Remove Jaeger =="
helm uninstall jaeger -n tracing || true

echo "== Remove Prometheus and Grafana =="
helm uninstall kube-prometheus-stack -n monitoring || true

echo "== Check remaining PVCs =="
kubectl get pvc -A || true

echo
echo "Review remaining PVCs before deleting namespaces."
read -r -p "Type 'cleanup' to delete robot-shop, monitoring and tracing namespaces: " answer

if [[ "$answer" == "cleanup" ]]; then
  kubectl delete namespace robot-shop monitoring tracing \
    --wait=true --timeout=5m || true
else
  echo "Namespace cleanup skipped."
fi

echo
echo "Uninstallation steps completed."
