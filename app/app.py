"""
Nimbus-style synthetic app for the composed DevOps + Security agent sample.

Intentionally minimal. The point of this app is to produce ONE bad deploy that
is simultaneously:
  (1) an operational fault  -> 5xx under load, which the DevOps Agent investigates
  (2) a security regression -> a dropped authorization check, which the Security
      Agent reviews in the diff.

Sandbox only. Not for production. See SECURITY.md.
"""

import hmac
import os

import boto3
from botocore.exceptions import ClientError
from flask import Flask, request, jsonify

app = Flask(__name__)

TABLE_NAME = os.environ.get("TABLE_NAME", "nimbus-notes")
REGION = os.environ.get("AWS_REGION", "us-east-1")

# Operational fault toggle. break-it.sh flips BREAK_APP=true in the task
# definition; the DevOps Agent spots this env change by diffing task-def
# revisions, and the service starts failing under load.
BREAK_APP = os.environ.get("BREAK_APP", "false").lower() == "true"

_dynamodb = boto3.resource("dynamodb", region_name=REGION)


def _table():
    return _dynamodb.Table(TABLE_NAME)


def _is_authorized(req) -> bool:
    """Authorization check for sensitive routes. Fails closed.

    This is a stand-in for a real authorizer (a production service would put the
    route behind IAM/SigV4 or an identity provider). The sample provisions no
    NIMBUS_AUTH_TOKEN, so in the healthy build every request to a sensitive
    route is rejected with 401.

    NOTE: app/changes/dropped-auth.patch removes the call to this check (see
    SECURITY.md item #2). That dropped check is the security regression the
    Security Agent is meant to find when the DevOps Agent delegates the diff.
    """
    expected = os.environ.get("NIMBUS_AUTH_TOKEN", "")
    if not expected:
        # No credential configured: deny everything. Never compare against "",
        # or an empty header would pass.
        return False
    supplied = req.headers.get("x-nimbus-auth", "")
    return hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8"))


@app.route("/")
def index():
    # Static, plain-text landing response (no request input is echoed back).
    return "Nimbus notes.", 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.route("/health")
def health():
    # Always healthy so the ALB keeps the task in service; the incident shows up
    # as 5xx on the main route under load, not as failed health checks.
    return "ok", 200


@app.route("/notes", methods=["GET"])
def list_notes():
    if BREAK_APP:
        # Operational fault: force a 5xx under load. In a real run this stands in
        # for the bad deploy's runtime failure (e.g. an unhandled dependency
        # error) that trips the 5xx CloudWatch alarm.
        raise RuntimeError("BREAK_APP enabled: simulated downstream failure")
    resp = _table().scan(Limit=25)
    return jsonify(resp.get("Items", [])), 200


@app.route("/admin/notes", methods=["POST"])
def admin_create_note():
    # Sensitive route. The healthy build requires authorization; the planted
    # regression removes it. This is the diff the Security Agent reviews.
    if not _is_authorized(request):
        return jsonify({"error": "unauthorized"}), 401
    body = request.get_json(force=True, silent=True) or {}
    try:
        # Create only: refuse to overwrite an existing note with the same id.
        _table().put_item(
            Item={"id": body.get("id", "note"), "text": body.get("text", "")},
            ConditionExpression="attribute_not_exists(id)",
        )
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return jsonify({"error": "a note with this id already exists"}), 409
        raise
    return jsonify({"created": True}), 201


if __name__ == "__main__":
    # Local development only: bind to loopback by default (override with HOST).
    # The deployed container does not use this entry point; gunicorn (see
    # app/Dockerfile) binds inside the task's private network, where only the
    # ALB security group can reach it.
    app.run(host=os.environ.get("HOST", "127.0.0.1"), port=8080)
