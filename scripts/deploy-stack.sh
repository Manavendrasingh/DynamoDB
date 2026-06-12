#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION in CircleCI project environment variables}"
: "${VPC_ID:?Set VPC_ID in CircleCI project environment variables}"
: "${PUBLIC_SUBNET_IDS:?Set PUBLIC_SUBNET_IDS as a comma-separated list in CircleCI project environment variables}"
: "${PROJECT_NAME:?Set PROJECT_NAME in CircleCI job environment variables}"
: "${ENVIRONMENT_NAME:?Set ENVIRONMENT_NAME in CircleCI job environment variables}"
: "${STACK_NAME:?Set STACK_NAME in CircleCI job environment variables}"
: "${USERS_TABLE_NAME:?Set USERS_TABLE_NAME in CircleCI job environment variables}"

IMAGE_ENV_FILE="${IMAGE_ENV_FILE:-/tmp/image/image.env}"

source "${IMAGE_ENV_FILE}"

aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file infrastructure/cloudformation.yml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    ProjectName="${PROJECT_NAME}" \
    EnvironmentName="${ENVIRONMENT_NAME}" \
    ImageUri="${IMAGE_URI}" \
    VpcId="${VPC_ID}" \
    PublicSubnetIds="${PUBLIC_SUBNET_IDS}" \
    UsersTableName="${USERS_TABLE_NAME}"

aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs" \
  --output table

