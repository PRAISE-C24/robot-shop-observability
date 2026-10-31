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

check() {  # check "<label>" "<command output>"
  if [[ -z "$2" || "$2" == "None" ]]; then pass "$1"; else fail "$1" "$2"; fi
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
cluster_out="$(aws eks describe-cluster \
  --name "$CLUSTER" --region "$REGION" 2>&1)"
cluster_rc=$?

if [[ "$cluster_rc" -eq 0 ]]; then
  fail "EKS cluster" "$CLUSTER still exists"
elif grep -q "ResourceNotFoundException" <<< "$cluster_out"; then
  pass "EKS cluster is absent"
else
  fail "Could not verify EKS cluster" "$cluster_out"
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
echo "== Resources Kubernetes created (not covered by the Project tag) =="
check "EC2 instances" "$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
check "Load balancers (v2)" "$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
check "Load balancers (classic)" "$(aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null)"
check "EBS volumes created by Kubernetes" "$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
  --query 'Volumes[].VolumeId' --output text)"
check "EKS network interfaces" "$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=description,Values=Amazon EKS $CLUSTER*" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"

echo
if [[ "$leftovers" -eq 0 ]]; then
  echo "All clear: no active project resources remain."
else
  echo "Verification failed: active or unclassified project resources remain."
fi

exit "$leftovers"
