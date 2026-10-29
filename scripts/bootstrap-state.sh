#!/usr/bin/env bash
# One-time bootstrap: creates the S3 bucket that stores Terraform state.
# Run from the repo root. Safe to re-run.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-robot-shop-observability}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${STATE_BUCKET:-tfstate-${ACCOUNT_ID}-${REGION}}"

echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"
echo "Bucket:  ${BUCKET}"
read -r -p "Create/verify this state bucket? [y/N] " answer
[[ "${answer}" == "y" ]] || { echo "Aborted."; exit 1; }

if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "Bucket already exists; re-applying settings."
elif [[ "${REGION}" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --create-bucket-configuration "LocationConstraint=${REGION}"
fi

aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}}
  }]
}
EOF
)
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy "${POLICY}"

# Local backend config (git-ignored; each person gets their own)
mkdir -p infra/eks
cat > infra/eks/backend.hcl <<EOF
bucket       = "${BUCKET}"
key          = "${PROJECT}/eks/terraform.tfstate"
region       = "${REGION}"
encrypt      = true
use_lockfile = true
EOF

echo "Done. Wrote infra/eks/backend.hcl"