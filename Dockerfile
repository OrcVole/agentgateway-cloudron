# agentgateway packaged for Cloudron.
#
# The single source of truth for the upstream version is the AGENTGATEWAY_VERSION build
# argument below. The Cloudron manifest mirrors it in `upstreamVersion`; nothing else
# hardcodes it. See UPGRADING.md before changing it (two release gates apply).
#
# The official agentgateway image is distroless (Chainguard glibc-dynamic). We copy only the
# single binary from it (the admin UI is embedded in that binary) onto cloudron/base. The
# binary requires at most GLIBC_2.39, which cloudron/base:5.0.0 (glibc 2.39) provides; this
# is a tight match, so every version bump must re-run the linkage gate in UPGRADING.md.

ARG AGENTGATEWAY_VERSION=v1.3.1

# --- Stage 1: the official upstream image, used only as a source for the binary ----------
# Pinned by tag (AGENTGATEWAY_VERSION). Digest at packaging time:
#   ghcr.io/agentgateway/agentgateway@sha256:2e25455a0185f3c5a0e0f5e0f36ccc860c754d4d26632bfa5cc41c2f5bd35141
FROM ghcr.io/agentgateway/agentgateway:${AGENTGATEWAY_VERSION} AS upstream

# --- Stage 2: the Cloudron app image -----------------------------------------------------
# Pinned by digest per the Cloudron packaging skill (the final stage must be this exact base
# so the file manager, web terminal, and log viewer work). Tag 5.0.0 = this digest.
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# cloudron/base:5.0.0 already provides gosu, Node.js 22, curl, tini, and ca-certificates.
# We add only two pinned, checksum-verified static tools:
#   - uv  : runs uvx-based (Python) MCP servers out of the box.
#   - yq  : lets start.sh re-assert config.adminAddr on every boot (the UI can rewrite the
#           config file, and the genuine admin default binds localhost only).
ARG UV_VERSION=0.11.8
ARG UV_SHA256=56dd1b66701ecb62fe896abb919444e4b83c5e8645cca953e6ddd496ff8a0feb
ARG YQ_VERSION=v4.53.3
ARG YQ_SHA256=fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4

RUN set -eux; \
    # uv + uvx
    curl -fsSL -o /tmp/uv.tar.gz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/uv.tar.gz -C /tmp; \
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv  /usr/local/bin/uv; \
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx; \
    # yq
    curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"; \
    echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/yq; \
    rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu; \
    # sanity: every runtime tool must resolve in the final image
    uv --version; uvx --version; yq --version; gosu --version; node --version

# The agentgateway binary (UI embedded). /app/code is read-only at runtime.
COPY --from=upstream /app/agentgateway /app/code/agentgateway

# Package entrypoint and the default config that start.sh seeds into /app/data on first run.
COPY start.sh /app/code/start.sh
COPY config/config.yaml /app/code/config.yaml
RUN chmod 0755 /app/code/agentgateway /app/code/start.sh

# Record the pinned upstream version in the image for debuggability and log output.
ARG AGENTGATEWAY_VERSION
ENV AGENTGATEWAY_VERSION=${AGENTGATEWAY_VERSION}

LABEL org.opencontainers.image.title="agentgateway-cloudron" \
      org.opencontainers.image.description="agentgateway (MCP and LLM proxy) packaged for Cloudron" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR /app/code

# start.sh runs as root, prepares /app/data, then drops to the cloudron user via gosu.
CMD [ "/app/code/start.sh" ]
