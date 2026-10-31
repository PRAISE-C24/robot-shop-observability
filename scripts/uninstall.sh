#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Remove Ingress and ALB =="

ALB_HOST="$(kubectl get ingress web \
  -n robot-shop \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
  2>/dev/null || true)"

kubectl delete -f robot-shop/ingress.yaml --ignore-not-found

echo "Waiting for Ingress deletion..."
for i in {1..30}; do
  if ! kubectl get ingress web -n robot-shop >/dev/null 2>&1; then
    echo "Ingress deletion confirmed."
    break
  fi

  if [[ "$i" -eq 30 ]]; then
    echo "Ingress still exists after 5 minutes. Aborting cleanup."
    exit 1
  fi

  sleep 10
done

if [[ -n "$ALB_HOST" ]]; then
  echo "Waiting for AWS ALB deletion..."

  for i in {1..30}; do
    ALB_ARN="$(aws elbv2 describe-load-balancers \
      --region "${AWS_REGION:-us-east-1}" \
      --query "LoadBalancers[?DNSName=='${ALB_HOST}'].LoadBalancerArn | [0]" \
      --output text 2>/dev/null || true)"

    if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
      echo "ALB deletion confirmed."
      break
    fi

    if [[ "$i" -eq 30 ]]; then
      echo "ALB still exists after 5 minutes. Aborting cleanup."
      exit 1
    fi

    sleep 10
  done
fi

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
