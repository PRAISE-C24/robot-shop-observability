#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../infra/eks"

for tool in terraform aws; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
[[ -f backend.hcl ]] || { echo "Missing backend.hcl. Run scripts/bootstrap-state.sh first."; exit 1; }

echo "== Identity =="
aws sts get-caller-identity --query '[Account,Arn]' --output text

echo "== Format =="
terraform fmt -recursive

echo "== Init =="
terraform init -input=false -backend-config=backend.hcl

echo "== Validate =="
terraform validate

echo "== Plan =="
terraform plan -input=false -out=tfplan

echo
echo "Review the plan above. An EKS cluster costs about 0.10 USD/hour for the"
echo "control plane plus the worker nodes, until you destroy it."
if [[ "${CI:-}" == "true" ]]; then
  echo "Running in CI: approval was given at the production environment gate."
else
  read -r -p "Type 'apply' to continue: " answer
  [[ "${answer}" == "apply" ]] || { echo "Aborted."; rm -f tfplan; exit 1; }
fi

terraform apply -input=false tfplan
rm -f tfplan

echo
echo "Next: $(terraform output -raw kubeconfig_command)"