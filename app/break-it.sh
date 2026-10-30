#!/usr/bin/env bash
#
# Trip the incident with one command.
#
#   1. Deploys the bad task-definition revision (BREAK_APP=true) -- the
#      operational fault the DevOps Agent diffs. It is paired with the
#      dropped-auth diff in app/changes/dropped-auth.patch (the security
#      regression the Security Agent reviews). One bad deploy, two symptoms.
#   2. Waits for the bad revision to finish rolling out.
#   3. Generates the 5xx traffic that trips the alarm, which starts the DevOps
#      Agent investigation through the SNS -> forwarder -> webhook path.
#   4. If this machine cannot reach the ALB (VPN / egress blocks), starts the
#      investigation directly with `aws devops-agent create-backlog-task`
#      instead -- set AGENT_SPACE_ID (your DevOps Agent space id) for that.
#
# Options (environment variables):
#   AGENT_SPACE_ID   DevOps Agent space id, used for the direct-start fallback
#   INVESTIGATE      auto (default)  start directly only if the ALB is unreachable
#                    always          always start directly (in addition to the alarm)
#                    never           never start directly
#
# Sandbox only. Reverted by fix-it.sh and removed by teardown.sh.
set -euo pipefail

STACK="${STACK:-devops-security-composition}"
REGION="${REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-nimbus}"
INVESTIGATE="${INVESTIGATE:-auto}"
AGENT_SPACE_ID="${AGENT_SPACE_ID:-}"
REQUESTS="${REQUESTS:-30}"

stack_output() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

CLUSTER=$(stack_output ClusterName)
SERVICE=$(stack_output ServiceName)
TASKDEF=$(stack_output TaskDefinitionArn)
APP_URL=$(stack_output AppUrl)
ALARM=$(stack_output AlarmName)

start_investigation() {
  if [[ -z "$AGENT_SPACE_ID" ]]; then
    cat <<EOF

To start the investigation directly, set your DevOps Agent space id and re-run:
  AGENT_SPACE_ID=<devops-agent-space-id> INVESTIGATE=always ./app/break-it.sh
EOF
    return 0
  fi
  echo "Starting the DevOps Agent investigation directly (create-backlog-task) ..."
  aws devops-agent create-backlog-task --region "$REGION" \
    --agent-space-id "$AGENT_SPACE_ID" \
    --task-type INVESTIGATION --priority HIGH \
    --title "5xx spike on ${NAME_PREFIX}-notes after a deploy" \
    --description "Investigate the 5xx regression on the ${NAME_PREFIX}-notes ECS service. Diff recent task-definition revisions to find what changed. If the root cause is a code or configuration change, delegate a security review to the ${NAME_PREFIX}-security-review-agent remote agent and fold its findings in." \
    >/dev/null
  echo "Investigation started. Open the DevOps Agent operator app to watch it."
}

# --- 1. Deploy the bad revision ------------------------------------------------
echo "Registering a bad task-definition revision (BREAK_APP=true) ..."
# Write to a temp file and pass it with file://; piping into
# --cli-input-json file:///dev/stdin is unreliable (notably on macOS).
TMP_DEF=$(mktemp)
trap 'rm -f "$TMP_DEF"' EXIT
aws ecs describe-task-definition --task-definition "$TASKDEF" --region "$REGION" \
  --query 'taskDefinition' --output json \
  | python3 "$(dirname "$0")/_set_break_env.py" true > "$TMP_DEF"

NEW_ARN=$(aws ecs register-task-definition --region "$REGION" \
  --cli-input-json "file://$TMP_DEF" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

echo "Updating service to the bad revision: $NEW_ARN"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$NEW_ARN" --region "$REGION" >/dev/null

# --- 2. Wait for the rollout ---------------------------------------------------
# Until the old tasks drain, requests can still reach healthy tasks and the
# alarm may not trip.
echo "Waiting for the bad revision to roll out (usually 3-6 minutes) ..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"
echo "Bad revision is live."

# --- 3. Generate 5xx traffic (or fall back) -----------------------------------
if ! curl -s -m 5 -o /dev/null "$APP_URL/health"; then
  echo
  echo "This machine cannot reach the App URL ($APP_URL) -- usually a VPN or"
  echo "egress block. The alarm cannot fire without traffic."
  if [[ "$INVESTIGATE" != never ]]; then start_investigation; fi
  exit 0
fi

echo "Sending $REQUESTS requests to $APP_URL/notes ..."
fives=0
for _ in $(seq 1 "$REQUESTS"); do
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$APP_URL/notes" || true)
  if [[ "$code" == 5* ]]; then fives=$((fives + 1)); fi
done
echo "Got $fives x 5xx out of $REQUESTS requests."

if [[ "$INVESTIGATE" == always ]]; then
  start_investigation
  exit 0
fi

# --- 4. Confirm the alarm fires -----------------------------------------------
echo "Waiting for alarm $ALARM (up to ~4 minutes) ..."
state=OK
for _ in $(seq 1 16); do
  state=$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --region "$REGION" \
    --query 'MetricAlarms[0].StateValue' --output text)
  [[ "$state" == ALARM ]] && break
  sleep 15
done

if [[ "$state" == ALARM ]]; then
  echo "Alarm is in ALARM. The forwarder posts the incident to the DevOps Agent"
  echo "webhook, and an investigation appears in the operator app within ~1 minute."
else
  echo "Alarm did not reach ALARM (state: $state)."
  if [[ "$INVESTIGATE" != never ]]; then start_investigation; fi
fi
