# Deploy to Amazon EKS

This app is a NestJS API that runs on port `3000` and uses DynamoDB. The EKS deployment uses:

- ECR for the Docker image
- EKS for Kubernetes
- IRSA for DynamoDB permissions
- A Kubernetes `LoadBalancer` service for public access

## Quick deploy

You can deploy with one script instead of running every command manually.

Prerequisites:

- AWS CLI logged in
- Docker running
- `kubectl` installed
- `eksctl` installed
- An existing EKS cluster, unless you set `CREATE_CLUSTER=true`

Deploy to an existing EKS cluster:

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=dynamo-db-api-cluster
./scripts/deploy-eks.sh
```

Create the EKS cluster too, then deploy:

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=dynamo-db-api-cluster
export CREATE_CLUSTER=true
./scripts/deploy-eks.sh
```

Optional values:

```bash
export ECR_REPOSITORY_NAME=dynamo-db-api
export IMAGE_TAG=latest
export USERS_TABLE_NAME=Users
export NODE_TYPE=t3.small
export NODES=2
```

After the script finishes, wait for the LoadBalancer hostname:

```bash
kubectl get svc dynamo-db-api -n dynamo-db-api
```

Then test:

```bash
export API_URL=http://$(kubectl get svc dynamo-db-api -n dynamo-db-api \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl "$API_URL/"
curl "$API_URL/users"
```

The sections below show the manual commands if you want to run or debug each step yourself.

## CircleCI deploy

CircleCI is useful when you want the app to deploy automatically after code is pushed to `main`.

This repo includes [.circleci/config.yml](/Users/apple/Documents/GitHub/DynamoDB/.circleci/config.yml). The workflow now:

- installs dependencies
- runs lint
- runs tests
- builds the NestJS app
- builds and pushes the Docker image to ECR
- deploys that ECR image to EKS with `scripts/deploy-eks.sh`

Add these variables in CircleCI project settings:

```bash
AWS_ACCESS_KEY_ID=<your-access-key>
AWS_SECRET_ACCESS_KEY=<your-secret-key>
AWS_REGION=us-east-1
CLUSTER_NAME=dynamo-db-api-cluster
```

Optional variables:

```bash
ECR_REPOSITORY_NAME=dynamo-db-api
USERS_TABLE_NAME=Users
CREATE_CLUSTER=false
```

For normal CI/CD, keep `CREATE_CLUSTER=false` and create the EKS cluster one time outside the pipeline. A CI pipeline should usually deploy the app, not create and destroy the cluster on every run.

## 1. Set variables

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REPOSITORY_NAME=dynamo-db-api
export IMAGE_TAG=latest
export CLUSTER_NAME=dynamo-db-api-cluster
export USERS_TABLE_NAME=Users
```

## 2. Create the DynamoDB table

Skip this if the table already exists.

```bash
aws dynamodb create-table \
  --region "$AWS_REGION" \
  --table-name "$USERS_TABLE_NAME" \
  --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH
```

## 3. Build and push the Docker image

```bash
aws ecr describe-repositories \
  --region "$AWS_REGION" \
  --repository-names "$ECR_REPOSITORY_NAME" >/dev/null 2>&1 || \
aws ecr create-repository \
  --region "$AWS_REGION" \
  --repository-name "$ECR_REPOSITORY_NAME"

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker build -t "$ECR_REPOSITORY_NAME:$IMAGE_TAG" .
docker tag "$ECR_REPOSITORY_NAME:$IMAGE_TAG" \
  "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY_NAME:$IMAGE_TAG"
docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY_NAME:$IMAGE_TAG"
```

## 4. Create or connect to an EKS cluster

If you already have a cluster, configure `kubectl`:

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
```

If you need to create a simple cluster with `eksctl`:

```bash
eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --nodes 2 \
  --node-type t3.small \
  --managed

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
```

## 5. Create an IAM role for the pod

Create the Kubernetes namespace first:

```bash
kubectl apply -f k8s/namespace.yaml
```

Enable IAM OIDC for the cluster:

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve
```

Create a policy for this API's DynamoDB table:

```bash
cat > /tmp/dynamo-db-api-policy.json <<EOF
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
      "Resource": "arn:aws:dynamodb:$AWS_REGION:$AWS_ACCOUNT_ID:table/$USERS_TABLE_NAME"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name dynamo-db-api-policy \
  --policy-document file:///tmp/dynamo-db-api-policy.json
```

Create the Kubernetes service account and IAM role:

```bash
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace dynamo-db-api \
  --name dynamo-db-api \
  --role-name dynamo-db-api-eks-role \
  --attach-policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/dynamo-db-api-policy" \
  --approve \
  --override-existing-serviceaccounts
```

## 6. Update the manifests

Replace placeholders in the Kubernetes files:

```bash
export IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY_NAME:$IMAGE_TAG"

sed -i.bak "s|<IMAGE_URI>|$IMAGE_URI|g" k8s/deployment.yaml
sed -i.bak "s|<AWS_ACCOUNT_ID>|$AWS_ACCOUNT_ID|g" k8s/serviceaccount.yaml
sed -i.bak "s|us-east-1|$AWS_REGION|g" k8s/deployment.yaml k8s/configmap.yaml
rm k8s/*.bak
```

If you use a different table name, edit `USERS_TABLE_NAME` in `k8s/configmap.yaml`.

## 7. Deploy

`eksctl create iamserviceaccount` creates the service account, so apply the other manifests separately:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

If you did not use `eksctl create iamserviceaccount`, also apply:

```bash
kubectl apply -f k8s/serviceaccount.yaml
```

## 8. Check the deployment

```bash
kubectl get pods -n dynamo-db-api
kubectl get svc -n dynamo-db-api
kubectl logs -n dynamo-db-api deployment/dynamo-db-api
```

Wait until the service gets an external address:

```bash
kubectl get svc dynamo-db-api -n dynamo-db-api \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo
```

Test the API:

```bash
export API_URL=http://$(kubectl get svc dynamo-db-api -n dynamo-db-api \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl "$API_URL/"
curl -X POST "$API_URL/users" \
  -H "Content-Type: application/json" \
  -d '{"name":"Jane Doe","email":"jane@example.com","phone":"1234567890","address":"New York"}'
curl "$API_URL/users"
```

## Updating the app

Build and push a new tag, update `image` in `k8s/deployment.yaml`, then run:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment/dynamo-db-api -n dynamo-db-api
```
