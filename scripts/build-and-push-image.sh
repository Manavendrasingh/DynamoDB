#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION in CircleCI project environment variables}"
: "${ECR_REPOSITORY_NAME:?Set ECR_REPOSITORY_NAME in CircleCI job environment variables}"
: "${CIRCLE_SHA1:?CIRCLE_SHA1 is required}"

IMAGE_ENV_FILE="${IMAGE_ENV_FILE:-/tmp/image/image.env}"

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG="${CIRCLE_SHA1}"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPOSITORY_NAME}:${IMAGE_TAG}"

aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_NAME}" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "${ECR_REPOSITORY_NAME}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker build -t "${IMAGE_URI}" .
docker push "${IMAGE_URI}"

mkdir -p "$(dirname "${IMAGE_ENV_FILE}")"
echo "export IMAGE_URI=${IMAGE_URI}" > "${IMAGE_ENV_FILE}"

