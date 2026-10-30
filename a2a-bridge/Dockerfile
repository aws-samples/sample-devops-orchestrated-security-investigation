# REFERENCE ONLY. The bridge is deployed with the AgentCore CLI (CodeZip build),
# which does not use this file. It documents the runtime contract.
#
# AgentCore Runtime requires ARM64 and expects the A2A server on port 9000 at "/".
# serve_a2a() in bridge.py serves the agent card at
# /.well-known/agent-card.json and the /ping health endpoint (AgentCore Runtime
# performs the health checks, so no Dockerfile HEALTHCHECK is needed).
#
# Sandbox only.
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /bridge
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bridge.py .

# Run as an unprivileged user (CKV_DOCKER_3). Port 9000 needs no root.
RUN useradd --system --uid 10001 --no-create-home bridge
USER bridge

EXPOSE 9000
CMD ["python", "bridge.py"]
