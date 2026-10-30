#!/usr/bin/env bash
# Read-only check that nothing from the project is left in AWS.
set -uo pipefail
cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER_NAME:-robot-shop}"
leftovers=0

check() {  # check "<label>" "<command output>"
  if [[ -z "$2" || "$2" == "None" ]]; then
    printf 'OK     %s\n' "$1"
  else
    printf 'FOUND  %s: %s\n' "$1" "$2"
    leftovers=1
  fi
}

if state_out="$(cd infra/eks && terraform state list 2>&1)"; then
  check "Terraform state entries" "$state_out"
else
  printf 'ERROR  could not read Terraform state: %s\n' "$state_out"
  leftovers=1
fi
check "EKS clusters" "$(aws eks list-clusters --region "$REGION" --query 'clusters' --output text)"
check "EC2 instances" "$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
check "Load balancers (v2)" "$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
check "Load balancers (classic)" "$(aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null)"
check "EKS network interfaces" "$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=description,Values=Amazon EKS $CLUSTER*" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
check "Security groups" "$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=*$CLUSTER*" \
  --query 'SecurityGroups[].GroupId' --output text)"
check "IAM roles" "$(aws iam list-roles \
  --query "Roles[?(contains(RoleName, '$CLUSTER') && !starts_with(RoleName, 'gha-')) || contains(RoleName, 'eks-node-group')].RoleName" --output text)"
check "IAM OIDC providers" "$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'oidc.eks')].Arn" --output text)"
check "CloudWatch log groups" "$(aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/aws/eks/$CLUSTER" --query 'logGroups[].logGroupName' --output text)"
check "KMS aliases" "$(aws kms list-aliases --region "$REGION" \
  --query "Aliases[?contains(AliasName, '$CLUSTER')].AliasName" --output text)"
check "EBS volumes created by Kubernetes" "$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
  --query 'Volumes[].VolumeId' --output text)"

echo
if [[ $leftovers -eq 0 ]]; then
  echo "All clear: nothing from the project remains."
else
  echo "Some resources remain. Wait a few minutes and rerun; if they persist, tell me what is listed."
fi
exit $leftovers