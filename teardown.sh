#!/usr/bin/env bash
#
# Scripted teardown: deletes the CloudFormation stack and the app ECR repository
# (owned by deploy.sh, not the stack). If you export BRIDGE_RUNTIME_ID and
# BRIDGE_STACK, it also removes the A2A bridge runtime and the AgentCore CLI's
# CloudFormation stack.
#
# This does NOT remove everything. The webhook secret, the SigV4 IAM role,
# objects/buckets in S3, the remote-agent registration, and the two managed
# Agent Spaces must be removed manually. See the full "Tear down" checklist in
# docs/TEARDOWN.md (Steps 2-4) so nothing is left running.
set -euo pipefail

REGION="${REGION:-us-east-1}"
STACK="${STACK:-devops-security-composition}"
NAME_PREFIX="${NAME_PREFIX:-nimbus}"

echo "Deleting stack $STACK ..."
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" || true

# break-it.sh / fix-it.sh register task-definition revisions outside the stack.
# Deregister any that are still active, then delete them (best effort).
echo "Removing ${NAME_PREFIX}-notes task-definition revisions ..."
for td in $(aws ecs list-task-definitions --family-prefix "${NAME_PREFIX}-notes" --region "$REGION" \
              --query 'taskDefinitionArns' --output text 2>/dev/null); do
  aws ecs deregister-task-definition --task-definition "$td" --region "$REGION" >/dev/null 2>&1 || true
done
for td in $(aws ecs list-task-definitions --family-prefix "${NAME_PREFIX}-notes" --status INACTIVE \
              --region "$REGION" --query 'taskDefinitionArns' --output text 2>/dev/null); do
  aws ecs delete-task-definitions --task-definitions "$td" --region "$REGION" >/dev/null 2>&1 || true
done

# The forwarder's log group is created by Lambda on first invocation, so it is
# not part of the stack.
aws logs delete-log-group --log-group-name "/aws/lambda/${NAME_PREFIX}-forwarder" \
  --region "$REGION" >/dev/null 2>&1 || true

# The app ECR repo is owned by deploy.sh (not the stack), so remove it here.
echo "Deleting the app ECR repository ..."
aws ecr delete-repository --repository-name "${NAME_PREFIX}-app" --force --region "$REGION" >/dev/null 2>&1 \
  && echo "  deleted ${NAME_PREFIX}-app" \
  || echo "  (ECR repo ${NAME_PREFIX}-app already gone)"

# The A2A bridge runtime is a Bedrock AgentCore runtime created by the AgentCore
# CLI (which provisions it through a CloudFormation stack named
# AgentCore-<project>-default). The CLI has no 'destroy' command, so remove the
# runtime via the control-plane API and then delete the CLI's CFN stack. Set
# BRIDGE_RUNTIME_ID and BRIDGE_STACK to your values (printed by 'agentcore
# status' / visible in the CloudFormation console) to let this script remove
# them; otherwise follow the manual steps the checklist below prints.
if [[ -n "${BRIDGE_RUNTIME_ID:-}" ]]; then
  echo "Deleting the A2A bridge runtime $BRIDGE_RUNTIME_ID ..."
  aws bedrock-agentcore-control delete-agent-runtime \
    --agent-runtime-id "$BRIDGE_RUNTIME_ID" --region "$REGION" >/dev/null 2>&1 \
    && echo "  bridge runtime deleted" \
    || echo "  (bridge runtime $BRIDGE_RUNTIME_ID already gone)"
  # The runtime's log group outlives the runtime.
  aws logs delete-log-group \
    --log-group-name "/aws/bedrock-agentcore/runtimes/${BRIDGE_RUNTIME_ID}-DEFAULT" \
    --region "$REGION" >/dev/null 2>&1 && echo "  bridge log group deleted" || true
fi
if [[ -n "${BRIDGE_STACK:-}" ]]; then
  echo "Deleting the AgentCore CLI stack $BRIDGE_STACK ..."
  aws cloudformation delete-stack --stack-name "$BRIDGE_STACK" --region "$REGION" \
    && aws cloudformation wait stack-delete-complete --stack-name "$BRIDGE_STACK" --region "$REGION" 2>/dev/null \
    && echo "  $BRIDGE_STACK deleted" \
    || echo "  (delete $BRIDGE_STACK manually if it remains)"
fi

cat <<EOF

Stack, app ECR repo, task-definition revisions and forwarder log group removed.

STILL TO REMOVE MANUALLY (see docs/TEARDOWN.md Steps 2-4 for commands):
  * A2A bridge runtime + its AgentCore CFN stack + its log group, unless you set
    BRIDGE_RUNTIME_ID / BRIDGE_STACK above (the AgentCore CLI has no 'destroy';
    use 'aws bedrock-agentcore-control delete-agent-runtime' then delete the
    AgentCore-<project>-default stack)
  * Webhook secret:         ${NAME_PREFIX}-devops-webhook (Secrets Manager)
  * SigV4 role + policy:     ${NAME_PREFIX}-devops-to-bridge (IAM)
  * S3 objects + bucket:     diffs/ and source/ in \$DIFF_BUCKET (and the bucket
                             itself, if you created it for this sample)
  * Remote-agent registration in the DevOps Agent console (deregister)
  * The DevOps Agent and Security Agent Agent Spaces, if created only for this
    lab, plus the DevOpsAgentRole-* IAM roles the Agent Space wizard created
  * CDK bootstrap (CDKToolkit stack + its assets bucket/ECR repo), only if the
    bridge deploy created it and nothing else in the account uses CDK
EOF
