#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit

REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER_NAME:-robot-shop}"
PROJECT="robot-shop-observability"
leftovers=0

fail() {
  printf 'FOUND  %s: %s\n' "$1" "$2"
  leftovers=1
}

pass() {
  printf 'OK     %s\n' "$1"
}

echo "== Terraform state =="
if state_out="$(cd infra/eks && terraform state list 2>&1)"; then
  if [[ -z "$state_out" ]]; then
    pass "Terraform state is empty"
  else
    fail "Terraform state entries" "$state_out"
  fi
else
  fail "Could not read Terraform state" "$state_out"
fi

echo
echo "== EKS cluster =="
if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  fail "EKS cluster" "$CLUSTER still exists"
else
  pass "EKS cluster is absent"
fi

echo
echo "== Project-tagged resources =="

resources="$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=$PROJECT" \
  --region "$REGION" \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output text 2>&1)" || {
    fail "Could not list project resources" "$resources"
    resources=""
  }

for arn in $resources; do
  case "$arn" in
    arn:aws:kms:*:key/*)
      key_id="${arn##*/}"
      key_state="$(aws kms describe-key --key-id "$key_id" \
        --region "$REGION" \
        --query 'KeyMetadata.KeyState' --output text 2>&1)" || {
          fail "KMS key lookup failed" "$key_id: $key_state"
          continue
        }

      if [[ "$key_state" == "PendingDeletion" ]]; then
        pass "KMS key $key_id is pending deletion"
      else
        fail "KMS key $key_id" "state=$key_state"
      fi
      ;;

    arn:aws:eks:*:podidentityassociation/*)
      cluster_from_arn="$(printf '%s' "$arn" | cut -d/ -f2)"
      if aws eks describe-cluster --name "$cluster_from_arn" \
        --region "$REGION" >/dev/null 2>&1; then
        fail "Pod Identity association" "$arn"
      else
        pass "Pod Identity association belongs to deleted cluster $cluster_from_arn"
      fi
      ;;

    *)
      fail "Unclassified project resource" "$arn"
      ;;
  esac
done

echo
if [[ "$leftovers" -eq 0 ]]; then
  echo "All clear: no active project resources remain."
else
  echo "Verification failed: active or unclassified project resources remain."
fi

exit "$leftovers"
