# Synthetic app image for the composed-agents sample. Sandbox only.
FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as an unprivileged user (CKV_DOCKER_3). Port 8080 needs no root.
RUN useradd --system --uid 10001 --no-create-home app
USER app

EXPOSE 8080

# gunicorn in front of Flask; 2 workers is plenty for a demo. The 0.0.0.0 bind
# is on the task's own network interface; only the ALB's security group can
# reach it. Health checks are done by the ALB target group (/health).
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
