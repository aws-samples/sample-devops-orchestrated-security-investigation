#!/usr/bin/env bash
#
# Register the A2A bridge as a remote agent with the AWS DevOps Agent, so the
# DevOps Agent can delegate security-review subtasks to it mid-investigation and
# fold the findings into its investigation (per "Connecting Remote A2A Agents").
#
# The bridge is deployed to AgentCore Runtime (A2A protocol). Its agent card is
# served at:
#   https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<url-encoded-arn>/invocations/.well-known/agent-card.json
# and it authenticates with SigV4 (service name: bedrock-agentcore).
#
# This script computes the card URL from the runtime ARN and prints the exact
# console steps and the equivalent (dry-run) CLI call. Registration is an
# account-level, one-time action; re-run only if the ARN or auth changes.
#
# The SigV4 role (SIGV4_ROLE_ARN) must be trusted by the DevOps Agent service
# principal "aidevops.amazonaws.com" (NOT bedrock-agentcore), confined with
# SourceAccount + SourceArn conditions, and allowed GetAgentCard +
# InvokeAgentRuntime on the bridge runtime. Create it with
# scripts/create-sigv4-role.sh (role name: ${NAME_PREFIX}-devops-to-bridge).
set -euo pipefail

REGION="${REGION:-us-east-1}"
AGENT_RUNTIME_ARN="${AGENT_RUNTIME_ARN:?set AGENT_RUNTIME_ARN to the deployed A2A bridge runtime ARN (from 'agentcore deploy')}"
AGENT_SPACE_ID="${AGENT_SPACE_ID:?set AGENT_SPACE_ID to your DevOps Agent Agent Space id}"
SIGV4_ROLE_ARN="${SIGV4_ROLE_ARN:?set SIGV4_ROLE_ARN to a role whose trust policy allows the DevOps Agent service principal to assume it}"
REMOTE_AGENT_NAME="${REMOTE_AGENT_NAME:-nimbus-security-review-agent}"

# URL-encode the ARN for the invocations path.
ENCODED_ARN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$AGENT_RUNTIME_ARN")
CARD_URL="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/${ENCODED_ARN}/invocations/.well-known/agent-card.json"

cat <<EOF
Remote agent registration inputs
---------------------------------
  Name          : $REMOTE_AGENT_NAME
  Agent Space   : $AGENT_SPACE_ID
  Runtime ARN   : $AGENT_RUNTIME_ARN
  Agent card URL: $CARD_URL
  Auth          : SigV4  (region $REGION, service bedrock-agentcore)
  SigV4 role    : $SIGV4_ROLE_ARN

Console steps (authoritative today)
-----------------------------------
  1. DevOps Agent console -> Capability Providers -> Remote Agent -> Register.
  2. Name            = $REMOTE_AGENT_NAME
     Agent card URL  = (paste the Agent card URL above)
     Auth method     = AWS SigV4
       - IAM role      = $SIGV4_ROLE_ARN
       - Region        = $REGION
       - Service name  = bedrock-agentcore
  3. Register, then: your Agent Space -> Capabilities -> Remote Agents -> Add ->
     select "$REMOTE_AGENT_NAME".

Validate the card is reachable (SigV4-signed GET)
-------------------------------------------------
  awscurl --service bedrock-agentcore --region $REGION "\\
    ${CARD_URL%/.well-known/agent-card.json}/.well-known/agent-card.json"

Equivalent CLI (DRY RUN — confirm the verb/params against the devops-agent CLI
in your region before enabling; the console flow above is authoritative today)
EOF

# printf (not a heredoc) so the trailing backslashes print literally instead of
# being treated as line continuations.
printf '%s\n' \
  "# aws devops-agent register-capability-provider \\" \
  "#   --provider-type REMOTE_AGENT \\" \
  "#   --name \"$REMOTE_AGENT_NAME\" \\" \
  "#   --agent-card-endpoint \"$CARD_URL\" \\" \
  "#   --auth-config '{\"sigV4\":{\"roleArn\":\"$SIGV4_ROLE_ARN\",\"region\":\"$REGION\",\"serviceName\":\"bedrock-agentcore\"}}' \\" \
  "#   --region \"$REGION\"" \
  "#" \
  "# aws devops-agent associate-remote-agent \\" \
  "#   --agent-space-id \"$AGENT_SPACE_ID\" \\" \
  "#   --name \"$REMOTE_AGENT_NAME\" \\" \
  "#   --region \"$REGION\""
echo
echo "(Dry run: this script does not call the API. Use the console steps above, "
echo " or uncomment the CLI once the devops-agent remote-agent verbs are confirmed.)"
