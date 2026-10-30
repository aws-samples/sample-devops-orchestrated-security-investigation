"""
Alarm forwarder: CloudWatch alarm -> SNS -> this Lambda -> DevOps Agent webhook.

A CloudWatch alarm action cannot issue an HTTP request, so this function sits
between the SNS topic and the AWS DevOps Agent generic webhook. It builds the
incident payload, signs it with HMAC over `timestamp:body` (SHA-256, base64),
and posts it with the signature and timestamp headers.

Pattern mirrors sample-devops-agent-security-triage. The signing secret and the
webhook URL are read from Secrets Manager; neither is hard-coded or stored in
stack outputs.

Sandbox only. Not for production.
"""

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request

import boto3

WEBHOOK_SECRET_ID = os.environ["WEBHOOK_SECRET_ID"]  # Secrets Manager secret id
REGION = os.environ.get("AWS_REGION", "us-east-1")

_secrets = boto3.client("secretsmanager", region_name=REGION)
_cached = {}


def _webhook_config():
    """Return {'url':..., 'secret':...} from Secrets Manager (cached)."""
    if not _cached:
        raw = _secrets.get_secret_value(SecretId=WEBHOOK_SECRET_ID)["SecretString"]
        _cached.update(json.loads(raw))
    return _cached


def _sign(secret: str, timestamp: str, body: str) -> str:
    # The webhook verifies an HMAC over the string "timestamp:body". The colon
    # separator matters; any other join will fail verification.
    msg = f"{timestamp}:{body}".encode("utf-8")
    digest = hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).digest()
    return base64.b64encode(digest).decode("utf-8")


def _build_payload(alarm: dict) -> dict:
    alarm_name = alarm.get("AlarmName", "unknown-alarm")
    account = alarm.get("AWSAccountId", "unknown")
    region = alarm.get("Region", REGION)
    return {
        "eventType": "incident",
        "incidentId": f"cw-{alarm_name}-{int(time.time())}",
        "action": "created",
        "priority": "HIGH",
        "title": f"5xx surge on nimbus service ({alarm_name})",
        # Put as much context as possible here: the DevOps Agent starts from the
        # description. We name the account/region and point it at the likely
        # cause (a recent deployment) so it diffs task-def revisions early, which
        # is what surfaces the security-shaped root cause it then delegates.
        "description": (
            f"Alarm {alarm_name} entered ALARM in account {account}, {region}. "
            "The nimbus-notes ECS service is returning 5xx under load. Reconstruct "
            "the incident: diff recent ECS task-definition revisions to find what "
            "changed, identify the deployer from CloudTrail, and if the root cause "
            "is a code or configuration change, delegate a security review of that "
            "change to the connected Security remote agent and incorporate its "
            "findings."
        ),
        "service": "nimbus-notes",
        "data": {"alarmName": alarm_name},
    }


def handler(event, _context):
    cfg = _webhook_config()
    url, secret = cfg["url"], cfg["secret"]
    # Only ever send the signed incident to an https:// URL. This also rules out
    # file:// and other urllib schemes.
    if not url.lower().startswith("https://"):
        raise ValueError("Webhook URL must use https://")

    for record in event.get("Records", []):
        sns_msg = record["Sns"]["Message"]
        try:
            alarm = json.loads(sns_msg)
        except json.JSONDecodeError:
            alarm = {"AlarmName": "unparsed-alarm"}

        # ISO-8601 UTC timestamp: the format the DevOps Agent webhook documents
        # for x-amzn-event-timestamp (also used for replay protection).
        timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        payload = _build_payload(alarm)
        payload["timestamp"] = timestamp
        body = json.dumps(payload)
        signature = _sign(secret, timestamp, body)

        req = urllib.request.Request(
            url,
            data=body.encode("utf-8"),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "x-amzn-event-signature": signature,
                "x-amzn-event-timestamp": timestamp,
            },
        )
        # B310 / dynamic-urllib suppressed: the URL comes from Secrets Manager
        # (not from the event) and is checked to be https:// above.
        with urllib.request.urlopen(req, timeout=10) as resp:  # nosec B310 # nosemgrep: dynamic-urllib-use-detected
            status = resp.status
        print(f"Posted incident {payload['incidentId']} -> {status}")

    return {"ok": True}
