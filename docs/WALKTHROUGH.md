# Deploy and run: full walkthrough

> ⚠️ **Sandbox account only. Not for production.** Read the warnings at the
> top of the [README](../README.md) before you start, and tear everything
> down when you are finished ([TEARDOWN.md](TEARDOWN.md)).

Run every command from the repository root unless a step says otherwise.

## How deployment works (read this first)

**This is not a one-click CloudFormation stack.** The app half *is* a single
CloudFormation stack, but it is deployed by `deploy.sh` — which builds the
container image locally first — and the managed-agent pieces live outside
CloudFormation by necessity. A composed-agents sample has several moving parts:

| Piece | How it's deployed |
|---|---|
| App (ALB, Fargate, DynamoDB, 5xx alarm, SNS, Lambda forwarder) | One CloudFormation stack, `infra/template.yaml`, deployed by `deploy.sh` |
| App container image | **Built locally by `deploy.sh`** (finch or Docker) for `linux/amd64`, pushed to ECR, passed to CloudFormation as the `ImageUri` parameter. The task runs on x86_64 Fargate, so the build is pinned to `--platform linux/amd64` (important on Apple-Silicon Macs). |
| DevOps Agent + Security Agent **Agent Spaces** | Console setup on the managed agents |
| A2A bridge | Amazon Bedrock **AgentCore Runtime**, deployed with the **AgentCore CLI** (see [`a2a-bridge/DEPLOY.md`](../a2a-bridge/DEPLOY.md)) |
| Remote-agent registration | Console / IAM step (see [`scripts/register-remote-agent.sh`](../scripts/register-remote-agent.sh)) |

---

## Prerequisites

- A disposable **sandbox** AWS account, used for nothing else.
- A **single region** where **both** AWS DevOps Agent and AWS Security Agent
  Agent Spaces are available. Pin everything to this one region — including
  **both Agent Spaces**. The consoles open in whatever region you last used, so
  check the region selector before you create each space.
- **Amazon Bedrock model access** in that region for the model the bridge uses
  (default: Anthropic Claude Sonnet 4.5, via the global cross-Region inference
  profile `global.anthropic.claude-sonnet-4-5-20250929-v1:0`, so inference may
  be served from other regions). Enable it in the Bedrock console under
  **Model access**, or set `BRIDGE_MODEL_ID` on the runtime to another model.
- **AWS CLI v2**, configured for the sandbox account.
- **finch or Docker** — the app image is built locally by `deploy.sh`.
- **Node.js 20+** and the **AgentCore CLI** (`npm install -g @aws/agentcore`),
  plus **`uv`** (`curl -LsSf https://astral.sh/uv/install.sh | sh`) — used to
  deploy the A2A bridge.
- A **DevOps Agent Agent Space** with a generic HMAC webhook configured. Store
  the webhook URL and signing secret in Secrets Manager as
  `<nameprefix>-devops-webhook` (default name prefix: `nimbus`).
- A **Security Agent Agent Space** with **code review enabled**, and an **S3
  bucket you create and connect to that Agent Space** (used as `DIFF_BUCKET`) —
  you upload the app source there and create a code review resource against it.
  Step (c) covers creating and connecting the bucket.

---

## Step-by-step: deploy and run

Every value in `<angle brackets>` is a placeholder — substitute your own and do
**not** paste the brackets. Do not paste real account IDs, resource IDs, or ARNs
into shared places.

> **Seeing `zsh: parse error near '\n'`?** A placeholder was pasted as-is: zsh
> reads `<` and `>` as redirections. Replace the whole `<...>` with the real
> value (quote it if unsure), e.g. `export CODE_REVIEW_ID="cr-1234..."`. If you
> pasted a multi-line block, nothing in that block ran — re-run it.
>
> Run every step in the **same terminal**: later steps read the variables you
> `export` earlier (`REGION`, `SECURITY_AGENT_SPACE_ID`, `CODE_REVIEW_ID`,
> `DIFF_BUCKET`, ...).
>
> **On macOS (zsh), run `setopt interactivecomments` first.** The code blocks
> below have trailing `# comments`; zsh's default treats `#` as part of the
> command when you paste it, which breaks those lines (for example
> `zsh: no matches found` or `not valid in this context`).

> **Finding your resource IDs.** Several steps need IDs for the Agent Spaces and
> the code review (`SECURITY_AGENT_SPACE_ID` like `as-...`, `CODE_REVIEW_ID`
> like `cr-...`, and the DevOps Agent space id). The most reliable source is the
> **console URL**: open the resource in its console and copy the id from the
> address bar (e.g. `.../agent-spaces/as-...`, `.../code-reviews/cr-...`). CLI
> `list` commands exist too, but these are preview-era services whose CLI shapes
> change — if a `list` command errors or returns nothing, use the console URL.

### a. Set your profile and region

```bash
setopt interactivecomments 2>/dev/null || true   # zsh: treat "# ..." as a comment
export AWS_PROFILE=<your-sandbox-profile>
export REGION=us-east-1            # a region where BOTH agents are available
export AWS_REGION=$REGION          # the AgentCore CLI reads AWS_REGION
export NAME_PREFIX=nimbus          # used to name the stack, ECR repo, secret
aws sts get-caller-identity --query Account --output text   # must print your sandbox account
```

### b. Set up the two Agent Spaces and the webhook secret (console + CLI)

Create the **DevOps Agent** and **Security Agent** Agent Spaces in their
respective consoles (see Prerequisites), **both in `$REGION`**. For the DevOps
Agent space, keep the wizard defaults (it creates the IAM roles, adds this
account as the primary account, and enables the Web App). Note each space's id
(from the console URL — see the callout above):

```bash
export AGENT_SPACE_ID=<devops-agent-space-id>
```

Then configure the DevOps Agent's **generic HMAC webhook**: in the DevOps Agent
console, open your Agent Space → **Capabilities** → add a **generic webhook** →
choose **HMAC**. It shows a **webhook URL** and a **signing secret** — copy both
now (the secret is shown only once). Store them in Secrets Manager so `deploy.sh`
can wire the Lambda forwarder to the webhook. This prompts for both values, so
the secret never appears on screen or in your shell history (zsh syntax; in
bash use `read -r -p "Webhook URL: " WEBHOOK_URL` and `read -rs -p ...`):

```bash
read -r "WEBHOOK_URL?Webhook URL: "
read -rs "WEBHOOK_SECRET?Signing secret: "; echo
TMP=$(mktemp); chmod 600 "$TMP"
printf '{"url":"%s","secret":"%s"}' "$WEBHOOK_URL" "$WEBHOOK_SECRET" > "$TMP"
aws secretsmanager create-secret --name "${NAME_PREFIX}-devops-webhook" \
  --secret-string "file://$TMP" --region "$REGION"
rm -f "$TMP"; unset WEBHOOK_SECRET
```

> Re-running? If the secret already exists, replace `create-secret --name` with
> `put-secret-value --secret-id` and keep the rest.

Check that the webhook belongs to a space in `$REGION` — this must print
`event-ai.<your-region>.api.aws`:

```bash
aws secretsmanager get-secret-value --secret-id "${NAME_PREFIX}-devops-webhook" \
  --region "$REGION" --query SecretString --output text \
  | python3 -c 'import json,sys,urllib.parse as u; print(u.urlparse(json.load(sys.stdin)["url"]).netloc)'
```

### c. Set up the Security Agent code review

This has **three distinct sub-steps** — enabling code review is not the same as
creating a code review resource. Do all three:

**c.1 — Create and connect an S3 bucket.** The Security Agent reads code from an
S3 bucket **connected to its Agent Space**; an ordinary bucket does not work
until it is connected.

```bash
aws s3 mb s3://<diff-bucket> --region "$REGION"   # skip if you already have one
```

Then in the Security Agent console: open the Agent Space → **Enable code
review** → **S3 buckets → Add** → enter `<diff-bucket>`. This bucket's name is
your `DIFF_BUCKET`.

**c.2 — Upload the app source as the review's context.**

```bash
rm -f app-source.zip
( cd app && zip -qr ../app-source.zip . -x '__pycache__/*' '.DS_Store' )
aws s3 cp app-source.zip s3://<diff-bucket>/source/ --region "$REGION"
```

**c.3 — Create the code review resource** (this is a separate action from
"enable code review", and it is what produces `CODE_REVIEW_ID`). In the Security
Agent **web app** (open it from the Agent Space → **Web app → Admin access**):
**Code reviews → Create code review** → Title e.g. `nimbus-notes-review` →
**S3 sources** tab → enter `s3://<diff-bucket>/source/app-source.zip` → default
service role → **Create**. Open the created review and copy its id (`cr-...`)
from the console URL.

Capture the three values the bridge needs (see the "Finding your resource IDs"
callout for where each comes from):

```bash
export SECURITY_AGENT_SPACE_ID=<security-agent-space-id>   # as-... (Agent Space URL)
export CODE_REVIEW_ID=<code-review-id>                     # cr-... (code review URL)
export DIFF_BUCKET=<diff-bucket>
```

**c.4 — Stage the review diff.** Put the implicated change where the bridge
will hand it to the Security Agent (`.patch` extension required):

```bash
aws s3 cp app/changes/dropped-auth.patch "s3://$DIFF_BUCKET/diffs/" --region "$REGION"
```

> The bucket must be **connected to the Security Agent Agent Space** (c.1), and
> any diff the Security Agent reviews must be a **`.patch`** file (not `.diff`).

### d. Deploy the app stack

```bash
./deploy.sh --sandbox-confirmed
```

`deploy.sh` refuses to run without the acknowledgment flag. It **builds and
pushes the app image locally** (finch or Docker → ECR), deploys the
CloudFormation stack (app, 5xx alarm, SNS, Lambda forwarder) with the image URI
as a parameter, and prints the **App URL** and the next steps. Set
`CONTAINER_CLI=docker` if you use Docker rather than finch.

### e. Deploy the A2A bridge (AgentCore CLI)

The bridge is **not** deployed by `deploy.sh`. It is a Strands agent on AgentCore
Runtime, deployed with the interactive AgentCore CLI. This is **more than one
command** — the CLI scaffolds its own project and you graft the bridge code and
config into it. [`a2a-bridge/DEPLOY.md`](../a2a-bridge/DEPLOY.md) has the full
detail; the sub-steps are:

**e.1 — Scaffold a Strands A2A project** (run one directory outside this repo;
`--name` must be alphanumeric/underscores, no hyphens):

```bash
cd ..
agentcore create --project-name NimbusSecBridge --name nimbus_security_review_agent \
  --language Python --framework Strands --model-provider Bedrock \
  --memory none --build CodeZip --protocol A2A
```

**e.2 + e.3 — Configure the scaffold with one script.** The scaffold needs three
edits: the bridge code as its entrypoint, `boto3` as a dependency, and the
runtime's env vars (`SECURITY_AGENT_SPACE_ID` / `CODE_REVIEW_ID` /
`DIFF_BUCKET`) plus IAM permissions to call the Security Agent.
[`a2a-bridge/configure-bridge.sh`](../a2a-bridge/configure-bridge.sh) makes all
three for you. Run it from this repo, in the terminal where you exported the
three values in step c:

```bash
cd sample-devops-orchestrated-security-investigation
./a2a-bridge/configure-bridge.sh ../NimbusSecBridge
```

It should print `1/3`, `2/3` and `3/3` lines and end with "Bridge project
configured". If it says a variable is missing or still looks like a
placeholder, export the real value from step c and re-run; it is safe to run
more than once. (To make the edits by hand instead, see
[`a2a-bridge/DEPLOY.md`](../a2a-bridge/DEPLOY.md) steps 2-3.)

> If you skip this step, the bridge still deploys, but every review fails with
> "Security Agent not configured".

**e.4 — Deploy and capture the runtime ARN.** The first command refuses to
deploy unless e.2 + e.3 succeeded, so an unconfigured scaffold is never
deployed:

```bash
grep -q "nimbus-security-bridge" ../NimbusSecBridge/agentcore/cdk/lib/cdk-stack.ts \
  || { echo "Bridge not configured: re-run configure-bridge.sh (step e.2 + e.3) first"; false; } \
  && cd ../NimbusSecBridge \
  && agentcore deploy --yes
agentcore status             # repeat until the agent is deployed (not "Local only")
```

`agentcore deploy --yes` uses the credentials and region in your environment
(`AWS_PROFILE`, `AWS_REGION`). On a fresh account it first CDK-bootstraps the
account (a one-time `CDKToolkit` stack). To preview without deploying, run
`agentcore deploy --dry-run` in `../NimbusSecBridge`; on a fresh account it
reports "AWS environment needs bootstrapping", which is expected.

> **Deployed it before configuring?** Run `configure-bridge.sh` (e.2 + e.3) and
> then e.4 again. The redeploy updates the same runtime, so its ARN does not
> change.

Capture the runtime ARN without copy-pasting it:

```bash
export AGENT_RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes \
  --region "$REGION" --output text \
  --query "agentRuntimes[?contains(agentRuntimeName, 'nimbus_security_review_agent')].agentRuntimeArn | [0]")
echo "$AGENT_RUNTIME_ARN"    # must print an arn:aws:bedrock-agentcore:... value, not None
```

> **Redeploying the bridge later?** A new runtime gets a new ARN (and agent
> card URL). Re-run `./scripts/create-sigv4-role.sh`, then remove, deregister,
> and re-register the remote agent (step f) with the new card URL. An
> investigation that still points at an old registration finishes without ever
> delegating to the bridge.

### f. Create the SigV4 role and register the bridge as a remote agent

The DevOps Agent reaches the bridge by assuming an IAM role and signing its A2A
calls with SigV4. Create the role (named `${NAME_PREFIX}-devops-to-bridge`),
then print the registration inputs:

```bash
cd ../sample-devops-orchestrated-security-investigation
./scripts/create-sigv4-role.sh          # needs AGENT_RUNTIME_ARN from e.4
export SIGV4_ROLE_ARN=$(aws iam get-role --role-name "${NAME_PREFIX}-devops-to-bridge" \
  --query Role.Arn --output text)
./scripts/register-remote-agent.sh      # prints the Agent card URL + console steps
```

The role trusts only `aidevops.amazonaws.com` (with `aws:SourceAccount` and
`aws:SourceArn` conditions) and can only call `bedrock-agentcore:GetAgentCard`
and `bedrock-agentcore:InvokeAgentRuntime` on the bridge runtime.

Then, in the DevOps Agent console (in `$REGION`):

1. **Capability Providers → Remote Agent → Register.** Name:
   `<nameprefix>-security-review-agent`. Agent card endpoint: the URL the script
   printed. Authentication: **AWS SigV4** → use an existing role →
   `<nameprefix>-devops-to-bridge`, Region `$REGION`, Service name
   `bedrock-agentcore`. **Next → Register** (the console fetches the agent card
   to validate it).
2. **Your Agent Space → Capabilities → Remote Agents → Add** → select
   `<nameprefix>-security-review-agent`.

If registration fails, [`a2a-bridge/DEPLOY.md`](../a2a-bridge/DEPLOY.md) step 6
lists the errors you can hit, in order, with the fix for each. The most common
is `Credential should be scoped to correct service: 'bedrock-agentcore'`, which
means the SigV4 **Service name** field is not exactly `bedrock-agentcore`.

### g. (Optional) Verify the bridge on its own

This checks the bridge → Security Agent half before you involve the DevOps
Agent, so a later failure is easier to place. Skip it if you want to go
straight to the incident.

```bash
cd ../NimbusSecBridge
agentcore invoke --prompt "Start a security review of the staged change for the nimbus-notes service."
```

The bridge starts a Security Agent review of the staged patch (c.4) and then
keeps waiting for it to finish, so the command shows "Invoking Agent" for the
whole review — typically 10-15 minutes. The CLI may give up first and print
`A2A invoke failed`; the review keeps running. Check it directly:

```bash
aws securityagent list-code-review-jobs-for-code-review --region "$REGION" \
  --agent-space-id "$SECURITY_AGENT_SPACE_ID" --code-review-id "$CODE_REVIEW_ID" \
  --query 'codeReviewJobSummaries[].[codeReviewJobId,status,createdAt]' --output text
```

When the newest job is `COMPLETED`, list its findings (expect an
`AUTHENTICATION_BYPASS` on `POST /admin/notes`):

```bash
aws securityagent list-findings --region "$REGION" \
  --agent-space-id "$SECURITY_AGENT_SPACE_ID" --code-review-job-id <cj-...> \
  --query 'findingsSummaries[].[riskLevel,riskType,name]' --output text
```

> The bridge's CloudWatch logs show repeated `Failed to export span batch code:
> 400` errors. They come from the scaffold's OpenTelemetry tracing (it needs
> CloudWatch Transaction Search enabled in the account) and do not affect the
> bridge.

### h. Trip the incident

One command deploys the bad revision, waits for it to roll out, and generates
the 5xx traffic that fires the alarm (alarm → SNS → forwarder → DevOps Agent
webhook → investigation):

```bash
cd ../sample-devops-orchestrated-security-investigation
./app/break-it.sh
```

It takes about 5-8 minutes. When it ends with "Alarm is in ALARM", the
investigation appears in the operator app within about a minute.

If your network **cannot reach the ALB** (VPN or egress blocks), no traffic
arrives and the alarm cannot fire. `break-it.sh` detects this and, if
`AGENT_SPACE_ID` is set (step b), starts the investigation directly with
[`aws devops-agent create-backlog-task`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/create-backlog-task.html)
instead. In that case the DevOps Agent still finds the bad deploy and delegates
the security review, but it reports that the ALB saw no traffic.

To always start the investigation directly (in addition to the alarm), run
`INVESTIGATE=always ./app/break-it.sh`.

**Can't reach the ALB but still want to test the alarm path?** Deploy the bad
revision without the fallback, then force the alarm. This runs the real alarm
action, so SNS (with its KMS key), the forwarder, and the DevOps Agent webhook
are all exercised:

```bash
INVESTIGATE=never ./app/break-it.sh      # wait for "Bad revision is live"
aws cloudwatch set-alarm-state --region "$REGION" --alarm-name "${NAME_PREFIX}-target-5xx" \
  --state-value ALARM --state-reason "Manual test of the alarm -> webhook path"
aws logs tail "/aws/lambda/${NAME_PREFIX}-forwarder" --region "$REGION" --since 10m
```

The forwarder log should show `Posted incident ... -> 200` within a minute or
two, and an investigation then starts on its own. Because no real 5xx traffic
reached the ALB, the investigation finds the bad deploy but no matching error
spike. Alternatively, send real traffic from another network (for example a
phone on mobile data) by loading `<app-url>/notes` about ten times in a minute.

### i. Watch the handoff

Open the DevOps Agent operator app. The investigation runs root-cause analysis
(it finds the task-definition revision with `BREAK_APP=true`), **delegates to
the bridge over A2A**, the Security Agent review runs (10-15 minutes), and the
**`AUTHENTICATION_BYPASS` finding on `POST /admin/notes` folds into the one
timeline**. Humans approve everything; nothing is applied automatically. When
done, revert the app:

```bash
./app/fix-it.sh
```
