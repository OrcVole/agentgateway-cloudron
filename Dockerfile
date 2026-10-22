# agentgateway packaged for Cloudron.
#
# The single source of truth for the upstream version is the AGENTGATEWAY_VERSION build
# argument below. The Cloudron manifest mirrors it in `upstreamVersion`; nothing else
# hardcodes it. See UPGRADING.md before changing it (two release gates apply).
#
# The official agentgateway image is distroless (Chainguard glibc-dynamic). We copy only the
# single binary from it (the admin UI is embedded in that binary) onto cloudron/base. The
# binary requires at most GLIBC_2.39, which cloudron/base:6.0.1 (glibc 2.43) provides with room to
# spare; every version bump must still re-run the linkage gate in UPGRADING.md.

ARG AGENTGATEWAY_VERSION=v1.6.0

# --- Stage 1: the official upstream image, used only as a source for the binary ----------
# Pinned by DIGEST, not by the tag alone: a tag is mutable and a reproducible build is the
# point (field guide). The tag is kept alongside for readability; both move together.
# Digest resolved 2026-10-16 for v1.6.0.
FROM ghcr.io/agentgateway/agentgateway:v1.6.0@sha256:9d3e6044ddcdc0878b1787f77bd401252b95e22684203fb5e874c4c42d2ed90c AS upstream

# --- Stage 1b: Node, for stdio MCP servers launched with npx -----------------------------
# cloudron/base 6 ships no Node (base 5 carried it). The package brings its own, from the
# official image, at a versioned path of its own so a base bump cannot move it (field guide #291).
FROM docker.io/library/node:24.22.1-bookworm-slim@sha256:2dd9a4f758e173b65fee15388f7706af6fb01ef50cf7a2c0538711d67a6981ae AS node

# --- Stage 2: the Cloudron app image -----------------------------------------------------
# Pinned by digest per the Cloudron packaging skill (the final stage must be this exact base
# so the file manager, web terminal, and log viewer work). Tag 6.0.1 = this digest.
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

# cloudron/base:6.0.1 provides gosu, curl, tini and ca-certificates, but no Node.js. We add Node
# (copied from the pinned node image, with npm and npx because the runtime calls them) and two
# pinned, checksum-verified static tools:
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
    uv --version; uvx --version; yq --version; gosu --version

# Node 24.22.1 with npm and npx, at a versioned path, symlinked onto PATH. agentgateway launches
# stdio MCP servers with `npx`, so npm is a RUNTIME dependency, not only a build one.
COPY --from=node /usr/local/bin/node /usr/local/node-24.22.1/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/node-24.22.1/lib/node_modules/npm
RUN set -eux; \
    ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/node-24.22.1/bin/npm; \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/node-24.22.1/bin/npx; \
    ln -s /usr/local/node-24.22.1/bin/node /usr/local/bin/node; \
    ln -s /usr/local/node-24.22.1/bin/npm  /usr/local/bin/npm; \
    ln -s /usr/local/node-24.22.1/bin/npx  /usr/local/bin/npx; \
    ldd /usr/local/node-24.22.1/bin/node; \
    if ldd /usr/local/node-24.22.1/bin/node 2>&1 | grep -q 'not found'; then echo "FATAL: node links a missing library"; exit 1; fi; \
    test "$(/usr/local/node-24.22.1/bin/node --version)" = "v24.22.1"; \
    /usr/local/node-24.22.1/bin/npm --version; \
    /usr/local/node-24.22.1/bin/npx --version; \
    node --version; npm --version; npx --version; \
    echo "BUILD GATE OK: node v24.22.1, npm and npx at the runtime path"

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
