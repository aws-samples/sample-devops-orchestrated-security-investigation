#!/usr/bin/env bash
#
# Revert the incident: roll the service back to the healthy task definition
# (BREAK_APP=false). Mirrors the ops rollback the DevOps Agent would propose.
#
# Sandbox only.
set -euo pipefail

STACK="${STACK:-devops-security-composition}"
REGION="${REGION:-us-east-1}"

CLUSTER=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)
SERVICE=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ServiceName'].OutputValue" --output text)
TASKDEF=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='TaskDefinitionArn'].OutputValue" --output text)

echo "Rolling back to the healthy task definition (BREAK_APP=false) ..."
# Temp file + file:// (piping into --cli-input-json file:///dev/stdin is
# unreliable, notably on macOS).
TMP_DEF=$(mktemp)
trap 'rm -f "$TMP_DEF"' EXIT
aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" \
  --query 'taskDefinition' --output json \
  | python3 "$(dirname "$0")/_set_break_env.py" false > "$TMP_DEF"

NEW_ARN=$(aws ecs register-task-definition --region "$REGION" \
  --cli-input-json "file://$TMP_DEF" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$NEW_ARN" --region "$REGION" >/dev/null

echo "Service restored. The incident is cleared."
