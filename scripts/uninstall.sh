#!/usr/bin/env bash
# Removes the workloads in the safe order BEFORE the cluster is destroyed.
# Load balancers and EBS volumes are created by Kubernetes, so Terraform does not know about them.
set -euo pipefail
cd "$(dirname "$0")/.."

trap 'echo "ERROR: uninstall.sh failed near line $LINENO" >&2' ERR

CLUSTER="${CLUSTER_NAME:-robot-shop}"
REGION="${AWS_REGION:-us-east-1}"

for tool in aws kubectl helm; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done

echo "== Cluster access =="
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
echo "Cluster: $(kubectl config current-context)"
kubectl get nodes

# Volumes must be deleted together with their claims, otherwise they are left behind and keep billing
RECLAIM="$(kubectl get storageclass gp3 -o jsonpath='{.reclaimPolicy}' 2>/dev/null || true)"
if [[ -n "$RECLAIM" && "$RECLAIM" != "Delete" ]]; then
  echo "StorageClass gp3 has reclaimPolicy '$RECLAIM'. Volumes would be left behind. Aborting."
  exit 1
fi

managed_albs() {
  aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
}

uninstall_release() {  # usage: uninstall_release <release> <namespace>
  if helm status "$1" -n "$2" >/dev/null 2>&1; then
    helm uninstall "$1" -n "$2" --wait --timeout 5m
  else
    echo "$1 is not installed in $2, skipping."
  fi
}

echo "== Remove Ingress and ALB =="
# The controller removes the ALB before it releases the Ingress, so a successful delete means the ALB is going away.
kubectl delete -f robot-shop/ingress.yaml --ignore-not-found --timeout=300s

echo "Confirming the AWS load balancers are gone..."
for i in {1..40}; do
  if OUT="$(managed_albs 2>/dev/null)"; then
    if [[ -z "$OUT" || "$OUT" == "None" ]]; then
      echo "No load balancers remain for cluster $CLUSTER."
      break
    fi
    echo "Still present: $OUT"
  else
    echo "AWS query failed, retrying..."
  fi
  if [[ "$i" -eq 40 ]]; then
    echo "Load balancers still present or unverifiable after about 7 minutes. Aborting."
    exit 1
  fi
  sleep 10
done

echo "== Remove load generator =="
kubectl delete -f robot-shop/loadgen.yaml -n robot-shop --ignore-not-found

echo "== Remove Helm releases =="
uninstall_release robot-shop robot-shop
uninstall_release blackbox-exporter monitoring
uninstall_release fluent-bit monitoring
uninstall_release loki monitoring
uninstall_release jaeger tracing
uninstall_release opentelemetry-operator opentelemetry-operator-system
uninstall_release kube-prometheus-stack monitoring

echo "== Remaining volume claims =="
kubectl get pvc -A || true

echo
read -r -p "Type 'cleanup' to delete the robot-shop, monitoring, tracing and opentelemetry-operator-system namespaces: " answer

if [[ "$answer" != "cleanup" ]]; then
  echo "Namespace cleanup skipped. Do not destroy the cluster until the volumes are gone."
  exit 0
fi

kubectl delete namespace robot-shop monitoring tracing opentelemetry-operator-system \
  --ignore-not-found --wait=true --timeout=5m

echo "== Waiting for Kubernetes-created EBS volumes to be deleted =="
for i in {1..30}; do
  if VOLS="$(aws ec2 describe-volumes --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null)"; then
    if [[ -z "$VOLS" || "$VOLS" == "None" ]]; then
      echo "No Kubernetes-created volumes remain."
      break
    fi
    echo "Still present: $VOLS"
  else
    echo "AWS query failed, retrying..."
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "Volumes still present or unverifiable. Do not destroy the cluster yet."
    exit 1
  fi
  sleep 10
done

echo
echo "Uninstall complete. Next: run ./scripts/destroy.sh in the Terraform repo, then verify with:"
echo "  CLUSTER_NAME=$CLUSTER ./scripts/verify-destroyed.sh"
