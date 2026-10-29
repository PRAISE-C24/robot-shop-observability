#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../infra/eks"

PROJECT="${PROJECT:-robot-shop-observability}"

for tool in terraform aws kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
[[ -f backend.hcl ]] || { echo "Missing backend.hcl."; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
IDENTITY="$(aws sts get-caller-identity --query Arn --output text)"

terraform init -input=false -backend-config=backend.hcl >/dev/null
CLUSTER="$(terraform output -raw cluster_name 2>/dev/null || true)"
REGION="$(terraform output -raw region 2>/dev/null || echo us-east-1)"

cat <<EOF

=====================  DESTROY  =====================
  AWS account : ${ACCOUNT}
  Identity    : ${IDENTITY}
  Region      : ${REGION}
  Cluster     : ${CLUSTER:-<none found in state>}

  This permanently deletes the EKS cluster, its worker
  nodes and everything Terraform created for them.
  The Terraform state bucket is NOT touched.
=====================================================

EOF

# Load balancers created by Kubernetes are invisible to Terraform and block cleanup
if [[ -n "${CLUSTER}" ]]; then
  TMPKUBE="$(mktemp)"
  trap 'rm -f "${TMPKUBE}"' EXIT
  if aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" \
       --kubeconfig "${TMPKUBE}" >/dev/null 2>&1; then
    LB_SVCS="$(KUBECONFIG="${TMPKUBE}" kubectl get svc -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
      2>/dev/null || true)"
    INGRESSES="$(KUBECONFIG="${TMPKUBE}" kubectl get ingress -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
      2>/dev/null || true)"
    if [[ -n "${LB_SVCS}${INGRESSES}" ]]; then
      echo "Kubernetes still has load balancer Services or Ingresses:"
      echo "${LB_SVCS}${INGRESSES}"
      echo
      echo "Remove them first (for example: helm uninstall <release>) and wait for"
      echo "the AWS load balancers to disappear. Aborting."
      exit 1
    fi
  else
    echo "WARNING: could not reach the cluster to check for load balancers."
    if [[ "${CI:-}" == "true" ]]; then
      echo "Running in CI: not continuing without that check. Aborting."
      exit 1
    fi
    read -r -p "Continue anyway? [y/N] " cont
    [[ "${cont}" == "y" ]] || { echo "Aborted."; exit 1; }
  fi
fi

echo "== Destroy plan =="
set +e
terraform plan -destroy -input=false -detailed-exitcode -out=destroy.tfplan
rc=$?
set -e
if [[ ${rc} -eq 0 ]]; then
  echo "Nothing to destroy."
  rm -f destroy.tfplan
  exit 0
elif [[ ${rc} -ne 2 ]]; then
  echo "Plan failed. Nothing was destroyed."
  exit 1
fi

CONFIRM_WORD="${CLUSTER:-destroy}"
echo
if [[ "${CI:-}" == "true" ]]; then
  echo "Running in CI: confirmation was typed in the workflow and approved at the production gate."
else
  read -r -p "Type '${CONFIRM_WORD}' to confirm destruction: " answer
  [[ "${answer}" == "${CONFIRM_WORD}" ]] || { echo "Aborted."; rm -f destroy.tfplan; exit 1; }
fi

terraform apply -input=false destroy.tfplan
rm -f destroy.tfplan

echo
echo "== Resources still tagged Project=${PROJECT} (should be empty) =="
aws resourcegroupstaggingapi get-resources --region "${REGION}" \
  --tag-filters "Key=Project,Values=${PROJECT}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text