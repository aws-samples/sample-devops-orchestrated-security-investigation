#!/usr/bin/env python3
"""Read a task definition JSON on stdin, set the BREAK_APP env var on every
container to the value passed as argv[1] ("true"/"false"), and emit a
register-task-definition-ready JSON on stdout.

Strips fields that register-task-definition does not accept.
"""
import json
import sys

value = sys.argv[1] if len(sys.argv) > 1 else "false"
td = json.load(sys.stdin)

# Drop read-only / server-managed fields.
for field in (
    "taskDefinitionArn",
    "revision",
    "status",
    "requiresAttributes",
    "compatibilities",
    "registeredAt",
    "registeredBy",
    "deregisteredAt",
):
    td.pop(field, None)

for container in td.get("containerDefinitions", []):
    env = {e["name"]: e["value"] for e in container.get("environment", [])}
    env["BREAK_APP"] = value
    container["environment"] = [{"name": k, "value": v} for k, v in env.items()]

json.dump(td, sys.stdout)
