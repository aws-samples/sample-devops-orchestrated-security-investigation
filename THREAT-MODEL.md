# Threat model

This is the gating artifact for publishing this security-flavoured sample. It
documents what the sample deploys, what could go wrong, and the controls that
keep the blast radius inside a disposable sandbox account.

## 1. What this sample is

A demonstration of two managed AWS agents (DevOps Agent + Security Agent)
composed over the A2A protocol to investigate one cross-domain incident. It
deploys a deliberately-flawed web app and a thin A2A bridge, and stages a
security regression (as a patch) that the agents investigate. It is educational
sample code, MIT-0, not for production.

## 2. Assets

| Asset | Sensitivity | Notes |
|---|---|---|
| Synthetic app + its notes table | None | No seed data; only notes created during the demo, which can only be created by a caller with the (unprovisioned) credential |
| Sample IAM roles (task role, forwarder role, bridge runtime role) | Medium | Scoped to the sample's own resources: task role → one DynamoDB table; forwarder → one secret; bridge → one Security Agent Agent Space and the bucket's `diffs/` prefix |
| DevOps Agent / Security Agent Agent Spaces | Medium | Investigation and review only; neither agent applies changes |
| SigV4 role the DevOps Agent assumes to reach the bridge | Medium | Trusts only `aidevops.amazonaws.com` (with `aws:SourceAccount` / `aws:SourceArn`); can only call `bedrock-agentcore:GetAgentCard` and `InvokeAgentRuntime` on the bridge runtime |
| Webhook signing secret | Medium | Secrets Manager only; entered from a prompt, never on the command line or in stack outputs |

## 3. Trust boundaries

- End-user traffic → ALB → ECS service (public HTTP ingress, by design, to
  produce a live incident). The tasks accept traffic only from the ALB's
  security group.
- CloudWatch alarm → SNS (customer managed KMS key) → Lambda forwarder → DevOps
  Agent webhook (HTTPS, HMAC-signed; secret in Secrets Manager).
- DevOps Agent → remote A2A agent on AgentCore Runtime (SigV4-authenticated).
- Remote A2A agent → AWS Security Agent API and the review bucket (IAM scoped
  to one Agent Space and one S3 prefix).
- Remote A2A agent → Amazon Bedrock (model inference). The default model id is
  a global cross-Region inference profile, so inference may be served outside
  the deployment region; set `BRIDGE_MODEL_ID` to change this.

## 4. Threats and controls

| Threat | Control |
|---|---|
| Deployed into a shared/production account | `deploy.sh` refuses to run without `--sandbox-confirmed`; README and SECURITY.md lead with the sandbox-only warning. All scripts read one `REGION` variable, and the README requires both Agent Spaces in that region |
| Public endpoint abused to write data | `POST /admin/notes` fails closed: no credential is provisioned, so every request gets `401` (constant-time comparison). Writes are create-only (`attribute_not_exists(id)`), so existing notes cannot be overwritten. The data is synthetic |
| Planted regression used as an attack recipe | The dropped-auth change exists only as a staged patch for the Security Agent to review; it is never deployed. No real credentials anywhere |
| Agent performs a destructive action | Both agents only **propose**; nothing auto-applies. The remote agent's only writes are starting a Security Agent review job and uploading a diff under `diffs/`; it cannot modify the app, its infrastructure, or its data |
| Webhook forgery / replay | HMAC signature over `timestamp:body`; signed timestamp for replay protection; signing secret in Secrets Manager; webhook URL is HTTPS |
| Prompt injection via investigated content into the remote agent | The remote agent's system prompt treats investigated content as untrusted data; its tools can only start a review and read findings, which bounds the impact; see DevOps Agent prompt-injection guidance |
| Secrets leaking into the repo or stack outputs | `scripts/lint-repo.sh` blocks hard-coded account IDs, access keys, routable IPs, and absolute home paths, and fails if a check cannot run; no secret in stack outputs |
| Resources left running and costing money | 7-day log retention. `teardown.sh` deletes the app stack, the app ECR repository, task-definition revisions, the forwarder log group, and (when given the ids) the bridge runtime, its log group, and its stack. `docs/TEARDOWN.md` lists the remaining manual removals (secret, SigV4 role, S3 bucket, CDK bootstrap, console registrations, Agent Spaces) |

## 5. Blast-radius fence

- One account, one deployment region, sandbox only (model inference may be
  served cross-Region, see §3).
- IAM roles scoped to the sample's own resources.
- No cross-account access.
- No datastore is internet-exposed. DynamoDB is reached only by the tasks, and
  the only write route rejects every request.
- Teardown is a release-gate requirement, not optional cleanup.

## 6. Residual risk

The ALB is intentionally reachable over the public internet on plain HTTP so a
real incident can be generated. While deployed, anyone can read the synthetic
notes list and trigger the forced 5xx responses; they cannot write or overwrite
data. This is acceptable **only** in a disposable sandbox account for the
duration of the demo. The controls above keep the impact bounded to that
account; the user is responsible for deploying it as documented and tearing it
down the same day.
