#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER_NAME:-robot-shop}"
REGION="${AWS_REGION:-us-east-1}"
BLACKBOX_VERSION="11.20.2"   # helm search repo prometheus-community/prometheus-blackbox-exporter

[[ "$BLACKBOX_VERSION" != "FILL_IN" ]] || { echo "Set BLACKBOX_VERSION at the top of install.sh"; exit 1; }

echo "== Cluster access =="
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl get nodes

echo "== Storage class =="
kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=300s
kubectl apply -f platform/storageclass-gp3.yaml
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  kubectl patch storageclass gp2 \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

echo "== Add Helm repositories =="
helm repo add eks https://aws.github.io/eks-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update

echo "== AWS Load Balancer Controller =="
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query cluster.resourcesVpcConfig.vpcId --output text)"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version 3.6.2 \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait --timeout 5m

echo "== Prometheus and Grafana =="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  kubectl -n monitoring create secret generic slack-webhook \
    --from-literal=slack-webhook-url="$SLACK_WEBHOOK_URL" --dry-run=client -o yaml | kubectl apply -f -
elif [[ -f slo/slack-secret.yaml ]]; then
  kubectl apply -f slo/slack-secret.yaml
else
  echo "WARNING: no Slack webhook given, alerts will not be delivered."
  kubectl -n monitoring create secret generic slack-webhook \
    --from-literal=slack-webhook-url="https://example.invalid/placeholder" --dry-run=client -o yaml | kubectl apply -f -
fi
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 92.16.1 \
  -f monitoring/kube-prometheus-stack-values.yaml \
  -f slo/alertmanager-values.yaml \
  --wait --timeout 10m

echo "== Loki =="
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --version 7.5.0 \
  -f logging/loki-values.yaml \
  --wait --timeout 10m

echo "== Fluent Bit =="
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace monitoring \
  --version 0.58.3 \
  -f logging/fluent-bit/values.yaml \
  --wait --timeout 10m

echo "== Jaeger =="
helm upgrade --install jaeger jaegertracing/jaeger \
  --namespace tracing --create-namespace \
  --version 4.16.1 \
  -f tracing/jaeger-values.yaml \
  --wait --timeout 10m

echo "== Robot Shop =="
helm upgrade --install robot-shop robot-shop/chart \
  --namespace robot-shop --create-namespace \
  -f robot-shop/values-eks.yaml \
  --wait --timeout 10m

echo "== Load generator =="
kubectl apply -n robot-shop -f robot-shop/loadgen.yaml

echo "== Public entrance (ALB) =="
for i in 1 2 3 4 5; do
  kubectl apply -f robot-shop/ingress.yaml && break
  [ "$i" -eq 5 ] && { echo "Could not create the Ingress"; exit 1; }
  echo "Load balancer controller not ready yet, retrying in 15s..."
  sleep 15
done

echo "== Availability probes and cart/payment metrics =="
helm upgrade --install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring \
  --version "$BLACKBOX_VERSION" \
  -f monitoring/blackbox-values.yaml \
  --wait --timeout 5m
kubectl apply -f monitoring/robot-shop-podmonitor.yaml

echo
echo "Installation complete."
echo "Shop address (appears in 2 to 3 minutes):  kubectl get ingress -n robot-shop"
echo "Grafana:  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"