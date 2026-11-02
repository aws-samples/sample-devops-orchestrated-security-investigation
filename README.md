# DevOps-orchestrated security investigation (two managed agents, one incident)

> ⚠️ **Intentionally vulnerable. Sandbox account only. Single region. Tear down
> after.** This sample plants a security regression on purpose and deploys an
> IAM role, a public ALB, and a running service. It is for education and
> demonstration — **not for production**. Do not run it in a shared or
> production account. See [`SECURITY.md`](SECURITY.md) for the planted-regression
> inventory and [`THREAT-MODEL.md`](THREAT-MODEL.md) for the sandbox guards and
> blast-radius fence.

> ⚠️ **NOT for Production Deployments**
>
> **About `--sandbox-confirmed`:** `deploy.sh` will not run unless you pass
> `--sandbox-confirmed`. Passing it is **your acknowledgment** that you are
> deploying into a disposable sandbox AWS account that you own and use for
> nothing else. The script **cannot verify** that the account is a sandbox, and
> it deploys straight away once the flag is given. Before you run it, confirm
> which account your credentials point to with
> `aws sts get-caller-identity --query Account --output text`, and do not pass
> the flag if you are unsure.

An end-to-end sample where **one bad deploy** trips a single incident with two
faces, an operational outage *and* a security regression, and two managed AWS
agents investigate it **together**. The **AWS DevOps Agent** catches the alarm,
finds the root cause, and **delegates a subtask over the Agent-to-Agent (A2A)
protocol** to a remote agent on **Amazon Bedrock AgentCore Runtime**. That agent
runs a real **AWS Security Agent** differential code review, and the findings
fold back into the same investigation. One incident, two agents, one timeline.
Humans approve everything; nothing is applied automatically.

---

## The story

A deploy goes out. Minutes later the 5xx alarm fires and the on-call engineer
gets paged. The outage is only half the problem: the change that shipped with
that deploy also dropped an authorization check on an admin route. Usually
that is two incidents, two teams, and two timelines. The operations team rolls
back, and the security issue is found days later, if at all.

This sample hands both halves to agents that work together. The AWS DevOps
Agent picks up the alarm, traces it to the bad deploy, and recognizes that the
cause is a code change. Instead of stopping there, it asks a security specialist
for help: over A2A, it delegates the review of that change to a remote agent,
which drives the AWS Security Agent. The Security Agent flags the missing
authorization check as an `AUTHENTICATION_BYPASS`, and that finding lands back
in the DevOps Agent's investigation, next to the operational root cause. A human
reviews the whole picture and decides what to do.

---

## Architecture

![Architecture](docs/architecture.png)

The end-to-end flow, validated live:

1. **The incident.** A deliberately flawed Flask app runs on **ALB → ECS
   Fargate → DynamoDB**, with CloudWatch logs and a 5xx alarm.
   `app/break-it.sh` deploys a bad revision that forces 5xx errors. The code
   change that "ships" with that deploy, removing the authorization check on
   `POST /admin/notes`, is modeled by
   [`app/changes/dropped-auth.patch`](app/changes/dropped-auth.patch). The patch
   is **staged for review, not deployed**: the running app keeps its auth check
   and fails closed (`401`) in every revision.
2. **The alert.** The alarm notifies **SNS**, and a **Lambda forwarder**
   HMAC-signs the incident and posts it to the **AWS DevOps Agent** webhook.
3. **The investigation.** The DevOps Agent runs root-cause analysis and, because
   the cause is a code change, **delegates a subtask over A2A** to the bridge.
4. **The handoff.** The bridge is a **Strands agent on AgentCore Runtime**. It
   does not modify the workload; its only writes are starting a review job and
   uploading the diff to the review bucket. It calls the **AWS Security Agent**
   API to run a differential review of the staged patch and read the findings.
5. **One timeline.** The Security Agent reports an **`AUTHENTICATION_BYPASS`**
   on `POST /admin/notes` (HIGH or CRITICAL, depending on the run), which folds
   back into the DevOps Agent investigation.

## How it works

| Layer | Service | Role in the sample |
|---|---|---|
| Workload | Application Load Balancer, Amazon ECS on AWS Fargate, Amazon DynamoDB | The synthetic notes app that breaks |
| Detection | Amazon CloudWatch (logs + 5xx alarm), Amazon SNS | Notices the outage and raises the alarm |
| Alert delivery | AWS Lambda forwarder, AWS Secrets Manager | HMAC-signs the incident and posts it to the DevOps Agent webhook |
| Operations agent | AWS DevOps Agent | Investigates the incident, finds the bad deploy, delegates over A2A |
| Remote agent | Amazon Bedrock AgentCore Runtime + Strands Agents | The A2A bridge between the two managed agents |
| Model | Amazon Bedrock (Anthropic Claude Sonnet 4.5 by default) | Reasoning model for the bridge |
| Security agent | AWS Security Agent, Amazon S3 | Differential code review of the staged patch |
| Access | AWS IAM (SigV4 role) | Lets the DevOps Agent call only this bridge runtime |

The app stack is one CloudFormation template ([`infra/template.yaml`](infra/template.yaml)),
deployed by `deploy.sh`. The bridge is deployed with the AgentCore CLI, and the
two Agent Spaces are set up in their consoles. **This is not a one-click
deploy;** the walkthrough covers every piece.

---

## Prerequisites

- A disposable **sandbox** AWS account, used for nothing else.
- A **single Region** where both AWS DevOps Agent and AWS Security Agent are
  available, with **both Agent Spaces** created in that Region.
- **Amazon Bedrock model access** for the bridge's model in that Region.
- **AWS CLI v2**, **finch or Docker**, **Node.js 20+** with the **AgentCore CLI**
  (`npm install -g @aws/agentcore`), and **`uv`**.

The full list, with the webhook secret and S3 bucket details, is in
[Prerequisites](docs/WALKTHROUGH.md#prerequisites).

---

## Deploy and run

Follow the **[full walkthrough](docs/WALKTHROUGH.md)**: it has every command,
the placeholders to fill in, and the troubleshooting notes. This table is a map
of it:

| Step | What you do | Key command |
|---|---|---|
| [a](docs/WALKTHROUGH.md#a-set-your-profile-and-region) | Set your profile and Region | `aws sts get-caller-identity` |
| [b](docs/WALKTHROUGH.md#b-set-up-the-two-agent-spaces-and-the-webhook-secret-console--cli) | Create the two Agent Spaces and store the webhook secret | console + `aws secretsmanager create-secret` |
| [c](docs/WALKTHROUGH.md#c-set-up-the-security-agent-code-review) | Set up the Security Agent code review and stage the patch | console + `aws s3 cp` |
| [d](docs/WALKTHROUGH.md#d-deploy-the-app-stack) | Deploy the app stack | `./deploy.sh --sandbox-confirmed` |
| [e](docs/WALKTHROUGH.md#e-deploy-the-a2a-bridge-agentcore-cli) | Deploy the A2A bridge | `agentcore create`, `./a2a-bridge/configure-bridge.sh`, `agentcore deploy` |
| [f](docs/WALKTHROUGH.md#f-create-the-sigv4-role-and-register-the-bridge-as-a-remote-agent) | Create the SigV4 role and register the bridge | `./scripts/create-sigv4-role.sh`, then console |
| [g](docs/WALKTHROUGH.md#g-optional-verify-the-bridge-on-its-own) | (Optional) Test the bridge on its own | `agentcore invoke` |
| [h](docs/WALKTHROUGH.md#h-trip-the-incident) | Trip the incident | `./app/break-it.sh` |
| [i](docs/WALKTHROUGH.md#i-watch-the-handoff) | Watch the handoff, then revert | `./app/fix-it.sh` |

Once everything is deployed, the incident takes about 5-8 minutes to trip and
the Security Agent review about 10-15 minutes.

---

## Repository structure

```
.
├── README.md                      # this file
├── SECURITY.md                    # planted-regression inventory; how to report real issues
├── THREAT-MODEL.md                # sandbox guards, blast-radius fence, teardown guarantees
├── CONTRIBUTING.md                # how to contribute; security issue notifications
├── CODE_OF_CONDUCT.md             # Amazon Open Source Code of Conduct
├── LICENSE                        # MIT-0
├── THIRD-PARTY-LICENSES           # attributions for dependencies fetched at build time
├── deploy.sh                      # build image locally, push to ECR, deploy the stack
├── teardown.sh                    # delete the stack and app image; prints manual removals
├── docs/
│   ├── WALKTHROUGH.md             # full deploy-and-run steps (a-i)
│   ├── TEARDOWN.md                # full teardown checklist
│   └── architecture.png           # the architecture diagram embedded above
├── app/                           # the deliberately-flawed Flask app
│   ├── app.py                     # ALB→Fargate→DynamoDB service; the vulnerable route
│   ├── Dockerfile                 # image built locally by deploy.sh
│   ├── requirements.txt           # app dependencies
│   ├── break-it.sh                # deploy the bad revision, generate 5xx traffic (or start the investigation)
│   ├── fix-it.sh                  # revert to the healthy revision
│   ├── _set_break_env.py          # helper: flips BREAK_APP on the task definition
│   └── changes/
│       └── dropped-auth.patch     # the diff the Security Agent reviews
├── forwarder/
│   └── forwarder.py               # SNS→Lambda: HMAC-sign and POST the incident to the webhook
├── infra/
│   └── template.yaml              # the app CloudFormation stack
├── a2a-bridge/                    # the remote agent
│   ├── bridge.py                  # Strands agent; drives the Security Agent API
│   ├── configure-bridge.sh        # applies the bridge code, boto3, env vars + IAM to the AgentCore scaffold
│   ├── requirements.txt           # bridge dependencies
│   ├── Dockerfile                 # reference only; AgentCore CLI builds the runtime
│   ├── agent_card.reference.json  # reference agent card
│   └── DEPLOY.md                  # full AgentCore CLI deployment steps
└── scripts/
    ├── create-sigv4-role.sh       # creates the IAM role the DevOps Agent uses to call the bridge
    ├── register-remote-agent.sh   # prints the agent card URL + remote-agent registration steps
    └── lint-repo.sh               # repo lint checks
```

---

## Cost

This sample runs paid resources while it is deployed: the Application Load
Balancer, the ECS Fargate tasks, VPC endpoints, a KMS key, DynamoDB, CloudWatch,
SNS, Lambda, Secrets Manager, ECR storage, the AgentCore Runtime, Amazon Bedrock
model invocations, and AWS DevOps Agent and AWS Security Agent usage. Treat it
as a short-lived demo, not something to leave running. Costs stop when you tear
it down.

## Tear down

This sample creates resources across CloudFormation, ECR, AgentCore, IAM,
Secrets Manager, S3, and the two managed Agent Spaces. Removing everything is a
mix of scripted and manual steps, so **work through the full
[teardown checklist](docs/TEARDOWN.md)** so nothing is left running (and
billing) in your account:

1. [**Scripted removal**](docs/TEARDOWN.md#step-1--scripted-removal):
   deregister the remote agent, then run
   `BRIDGE_STACK=AgentCore-NimbusSecBridge-default ./teardown.sh`.
2. [**Manual removal**](docs/TEARDOWN.md#step-2--manual-removal-what-the-scripts-do-not-delete):
   the webhook secret, the SigV4 role, the review bucket contents, and the CDK
   bootstrap if this sample created it.
3. [**Console removals**](docs/TEARDOWN.md#step-3--console-removals-no-cli):
   the remote-agent registration and both Agent Spaces.
4. [**Local cleanup**](docs/TEARDOWN.md#step-4--local-cleanup-no-cost-just-tidy).

---

## Security

This sample is intentionally vulnerable for demonstration. See:

- [`SECURITY.md`](SECURITY.md) — the planted-regression inventory and how to
  report a genuine (non-intentional) issue.
- [`THREAT-MODEL.md`](THREAT-MODEL.md) — the sandbox guards, blast-radius fence,
  and teardown guarantees.
- [`CONTRIBUTING.md`](CONTRIBUTING.md#security-issue-notifications) — how to
  report a potential security issue in this sample.

### Plain HTTP is for the sandbox demo only

The load balancer listens on plain HTTP (port 80) and `AppUrl` is an
`http://` URL. Nothing sensitive crosses it: the app serves synthetic notes,
and no credential is provisioned for its one write route. Traffic is not
encrypted in transit, so **do not reuse this listener pattern for a real
workload.** Before you adapt the template, move the load balancer to HTTPS:

1. Request or import a certificate in AWS Certificate Manager for a domain you
   own, and point that domain at the load balancer.
2. Add an HTTPS listener on port 443 that uses the certificate and a current
   TLS security policy (TLS 1.2 or later), forwarding to the same target group.
3. Change the port 80 listener to redirect to HTTPS, and allow port 443 in
   `AlbSg`.
4. Use the `https://` domain URL wherever the scripts read `AppUrl`.

See [Create an HTTPS listener for your Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html).

## Responsible AI

This sample uses generative AI in two places: the managed AWS DevOps Agent and
AWS Security Agent, and the A2A bridge, which runs an Anthropic Claude model
through **Amazon Bedrock** (default `global.anthropic.claude-sonnet-4-5-20250929-v1:0`,
set with `BRIDGE_MODEL_ID`). Keep these points in mind if you adapt it:

- **Humans stay in the loop.** Both agents only investigate and propose. Nothing
  the agents conclude is applied automatically: rollbacks (`./app/fix-it.sh`)
  and code fixes are human decisions.
- **Treat AI output as advisory.** Investigation summaries and security
  findings can be incomplete or wrong. Verify a finding against the code and
  the AWS Security Agent console before acting on it, and do not use the
  agents' output as the sole basis for production or security decisions.
- **Treat investigated content as untrusted.** Logs, diffs, and incident text
  can contain prompt-injection attempts. The bridge's system prompt treats all
  input as untrusted data, and its tools can only start a review and read
  findings, which bounds what a manipulated model could do. See
  [`THREAT-MODEL.md`](THREAT-MODEL.md).
- **Add guardrails for your own content.** The sample processes only synthetic
  data, so it does not configure [Amazon Bedrock Guardrails](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html).
  If you point the bridge at real code or incidents, create a guardrail (for
  example, sensitive-information filters for credentials and personal data,
  plus a prompt-attack filter) and apply it to the bridge's model invocations.
- **Data location.** The default model ID is a global cross-Region inference
  profile, so prompts and responses may be processed outside your deployment
  Region. Use a geographic profile (for example `us.`) through
  `BRIDGE_MODEL_ID` if you need inference kept in one geography.
- **Data handling.** No customer data, personal data, or secrets are sent to the
  model by the sample: it reviews the synthetic `dropped-auth.patch` and the
  sample's own source.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
Third-party dependency attributions are in
[THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES).
