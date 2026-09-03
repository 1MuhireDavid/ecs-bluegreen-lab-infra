#!/usr/bin/env bash
# OPTIONAL CLI ALTERNATIVE. The recommended path for this lab is the
# AWS Console walkthrough in ../README.md ("One-time bootstrap"), which
# deploys this exact same template with no CLI required. Use this script
# only if you'd rather script it -- it creates identical resources.
#
# Usage:
#   ./bootstrap.sh <github-org> [aws-region]
#
# Example:
#   ./bootstrap.sh 1MuhireDavid us-east-1

set -euo pipefail

GITHUB_ORG="${1:?Usage: bootstrap.sh <github-org> [aws-region]}"
AWS_REGION="${2:-us-east-1}"
STACK_NAME="ecs-bluegreen-lab-bootstrap"
INFRA_REPO="ecs-bluegreen-lab-infra"
APP_REPO="ecs-bluegreen-lab-app"

echo "Deploying bootstrap stack '${STACK_NAME}' in ${AWS_REGION}..."

aws cloudformation deploy \
  --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file "$(dirname "$0")/../cfn/bootstrap/00-bootstrap.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOrg="${GITHUB_ORG}" \
      InfraRepoName="${INFRA_REPO}" \
      AppRepoName="${APP_REPO}" \
      CreateOidcProvider=false

echo
echo "Bootstrap complete. Values to configure next:"
echo "----------------------------------------------------------------"

TEMPLATES_BUCKET=$(aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='TemplatesBucketName'].OutputValue" --output text)

INFRA_ROLE_ARN=$(aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='InfraPackagingRoleArn'].OutputValue" --output text)

APP_ROLE_ARN=$(aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='AppEcrPushRoleArn'].OutputValue" --output text)

DEPLOY_ROLE_ARN=$(aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='InfraDeployRoleArn'].OutputValue" --output text)

cat <<EOF

Each repo gets its own secrets -- the two roles stay isolated from each
other both by living in different repos AND via GitHub's job_workflow_ref
OIDC claim (see 00-bootstrap.yaml).

1) Add these secrets to ${GITHUB_ORG}/${INFRA_REPO}:
     AWS_INFRA_PACKAGING_ROLE_ARN = ${INFRA_ROLE_ARN}
     AWS_TEMPLATES_BUCKET         = ${TEMPLATES_BUCKET}
     AWS_INFRA_DEPLOY_ROLE_ARN    = ${DEPLOY_ROLE_ARN}
   And this variable:
     AWS_REGION                   = ${AWS_REGION}

   AWS_INFRA_DEPLOY_ROLE_ARN is only needed if you run the manual
   ".github/workflows/infra-deploy.yml" fallback (bypasses CloudFormation
   Git sync, deploys via the CLI instead).

2) Add these secrets to ${GITHUB_ORG}/${APP_REPO}:
     AWS_ECR_PUSH_ROLE_ARN        = ${APP_ROLE_ARN}
     ECR_REPOSITORY               = ecs-bluegreen-lab-app
   And this variable:
     AWS_REGION                   = ${AWS_REGION}

3) In ${INFRA_REPO}/cfn/deployment-file.yaml, set:
     TemplatesBucketName: ${TEMPLATES_BUCKET}
     AppOwnerName: "<your full name>"
     GitHubOrg: "${GITHUB_ORG}"

4) Push ${INFRA_REPO} (main branch) so
   .github/workflows/package-templates.yml runs once and uploads
   cfn/modules/*.yaml to S3.

5) In the CloudFormation console, create a new stack -> "Sync from Git" ->
   point it at ${GITHUB_ORG}/${INFRA_REPO}, branch main, deployment file
   cfn/deployment-file.yaml. Merge the pull request Git sync opens.
----------------------------------------------------------------
EOF
