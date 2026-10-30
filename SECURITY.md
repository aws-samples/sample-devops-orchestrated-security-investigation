# Security

This sample is **intentionally flawed** for demonstration purposes. It must only
be deployed in a disposable sandbox AWS account, in a single region, and torn
down when you are finished.

## Planted regression (what the Security Agent should find)

The incident has two faces: an operational fault that `app/break-it.sh`
deploys, and a security regression that represents the code change shipped
with it. The planted issues are:

| # | Issue | Where | Role in the demo |
|---|---|---|---|
| 1 | Operational fault (`BREAK_APP` env var) that forces 5xx under load | task definition set by `app/break-it.sh`; code in `app/app.py` | The DevOps Agent's entry point — trips the 5xx alarm |
| 2 | Dropped authorization check on the `POST /admin/notes` route | `app/changes/dropped-auth.patch` (staged in S3 for review; **not deployed**) | The security root cause — what the Security Agent reviews (found as a HIGH or CRITICAL `AUTHENTICATION_BYPASS`) |

Issue 1 is reverted by `app/fix-it.sh`. Issue 2 exists only as the staged
patch: the deployed app keeps its authorization check in every revision. Both
are removed entirely by `teardown.sh`.

In the deployed app, `POST /admin/notes` **fails closed**: the sample provisions
no `NIMBUS_AUTH_TOKEN`, so every request is rejected with `401` (the check also
uses a constant-time comparison). Writes are create-only
(`attribute_not_exists(id)`), so an existing note cannot be overwritten. The
shared-token check is a stand-in for a real authorizer; a production service
would put the route behind IAM/SigV4 or an identity provider.

### Standing conditions (part of the demo, not toggled by the break switch)

| Condition | Where | Why it is here |
|---|---|---|
| ALB security group open to `0.0.0.0/0` on port 80 (plain HTTP) | `infra/template.yaml` (`AlbSg`) | The app must receive public traffic to produce a live incident. Sandbox-only. |
| gunicorn binds `0.0.0.0:8080` inside the container | `app/Dockerfile` | Required so the ALB can reach the task; `ServiceSg` admits only the ALB's security group. (`app.py`'s local-dev entry point binds `127.0.0.1`.) |
| IAM roles for the task, forwarder Lambda, bridge, and SigV4 access | `infra/template.yaml`, `a2a-bridge/configure-bridge.sh`, `scripts/create-sigv4-role.sh` | Scoped to the sample's own resources (one table, one secret, one Agent Space + the bucket's `diffs/` prefix, one bridge runtime). |

## What is NOT planted

- No real credentials and no real or personal data. There is no seed data; the
  notes table holds only what is created during the demo.
- No internet-exposed datastore. DynamoDB is accessed only by the service, and
  the only write route rejects every request in the deployed app (see above).
- The remote A2A agent does not modify the workload. Its only writes are
  starting a Security Agent review job and uploading a diff under the review
  bucket's `diffs/` prefix.

## Security scanners

Because this sample creates insecure conditions on purpose, security scanners
will report them. The planted regression and the standing conditions above are
intentional; check those tables before reporting a scanner result as an issue.

## Reporting a genuine issue

If you find a security issue in this sample that is **not** one of the
intentional conditions documented above, notify AWS/Amazon Security via the
[vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/).
Please do **not** create a public GitHub issue.
