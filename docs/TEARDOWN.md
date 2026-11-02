# Tear down

Step letters such as "step f" or "step (e)" refer to the
[walkthrough](WALKTHROUGH.md).


This sample creates resources across CloudFormation, ECR, AgentCore, IAM,
Secrets Manager, S3, and the two managed Agent Spaces. Removing everything is a
mix of scripted and manual steps — **work through the full checklist below** so
nothing is left running (and billing) in your account.

## Step 1 — Scripted removal

First, in the DevOps Agent console, remove `<nameprefix>-security-review-agent`
from your Agent Space (**Capabilities → Remote Agents → Remove**) and deregister
it (**Capability Providers → select it → Actions → Deregister**), so nothing
tries to call the bridge while it is being deleted.

```bash
# Look up the bridge runtime id (the part of the ARN after "runtime/").
export BRIDGE_RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --output text --query "agentRuntimes[?contains(agentRuntimeName, 'nimbus_security_review_agent')].agentRuntimeId | [0]")
echo "$BRIDGE_RUNTIME_ID"

# Deletes: the app CloudFormation stack (VPC, subnets, ALB, ECS Fargate service +
# cluster, DynamoDB table, 4 VPC endpoints, SNS topic + its KMS key, Lambda
# forwarder, CloudWatch alarm + log group, 3 stack IAM roles), the app ECR
# repository, every task-definition revision (including the one break-it.sh
# registered), the forwarder log group, the bridge runtime + its log group, and
# the AgentCore CLI's stack. The KMS key enters a 7-day pending-deletion window.
BRIDGE_STACK=AgentCore-NimbusSecBridge-default ./teardown.sh
```

The AgentCore CLI has no `destroy` command, which is why `teardown.sh` deletes
the runtime through the control-plane API and then deletes the CLI's
`AgentCore-<project>-default` stack. If you used a different `--project-name`,
change `BRIDGE_STACK` to match.

## Step 2 — Manual removal (what the scripts do NOT delete)

These are created outside the stack (by you, by `deploy.sh`, by the AgentCore
CLI, or in a console) and must be removed by hand. Use your own names/region.

```bash
# a. The DevOps Agent webhook secret (Secrets Manager).
aws secretsmanager delete-secret \
  --secret-id "${NAME_PREFIX}-devops-webhook" \
  --force-delete-without-recovery --region "$REGION"

# b. The SigV4 role + inline policy created for remote-agent registration (step f).
aws iam delete-role-policy \
  --role-name "${NAME_PREFIX}-devops-to-bridge" --policy-name invoke-bridge
aws iam delete-role --role-name "${NAME_PREFIX}-devops-to-bridge"

# c. The objects you uploaded to the Security Agent S3 bucket (diffs + source).
aws s3 rm s3://<diff-bucket>/diffs/  --recursive --region "$REGION"
aws s3 rm s3://<diff-bucket>/source/ --recursive --region "$REGION"

# d. The DIFF_BUCKET itself — ONLY if you created it for this sample.
#    (Disconnect it from the Security Agent Agent Space in the console first.)
aws s3 rb s3://<diff-bucket> --force --region "$REGION"

# e. The CDK bootstrap — ONLY if `agentcore deploy` bootstrapped this account
#    (step e.4) and nothing else here uses CDK. Its assets bucket is versioned
#    and retained, so empty and remove it after deleting the stack.
CDK_BUCKET=cdk-hnb659fds-assets-$(aws sts get-caller-identity --query Account --output text)-$REGION
aws cloudformation delete-stack --stack-name CDKToolkit --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name CDKToolkit --region "$REGION"
aws ecr delete-repository --force --region "$REGION" \
  --repository-name "${CDK_BUCKET/assets/container-assets}" >/dev/null 2>&1 || true
for kind in Versions DeleteMarkers; do
  aws s3api delete-objects --bucket "$CDK_BUCKET" --region "$REGION" --delete "$(aws s3api \
    list-object-versions --bucket "$CDK_BUCKET" --region "$REGION" --output json \
    --query "{Objects: $kind[].{Key:Key,VersionId:VersionId}}")" >/dev/null 2>&1 || true
done
aws s3 rb "s3://$CDK_BUCKET" --region "$REGION" \
  || echo "(if this fails, empty $CDK_BUCKET in the S3 console, then delete it)"
```

## Step 3 — Console removals (no CLI)

- **Deregister the remote agent** in the DevOps Agent console: Capability
  Providers → select `${NAME_PREFIX}-security-review-agent` → **Deregister**
  (detach it from the Agent Space first if prompted).
- **Delete the DevOps Agent Agent Space** — if you created it only for this
  sample. The wizard also created two IAM roles per space
  (`DevOpsAgentRole-AgentSpace-*` and `DevOpsAgentRole-WebappAdmin-*`); delete
  them in the IAM console after the space is gone.
- **Delete the Security Agent Agent Space** (including the code review resource)
  — if you created it only for this sample.
- Check the **other regions** in both consoles for any Agent Space you created
  by accident while the console was pointed elsewhere.

## Step 4 — Local cleanup (no cost, just tidy)

- Delete the AgentCore bridge project folder you scaffolded in step (e)
  (e.g. `~/Downloads/NimbusSecBridge`) — only after the bridge runtime and its
  `AgentCore-<project>-default` stack are deleted (Step 1), since you read the
  runtime id and stack name from `agentcore status` in that project.
- Delete the local `app-source.zip` if you created one.

> **Verify nothing is left billing.** After the above, confirm the stack is gone
> (`aws cloudformation describe-stacks --stack-name devops-security-composition
> --region "$REGION"` should return "does not exist"), and check the ECS, ALB,
> and AgentCore consoles show no running resources from this sample.
