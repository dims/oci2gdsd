FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    git-lfs \
    jq \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/oras.tar.gz "https://github.com/oras-project/oras/releases/download/v1.2.2/oras_1.2.2_linux_amd64.tar.gz" \
    && tar -xzf /tmp/oras.tar.gz -C /tmp oras \
    && install -m 0755 /tmp/oras /usr/local/bin/oras \
    && rm -f /tmp/oras /tmp/oras.tar.gz

WORKDIR /workspace
COPY requirements.txt /workspace/requirements.txt
RUN pip3 install --no-cache-dir -r /workspace/requirements.txt

COPY scripts /workspace/scripts
RUN chmod +x /workspace/scripts/*.sh

ENTRYPOINT ["/workspace/scripts/package_and_push.sh"]
