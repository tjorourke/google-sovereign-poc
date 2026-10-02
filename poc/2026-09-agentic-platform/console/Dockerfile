FROM python:3.12-slim
ARG KUBECTL_VERSION=v1.36.0
ARG ARCTL_VERSION=v2026.6.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git gh \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" -o /tmp/kubectl.sha256 \
    && printf '%s  /usr/local/bin/kubectl\n' "$(cat /tmp/kubectl.sha256)" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl
RUN curl -fsSL "https://storage.googleapis.com/agentregistry-enterprise/${ARCTL_VERSION}/arctl-linux-amd64" -o /usr/local/bin/arctl \
    && curl -fsSL "https://storage.googleapis.com/agentregistry-enterprise/${ARCTL_VERSION}/arctl-linux-amd64.sha256" -o /tmp/arctl.sha256 \
    && printf '%s  /usr/local/bin/arctl\n' "$(cut -d' ' -f1 /tmp/arctl.sha256)" | sha256sum -c - \
    && chmod +x /usr/local/bin/arctl
RUN useradd --uid 10001 --create-home console
COPY app /app
COPY google-sov /opt/google-sov
ENV GOOGLE_ONLY=1 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 HOME=/home/console \
    ARCTL=/usr/local/bin/arctl GCD_LAB_ROOT=/opt/google-sov/poc/2026-09-agentic-platform \
    CONSOLE_STATE_DIR=/data CONSOLE_AUTH_FILE=/etc/console-auth/access.json \
    GCD_KUBECONFIG=/etc/berlin/kubeconfig DASHBOARD_PORT=8900 CONSOLE_BUILD_MODE=snapshot
USER 10001
WORKDIR /app
EXPOSE 8900
CMD ["python3", "serve.py"]
