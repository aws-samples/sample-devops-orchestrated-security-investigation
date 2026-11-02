# Deploying the A2A bridge

The bridge is a Strands agent hosted on **AgentCore Runtime (A2A protocol)**. It
is deployed with the **AgentCore CLI**, which scaffolds a project, builds the
code, and provisions the runtime. (It is not a plain `docker build` / ECS
service — the `Dockerfile` here is reference only.)

## Prerequisites

- Node.js 20+ and the AgentCore CLI: `npm install -g @aws/agentcore`
- `uv` (Python package manager the CLI uses): `curl -LsSf https://astral.sh/uv/install.sh | sh`
- A Security Agent Agent Space with code review enabled, a code review resource
  for the app repo (full source uploaded to the connected S3 bucket), and that
  bucket name. You need three values:
  - `SECURITY_AGENT_SPACE_ID` (as-...)
  - `CODE_REVIEW_ID` (cr-...)
  - `DIFF_BUCKET` (the S3 bucket connected to the Agent Space)

## 1. Scaffold a Strands A2A project

The CLI generates its own project structure. Run it one directory outside this
repo. The `--name` must be alphanumeric + underscores (no hyphens).

```bash
agentcore create \
  --project-name NimbusSecBridge \
  --name nimbus_security_review_agent \
  --language Python \
  --framework Strands \
  --model-provider Bedrock \
  --memory none \
  --build CodeZip \
  --protocol A2A
```

This produces `app/nimbus_security_review_agent/main.py` (the entrypoint) and
`app/nimbus_security_review_agent/pyproject.toml`.

## 2-3. Configure the scaffold (recommended: one script)

Steps 2 and 3 below are done for you by `configure-bridge.sh`. Export the three
values, then run it from the root of this repo against the scaffolded project:

```bash
export SECURITY_AGENT_SPACE_ID=as-...   # real values, no angle brackets
export CODE_REVIEW_ID=cr-...
export DIFF_BUCKET=your-bucket
./a2a-bridge/configure-bridge.sh ../NimbusSecBridge
```

It copies `bridge.py` over the entrypoint, adds `boto3`, inserts the CDK block
from step 3 after the `AgentCoreApplication` is created, and writes the three
values into `cdk.json`. It refuses placeholder values and is safe to re-run.
The manual steps are kept below for reference.

## 2. Drop in the bridge code (manual)

Replace the generated `main.py` with this directory's `bridge.py` (it uses the
same `serve_a2a(StrandsA2AExecutor(agent))` entry the scaffold expects), and add
`"boto3 >= 1.35.0"` to the `dependencies` list in the scaffold's
`pyproject.toml`.

## 3. Wire the three config values + IAM (manual)

The runtime needs `SECURITY_AGENT_SPACE_ID`, `CODE_REVIEW_ID`, `DIFF_BUCKET` as
environment variables, and its execution role needs permission to call the
Security Agent (scoped to your Agent Space) and to read/write diffs under the
bucket's `diffs/` prefix. The AgentCore CLI deploys via CDK;
add this to the generated `agentcore/cdk/lib/cdk-stack.ts` right after the
`AgentCoreApplication` is created, and set the three values in
`agentcore/cdk/cdk.json`'s `context` block:

```ts
const secSpaceId = this.node.tryGetContext('securityAgentSpaceId');
const secCodeReviewId = this.node.tryGetContext('codeReviewId');
const secDiffBucket = this.node.tryGetContext('diffBucket');
if (secSpaceId && secCodeReviewId && secDiffBucket) {
  for (const env of this.application.environments.values()) {
    env.runtime.addEnvironmentVariable('SECURITY_AGENT_SPACE_ID', String(secSpaceId));
    env.runtime.addEnvironmentVariable('CODE_REVIEW_ID', String(secCodeReviewId));
    env.runtime.addEnvironmentVariable('DIFF_BUCKET', String(secDiffBucket));
    env.runtime.role.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: [
        'securityagent:StartCodeReviewJob',
        'securityagent:BatchGetCodeReviewJobs',
        'securityagent:ListFindings',
      ],
      // Scoped to the one Agent Space the bridge uses (these actions support
      // the AgentSpace resource type in the Service Authorization Reference).
      resources: [
        `arn:${this.partition}:securityagent:${this.region}:${this.account}:agent-space/${secSpaceId}`,
      ],
    }));
    env.runtime.role.addToPrincipalPolicy(new iam.PolicyStatement({
      actions: ['s3:PutObject', 's3:GetObject'],
      resources: [`arn:aws:s3:::${secDiffBucket}/diffs/*`],
    }));
  }
}
```

```jsonc
// agentcore/cdk/cdk.json -> "context": { ... }
"securityAgentSpaceId": "as-...",
"codeReviewId": "cr-...",
"diffBucket": "your-bucket"
```

## 4. Deploy

```bash
cd ../NimbusSecBridge
agentcore deploy --dry-run   # optional: builds + synthesizes, deploys nothing
agentcore deploy --yes       # uses AWS_PROFILE / AWS_REGION from your environment
agentcore status             # repeat until the agent is deployed (not "Local only")
```

On an account that has never used CDK, `--dry-run` reports "AWS environment
needs bootstrapping"; `deploy --yes` bootstraps it automatically (one-time
`CDKToolkit` stack).

Capture the runtime ARN without copy-pasting it:

```bash
export AGENT_RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes \
  --region "$REGION" --output text \
  --query "agentRuntimes[?contains(agentRuntimeName, 'nimbus_security_review_agent')].agentRuntimeArn | [0]")
echo "$AGENT_RUNTIME_ARN"    # must print an arn:aws:bedrock-agentcore:... value, not None
```

## 5. Verify (optional)

Stage the patch first (docs/WALKTHROUGH.md step c.4), then:

```bash
agentcore invoke --prompt "Start a security review of the staged change for the nimbus-notes service."
```

The agent calls `start_security_review` (which returns a job id within
seconds) and then keeps calling `get_security_findings` until the review
finishes, so the command shows "Invoking Agent" for the whole review —
typically 10-15 minutes. The CLI may time out first with `A2A invoke failed`;
the review keeps running. Check its status and findings with the
`aws securityagent` commands in docs/WALKTHROUGH.md step g.

During a real delegation this is not a problem: each `get_security_findings`
call returns within ~45 seconds, under the DevOps Agent's 1-minute A2A idle
timeout.

The runtime logs show repeated `Failed to export span batch code: 400` errors
from the scaffold's OpenTelemetry tracing (it needs CloudWatch Transaction
Search enabled). They are harmless.

## 6. Register as a DevOps Agent remote agent

Create the SigV4 role with `../scripts/create-sigv4-role.sh` (needs
`AGENT_RUNTIME_ARN`), then run `../scripts/register-remote-agent.sh` for the
agent card URL and the exact console steps.

**SigV4 role trust policy:** the role the DevOps Agent assumes must trust the
`aidevops.amazonaws.com` service principal (not `bedrock-agentcore`), confined
with `aws:SourceAccount` and `aws:SourceArn`
(`arn:aws:aidevops:<region>:<account>:service/*`). This matches the official
DevOps Agent MCP-integration template. The role's permission policy must grant BOTH
`bedrock-agentcore:GetAgentCard` (registration fetches/validates the agent card)
and `bedrock-agentcore:InvokeAgentRuntime` (delegation calls), scoped to the
bridge runtime ARN (+ `/*`).

If the bridge's logs show `AccessDenied` on a `securityagent:` call, compare the
resource ARN in the error with the policy in step 3: the Agent Space id in it
must match the `securityAgentSpaceId` you configured.

Errors you may hit during registration, in order, and their fix:
- "Invalid STS role configuration ... sigv4McpServerSession. Verify the role's
  trust policy." -> trust principal must be `aidevops.amazonaws.com` with the
  SourceAccount/SourceArn conditions (above).
- "Credential should be scoped to correct service: 'bedrock-agentcore'." -> set
  the registration's SigV4 **Service name** to `bedrock-agentcore` (Region
  `us-east-1`).
- "not authorized to perform: bedrock-agentcore:GetAgentCard" -> add
  `GetAgentCard` to the role's permission policy.

### Note on the monitored account

The account the DevOps Agent monitors should **not** contain customer-controlled
compute (CodeBuild/CloudShell/SageMaker). That is why this sample builds the app
image locally rather than with in-stack CodeBuild.
