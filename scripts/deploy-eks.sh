#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-dynamo-db-api}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CLUSTER_NAME="${CLUSTER_NAME:-dynamo-db-api-cluster}"
USERS_TABLE_NAME="${USERS_TABLE_NAME:-Users}"
NAMESPACE="${NAMESPACE:-dynamo-db-api}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-dynamo-db-api}"
IAM_POLICY_NAME="${IAM_POLICY_NAME:-dynamo-db-api-policy}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-dynamo-db-api-eks-role}"
CREATE_CLUSTER="${CREATE_CLUSTER:-false}"
NODE_TYPE="${NODE_TYPE:-t3.small}"
NODES="${NODES:-2}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-false}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command aws
require_command docker
require_command kubectl
require_command eksctl

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${IMAGE_URI:-${ECR_REGISTRY}/${ECR_REPOSITORY_NAME}:${IMAGE_TAG}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

echo "Using AWS account: ${AWS_ACCOUNT_ID}"
echo "Using EKS cluster: ${CLUSTER_NAME}"
echo "Using image: ${IMAGE_URI}"

if aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "EKS cluster found: ${CLUSTER_NAME}"
elif [[ "${CREATE_CLUSTER}" == "true" ]]; then
  eksctl create cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --nodes "${NODES}" \
    --node-type "${NODE_TYPE}" \
    --managed
else
  echo "EKS cluster not found: ${CLUSTER_NAME}" >&2
  echo "Checked AWS account ${AWS_ACCOUNT_ID} in region ${AWS_REGION}." >&2
  echo "Set CLUSTER_NAME/AWS_REGION to an existing cluster, or set CREATE_CLUSTER=true to create it." >&2
  exit 1
fi

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

if aws dynamodb describe-table --region "${AWS_REGION}" --table-name "${USERS_TABLE_NAME}" >/dev/null 2>&1; then
  echo "DynamoDB table already exists: ${USERS_TABLE_NAME}"
else
  aws dynamodb create-table \
    --region "${AWS_REGION}" \
    --table-name "${USERS_TABLE_NAME}" \
    --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH

  aws dynamodb wait table-exists --region "${AWS_REGION}" --table-name "${USERS_TABLE_NAME}"
fi

if [[ "${SKIP_IMAGE_BUILD}" == "true" ]]; then
  echo "Skipping Docker build and ECR push. Using image: ${IMAGE_URI}"
else
  aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --repository-names "${ECR_REPOSITORY_NAME}" >/dev/null 2>&1 || \
  aws ecr create-repository \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPOSITORY_NAME}" >/dev/null

  aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"

  docker build -t "${ECR_REPOSITORY_NAME}:${IMAGE_TAG}" .
  docker tag "${ECR_REPOSITORY_NAME}:${IMAGE_TAG}" "${IMAGE_URI}"
  docker push "${IMAGE_URI}"
fi

kubectl apply -f k8s/namespace.yaml

eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --approve

POLICY_DOCUMENT="$(mktemp)"
cat > "${POLICY_DOCUMENT}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:DeleteItem",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Scan",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${USERS_TABLE_NAME}"
    }
  ]
}
EOF

if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  echo "IAM policy already exists: ${POLICY_ARN}"
else
  aws iam create-policy \
    --policy-name "${IAM_POLICY_NAME}" \
    --policy-document "file://${POLICY_DOCUMENT}" >/dev/null
fi
rm -f "${POLICY_DOCUMENT}"

eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --namespace "${NAMESPACE}" \
  --name "${SERVICE_ACCOUNT_NAME}" \
  --role-name "${IAM_ROLE_NAME}" \
  --attach-policy-arn "${POLICY_ARN}" \
  --approve \
  --override-existing-serviceaccounts

RENDER_DIR="$(mktemp -d)"
cp k8s/configmap.yaml k8s/deployment.yaml k8s/service.yaml "${RENDER_DIR}/"

sed -i.bak "s|<IMAGE_URI>|${IMAGE_URI}|g" "${RENDER_DIR}/deployment.yaml"
sed -i.bak "s|us-east-1|${AWS_REGION}|g" "${RENDER_DIR}/deployment.yaml" "${RENDER_DIR}/configmap.yaml"
sed -i.bak "s|USERS_TABLE_NAME: \"Users\"|USERS_TABLE_NAME: \"${USERS_TABLE_NAME}\"|g" "${RENDER_DIR}/configmap.yaml"
rm -f "${RENDER_DIR}"/*.bak

kubectl apply -f "${RENDER_DIR}/configmap.yaml"
kubectl apply -f "${RENDER_DIR}/deployment.yaml"
kubectl apply -f "${RENDER_DIR}/service.yaml"
kubectl rollout status deployment/dynamo-db-api -n "${NAMESPACE}"

echo
echo "Deployment complete."
echo "Service:"
kubectl get svc dynamo-db-api -n "${NAMESPACE}"
echo
echo "When EXTERNAL-IP has a hostname, test with:"
echo "API_URL=http://\$(kubectl get svc dynamo-db-api -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "curl \"\$API_URL/\""
