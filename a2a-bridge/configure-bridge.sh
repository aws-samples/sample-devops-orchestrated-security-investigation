#!/usr/bin/env bash
#
# Configure an AgentCore CLI project (scaffolded with `agentcore create ...
# --framework Strands --protocol A2A`) to run the A2A bridge.
#
# Makes the three edits described in a2a-bridge/DEPLOY.md steps 2-3, so they
# cannot be missed or pasted in the wrong place:
#   1. replaces the scaffold's entrypoint (app/<agent>/main.py) with bridge.py
#   2. adds boto3 to the agent's pyproject.toml dependencies
#   3. wires SECURITY_AGENT_SPACE_ID / CODE_REVIEW_ID / DIFF_BUCKET and the
#      bridge's IAM permissions into the generated CDK stack + cdk.json context
#
# Safe to re-run: every edit is skipped if it is already present, and the
# cdk.json values are overwritten with the current ones.
#
# Usage (from the root of this repo, in the same shell where you exported the
# three values in README step c):
#   ./a2a-bridge/configure-bridge.sh ../NimbusSecBridge
#
# Sandbox only.
set -euo pipefail

PROJECT="${1:?usage: $0 <path-to-agentcore-project>   (e.g. ../NimbusSecBridge)}"
AGENT_NAME="${AGENT_NAME:-nimbus_security_review_agent}"

: "${SECURITY_AGENT_SPACE_ID:?export SECURITY_AGENT_SPACE_ID (as-...) first; see README step c}"
: "${CODE_REVIEW_ID:?export CODE_REVIEW_ID (cr-...) first; see README step c}"
: "${DIFF_BUCKET:?export DIFF_BUCKET (your Security Agent S3 bucket) first; see README step c}"

# Catch the most common mistake: a placeholder pasted instead of a real value.
for pair in "SECURITY_AGENT_SPACE_ID=$SECURITY_AGENT_SPACE_ID" \
            "CODE_REVIEW_ID=$CODE_REVIEW_ID" "DIFF_BUCKET=$DIFF_BUCKET"; do
  case "$pair" in
    *"<"*|*">"*|*"..."*)
      echo "Error: ${pair%%=*} still looks like a placeholder (${pair#*=})." >&2
      echo "Export the real value (no angle brackets) and re-run." >&2
      exit 1 ;;
  esac
done
[[ "$SECURITY_AGENT_SPACE_ID" == as-* ]] || { echo "Error: SECURITY_AGENT_SPACE_ID should start with 'as-'." >&2; exit 1; }
[[ "$CODE_REVIEW_ID" == cr-* ]] || { echo "Error: CODE_REVIEW_ID should start with 'cr-'." >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$PROJECT" && pwd)"
AGENT_DIR="$PROJECT/app/$AGENT_NAME"
PYPROJECT="$AGENT_DIR/pyproject.toml"
CDK_STACK="$PROJECT/agentcore/cdk/lib/cdk-stack.ts"
CDK_JSON="$PROJECT/agentcore/cdk/cdk.json"

for f in "$PYPROJECT" "$CDK_STACK" "$CDK_JSON"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: expected $f" >&2
    echo "Is '$PROJECT' an AgentCore CLI project created with --name $AGENT_NAME?" >&2
    echo "(Set AGENT_NAME=<your agent name> if you used a different --name.)" >&2
    exit 1
  fi
done

# --- 1. Entrypoint -----------------------------------------------------------
cp "$HERE/bridge.py" "$AGENT_DIR/main.py"
echo "1/3 entrypoint: copied bridge.py -> app/$AGENT_NAME/main.py"

# --- 2 + 3. pyproject, CDK stack, cdk.json -----------------------------------
PYPROJECT="$PYPROJECT" CDK_STACK="$CDK_STACK" CDK_JSON="$CDK_JSON" python3 - <<'PY'
import json
import os
import re
import sys

pyproject = os.environ["PYPROJECT"]
cdk_stack = os.environ["CDK_STACK"]
cdk_json = os.environ["CDK_JSON"]

# --- 2. boto3 dependency ---
text = open(pyproject).read()
if re.search(r'^\s*"boto3\b', text, re.M):
    print("2/3 pyproject: boto3 already listed")
else:
    new, n = re.subn(r'^(\s*dependencies\s*=\s*\[\s*\n)', r'\1    "boto3 >= 1.35.0",\n', text, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"Error: could not find 'dependencies = [' in {pyproject}; add \"boto3 >= 1.35.0\" by hand.")
    open(pyproject, "w").write(new)
    print("2/3 pyproject: added boto3 >= 1.35.0")

# --- 3a. CDK stack: env vars + IAM for the bridge runtime ---
MARKER = "// nimbus-security-bridge: Security Agent config + IAM"
BLOCK = f"""
    {MARKER} (added by a2a-bridge/configure-bridge.sh)
    const secSpaceId = this.node.tryGetContext('securityAgentSpaceId');
    const secCodeReviewId = this.node.tryGetContext('codeReviewId');
    const secDiffBucket = this.node.tryGetContext('diffBucket');
    if (secSpaceId && secCodeReviewId && secDiffBucket) {{
      for (const env of this.application.environments.values()) {{
        env.runtime.addEnvironmentVariable('SECURITY_AGENT_SPACE_ID', String(secSpaceId));
        env.runtime.addEnvironmentVariable('CODE_REVIEW_ID', String(secCodeReviewId));
        env.runtime.addEnvironmentVariable('DIFF_BUCKET', String(secDiffBucket));
        env.runtime.role.addToPrincipalPolicy(new iam.PolicyStatement({{
          actions: [
            'securityagent:StartCodeReviewJob',
            'securityagent:BatchGetCodeReviewJobs',
            'securityagent:ListFindings',
          ],
          // Scoped to the one Agent Space the bridge uses (these actions
          // support the AgentSpace resource type).
          resources: [
            `arn:${{this.partition}}:securityagent:${{this.region}}:${{this.account}}:agent-space/${{secSpaceId}}`,
          ],
        }}));
        env.runtime.role.addToPrincipalPolicy(new iam.PolicyStatement({{
          actions: ['s3:PutObject', 's3:GetObject'],
          resources: [`arn:aws:s3:::${{secDiffBucket}}/diffs/*`],
        }}));
      }}
    }}
"""

ts = open(cdk_stack).read()
if MARKER in ts:
    print("3/3 cdk-stack.ts: bridge block already present")
else:
    lines = ts.splitlines(keepends=True)
    start = next((i for i, l in enumerate(lines) if "this.application = new AgentCoreApplication(" in l), None)
    if start is None:
        sys.exit(f"Error: could not find 'this.application = new AgentCoreApplication(' in {cdk_stack}. "
                 "Paste the block from a2a-bridge/DEPLOY.md step 3 by hand, right after the application is created.")
    # The constructor call may span several lines; insert after the line that closes it.
    end = next((i for i in range(start, len(lines)) if lines[i].rstrip().endswith(");")), None)
    if end is None:
        sys.exit(f"Error: could not find the end of the AgentCoreApplication statement in {cdk_stack}.")
    lines.insert(end + 1, BLOCK)
    ts = "".join(lines)
    if not re.search(r"""^import \* as iam from ['"]aws-cdk-lib/aws-iam['"];""", ts, re.M):
        ts = "import * as iam from 'aws-cdk-lib/aws-iam';\n" + ts
    open(cdk_stack, "w").write(ts)
    print("3/3 cdk-stack.ts: added env vars + IAM block after the AgentCoreApplication")

# --- 3b. cdk.json context values ---
data = json.load(open(cdk_json))
data.setdefault("context", {}).update({
    "securityAgentSpaceId": os.environ["SECURITY_AGENT_SPACE_ID"],
    "codeReviewId": os.environ["CODE_REVIEW_ID"],
    "diffBucket": os.environ["DIFF_BUCKET"],
})
with open(cdk_json, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("    cdk.json: set securityAgentSpaceId, codeReviewId, diffBucket")
PY

cat <<EOF

Bridge project configured: $PROJECT

Next (README step e.4):
  cd "$PROJECT"
  agentcore deploy --dry-run     # confirm it targets the account/region you expect
  agentcore deploy --yes
  agentcore status               # wait until the agent is deployed / READY
EOF
