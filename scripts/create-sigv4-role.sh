#!/usr/bin/env bash
#
# Create (or update) the IAM role the AWS DevOps Agent assumes to call the A2A
# bridge on AgentCore Runtime with SigV4.
#
#   Role name : ${NAME_PREFIX}-devops-to-bridge   (the name teardown removes)
#   Trust     : aidevops.amazonaws.com, confined with aws:SourceAccount and
#               aws:SourceArn (arn:aws:aidevops:<region>:<account>:service/*)
#   Allows    : bedrock-agentcore:GetAgentCard (registration validates the
#               agent card) + bedrock-agentcore:InvokeAgentRuntime (delegation),
#               on the bridge runtime ARN and "<arn>/*" only
#
# Safe to re-run: an existing role gets its trust and permission policies
# updated in place.
#
# Usage (from the root of this repo):
#   export AGENT_RUNTIME_ARN=...   # README step e.4
#   ./scripts/create-sigv4-role.sh
#
# Sandbox only.
set -euo pipefail

REGION="${REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-nimbus}"
AGENT_RUNTIME_ARN="${AGENT_RUNTIME_ARN:?export AGENT_RUNTIME_ARN first (README step e.4)}"
ROLE_NAME="${NAME_PREFIX}-devops-to-bridge"

case "$AGENT_RUNTIME_ARN" in
  arn:aws:bedrock-agentcore:*:runtime/*) ;;
  *) echo "Error: AGENT_RUNTIME_ARN does not look like a runtime ARN: $AGENT_RUNTIME_ARN" >&2
     echo "Re-run the lookup in README step e.4 (it must not print None)." >&2
     exit 1 ;;
esac

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

TRUST=$(mktemp)
PERMS=$(mktemp)
trap 'rm -f "$TRUST" "$PERMS"' EXIT

cat > "$TRUST" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "aidevops.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
      "ArnLike": { "aws:SourceArn": "arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:service/*" }
    }
  }]
}
EOF

cat > "$PERMS" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["bedrock-agentcore:GetAgentCard", "bedrock-agentcore:InvokeAgentRuntime"],
    "Resource": ["${AGENT_RUNTIME_ARN}", "${AGENT_RUNTIME_ARN}/*"]
  }]
}
EOF

python3 -m json.tool "$TRUST" >/dev/null
python3 -m json.tool "$PERMS" >/dev/null

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role $ROLE_NAME exists; updating its trust policy ..."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST"
else
  echo "Creating role $ROLE_NAME ..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "AWS DevOps Agent -> A2A bridge (SigV4). Sample; sandbox only." \
    --assume-role-policy-document "file://$TRUST" >/dev/null
fi

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name invoke-bridge \
  --policy-document "file://$PERMS"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
cat <<EOF

SigV4 role ready: $ROLE_ARN

Next (README step f):
  export SIGV4_ROLE_ARN=$ROLE_ARN
  ./scripts/register-remote-agent.sh
EOF
