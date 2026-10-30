#!/usr/bin/env bash
#
# One-command deploy for the composed DevOps + Security agent sample.
# SANDBOX ACCOUNT ONLY. Refuses to run without --sandbox-confirmed.
#
# Steps:
#   1. Guard: require explicit sandbox acknowledgment.
#   2. Build and push the synthetic app image to ECR.
#   3. Package the forwarder and deploy the CloudFormation stack.
#   4. Build and deploy the A2A bridge to AgentCore Runtime.
#   5. Print next steps (register the bridge as a DevOps Agent remote agent).
set -euo pipefail

REGION="${REGION:-us-east-1}"
STACK="${STACK:-devops-security-composition}"
NAME_PREFIX="${NAME_PREFIX:-nimbus}"
CONTAINER_CLI="${CONTAINER_CLI:-finch}"   # finch by default; set to docker if preferred

# --- Step 1: sandbox guard ---------------------------------------------------
if [[ "${1:-}" != "--sandbox-confirmed" ]]; then
  cat >&2 <<EOF
Refusing to deploy.

This sample is intentionally flawed and must run in a DISPOSABLE SANDBOX account
only, in a single region ($REGION). It deploys a public ALB, a running service,
and plants a security regression.

Re-run with the acknowledgment flag once you have confirmed this is a sandbox:

    ./deploy.sh --sandbox-confirmed

See THREAT-MODEL.md and SECURITY.md.
EOF
  exit 1
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Deploying into account $ACCOUNT, region $REGION (sandbox confirmed)."

# --- Step 2: build + push the app image LOCALLY -----------------------------
# Built locally on purpose (not in-stack). The DevOps Agent security
# requirements forbid customer-controlled compute (CodeBuild/CloudShell/
# SageMaker) in a monitored account, so this sample does not run CodeBuild in
# the account the DevOps Agent monitors. Requires finch or Docker locally.
if ! command -v "$CONTAINER_CLI" >/dev/null 2>&1; then
  echo "Container runtime '$CONTAINER_CLI' not found. Install finch or Docker, " >&2
  echo "or set CONTAINER_CLI=docker. (Image must be built locally; see README.)" >&2
  exit 1
fi

REPO="${NAME_PREFIX}-app"
# deploy.sh owns the ECR repo (the stack does not declare it, to avoid a
# create collision). Create it with KMS encryption + scan-on-push so it meets
# the same hardening bar as the rest of the stack. Reuse it if it already
# exists (e.g. re-running the sample).
if ! aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$REPO" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=KMS >/dev/null
fi
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REPO}:latest"

echo "Building and pushing the app image locally with $CONTAINER_CLI ..."
aws ecr get-login-password --region "$REGION" \
  | "$CONTAINER_CLI" login --username AWS --password-stdin "$REGISTRY"
# Build for linux/amd64 explicitly: the Fargate task runs on x86_64, so an
# arm64 image built on an Apple-Silicon Mac would exit immediately (exit 255).
# The task definition pins RuntimePlatform to X86_64 to match.
"$CONTAINER_CLI" build --platform linux/amd64 -t "$IMAGE_URI" app/
"$CONTAINER_CLI" push "$IMAGE_URI"

# --- Step 3: webhook secret + stack -----------------------------------------
# The DevOps Agent webhook URL + signing secret must exist in Secrets Manager
# before deploy. This is created out of band (after you configure the webhook in
# the DevOps Agent console) so no secret ever lands in a stack output.
WEBHOOK_SECRET_ID="${WEBHOOK_SECRET_ID:-${NAME_PREFIX}-devops-webhook}"
if ! aws secretsmanager describe-secret --secret-id "$WEBHOOK_SECRET_ID" --region "$REGION" >/dev/null 2>&1; then
  cat >&2 <<EOF
Missing webhook secret "$WEBHOOK_SECRET_ID".

Configure a generic webhook in your DevOps Agent Agent Space (HMAC, in
region $REGION), then store the URL and signing secret as shown in README
step b (the secret is read from a prompt so it stays out of shell history).

Then re-run deploy.
EOF
  exit 1
fi

echo "Packaging forwarder and deploying stack $STACK ..."
TMP=$(mktemp -d)
cp forwarder/forwarder.py "$TMP/forwarder.py"
( cd "$TMP" && zip -q forwarder.zip forwarder.py )

aws cloudformation deploy \
  --template-file infra/template.yaml \
  --stack-name "$STACK" \
  --region "$REGION" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      NamePrefix="$NAME_PREFIX" \
      ImageUri="$IMAGE_URI" \
      WebhookSecretId="$WEBHOOK_SECRET_ID" \
      AllowedRegion="$REGION"

# Update the forwarder code (deployed with a placeholder in the template).
aws lambda update-function-code \
  --function-name "${NAME_PREFIX}-forwarder" \
  --zip-file "fileb://$TMP/forwarder.zip" \
  --region "$REGION" >/dev/null
rm -rf "$TMP"

APP_URL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='AppUrl'].OutputValue" --output text)

# --- Step 4: A2A bridge (AgentCore Runtime, A2A protocol) --------------------
# The bridge is a Strands agent served with serve_a2a() on port 9000. It is
# deployed with the AgentCore CLI, which packages the code, builds an ARM64
# image, and creates the runtime. We only deploy it if the AgentCore CLI is
# present and the Security Agent prerequisites are configured; otherwise we
# print the manual steps so deploy still succeeds for the app half.
# The A2A bridge is NOT deployed here. It is a Strands agent hosted on AgentCore
# Runtime, deployed with the interactive AgentCore CLI (`agentcore create`
# scaffolds the project, then `agentcore deploy`). That flow cannot be reduced
# to a single non-interactive line, so it is a documented separate step. See
# a2a-bridge/DEPLOY.md for the exact commands (including the Security Agent env
# vars and the CDK context wiring).

# --- Step 5: next steps ------------------------------------------------------
cat <<EOF

================================================================================
App deploy complete.

  App URL:        $APP_URL
  Alarm:          ${NAME_PREFIX}-target-5xx
  Region:         $REGION

The APP half is up. Now wire the agents and run the demo:

  1. Deploy the A2A bridge (README step e): agentcore create, then
        ./a2a-bridge/configure-bridge.sh ../NimbusSecBridge
     then agentcore deploy --yes, and capture AGENT_RUNTIME_ARN.

  2. Create the SigV4 role and register the bridge (README step f):
        ./scripts/create-sigv4-role.sh
        ./scripts/register-remote-agent.sh

  3. Trip the incident with one command (README step h):
        AGENT_SPACE_ID=<devops-agent-space-id> ./app/break-it.sh
     It deploys the bad revision, generates the 5xx traffic, and -- if this
     machine cannot reach the ALB -- starts the investigation directly.

  4. Watch the DevOps Agent investigate, delegate to the bridge over A2A, and
     fold the Security Agent findings into one investigation. Revert with
     ./app/fix-it.sh.

Tear down when done:  ./teardown.sh   (and see README "Tear down" for the rest)
================================================================================
EOF
