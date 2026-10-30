#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER_NAME:-robot-shop}"
REGION="${AWS_REGION:-us-east-1}"

echo "== Cluster access =="
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl get nodes

echo "== Storage class =="
kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=300s
kubectl apply -f platform/storageclass-gp3.yaml
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

echo "== AWS Load Balancer Controller =="
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
            --query cluster.resourcesVpcConfig.vpcId --output text)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --version 3.6.1 \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait --timeout 5m

echo "== Robot Shop =="
helm upgrade --install robot-shop robot-shop/chart \
  --namespace robot-shop --create-namespace \
  -f robot-shop/values-eks.yaml \
  --wait --timeout 10m

echo "== Public entrance (ALB) =="
for i in 1 2 3 4 5; do
  kubectl apply -f robot-shop/ingress.yaml && break
  [ "$i" -eq 5 ] && { echo "Could not create the Ingress"; exit 1; }
  echo "Load balancer controller not ready yet, retrying in 15s..."; sleep 15
done

echo
echo "Done. The load balancer address appears in 2 to 3 minutes:"
echo "  kubectl get ingress -n robot-shop"