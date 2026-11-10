#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

trap 'echo "ERROR: install.sh failed near line $LINENO" >&2' ERR

CLUSTER="${CLUSTER_NAME:-robot-shop}"
REGION="${AWS_REGION:-us-east-1}"
BLACKBOX_VERSION="11.20.2"            # helm search repo prometheus-community/prometheus-blackbox-exporter
OTEL_OPERATOR_CHART_VERSION="0.129.0" # helm repo update && helm search repo open-telemetry/opentelemetry-operator --versions | head -5

for tool in aws kubectl helm; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
[[ "$BLACKBOX_VERSION" != "FILL_IN" ]] || { echo "Set BLACKBOX_VERSION at the top of install.sh"; exit 1; }
[[ "$OTEL_OPERATOR_CHART_VERSION" != "FILL_IN" ]] || { echo "Set OTEL_OPERATOR_CHART_VERSION at the top of install.sh"; exit 1; }

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
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Fail early if the pinned operator chart version does not exist in the repository index
OTEL_FOUND="$(helm search repo open-telemetry/opentelemetry-operator --version "$OTEL_OPERATOR_CHART_VERSION" 2>/dev/null || true)"
[[ "$OTEL_FOUND" == *opentelemetry-operator* ]] || {
  echo "opentelemetry-operator chart version $OTEL_OPERATOR_CHART_VERSION not found."
  echo "List available versions with: helm search repo open-telemetry/opentelemetry-operator --versions | head -5"
  exit 1
}

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
  echo "NOTE: Slack is not configured (documented deviation). Alerts stay in Alertmanager."
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

echo "== Dashboard and SLO rules =="
kubectl -n monitoring create configmap robot-shop-golden-signals \
  --from-file=robot-shop-golden-signals.json=monitoring/dashboards/robot-shop-golden-signals.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -
kubectl apply -f slo/robot-shop-slo-rules.yaml

# Tracing comes last: it needs the robot-shop namespace and the shipping Deployment,
# and a tracing problem must not stop the shop, probes or dashboard from being installed.
echo "== Tracing (OpenTelemetry auto-instrumentation) =="
JAEGER_PORTS="$(kubectl -n tracing get svc jaeger -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || true)"
[[ " $JAEGER_PORTS " == *" 4318 "* ]] || {
  echo "Service 'jaeger' with port 4318 not found in namespace 'tracing' (ports found: ${JAEGER_PORTS:-none})."
  echo "Check 'kubectl -n tracing get svc' and update the endpoint in tracing/instrumentation.yaml."
  exit 1
}

helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace opentelemetry-operator-system --create-namespace \
  --version "$OTEL_OPERATOR_CHART_VERSION" \
  -f tracing/otel-operator-values.yaml \
  --wait --timeout 5m

# The operator's webhook can take a few seconds to accept requests
applied=false
for i in $(seq 1 20); do
  if kubectl apply -f tracing/instrumentation.yaml; then applied=true; break; fi
  echo "waiting for the operator webhook ($i/20)..."; sleep 6
done
[[ "$applied" == true ]] || { echo "Could not create the Instrumentation resource"; exit 1; }

# Instrument one service. The Instrumentation resource must exist before the pod restarts.
kubectl -n robot-shop patch deploy shipping --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"true"}}}}}'
kubectl -n robot-shop rollout status deploy/shipping --timeout=300s

echo
echo "Installation complete."
echo "Shop address (appears in 2 to 3 minutes):  kubectl get ingress -n robot-shop"
echo "Grafana:  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "Jaeger:   kubectl -n tracing port-forward svc/jaeger 16686:16686   (look for the 'shipping' service)"
