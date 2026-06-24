# 0004: Bundle uv and yq in the image; reuse the base's Node

Status: accepted

## Context

agentgateway runs stdio MCP servers by launching local commands, most commonly `npx ...` (Node)
and `uvx ...` (Python through uv). For these to work without operator setup, the image needs Node
and uv. Separately, start.sh must re-assert `config.adminAddr` on every boot (the genuine default
binds localhost only, and the admin UI can rewrite the config file), which needs a YAML-aware
in-place edit rather than fragile text substitution.

## Decision

- **Node (npx):** provided by `cloudron/base:5.0.0` (Node 22.14.0). We do not install it; it is
  pinned transitively by the base image digest.
- **uv and uvx:** install a pinned, checksum-verified static build from the upstream GitHub
  release.
- **yq:** install a pinned, checksum-verified static binary (mikefarah yq), used by start.sh for
  the adminAddr re-assert and first-run API-key injection.

The only runtimes added beyond the base are uv and yq, both pinned by version and SHA-256.

## Consequences

- Common stdio MCP servers (npx and uvx) work the moment the app is installed.
- A configured stdio backend can run local commands inside the container. This is a trust
  boundary: operators should add only servers they trust. It is documented in the README security
  section.
- npx and uvx need a writable HOME and cache, but the rootfs is read-only, so start.sh points
  HOME and the npm and uv caches at `/app/data` (persistent, so fetched servers survive restarts).
- The image stays close to the base. The version pins live in the Dockerfile build arguments, so a
  bump is a one-line change with a new checksum.
