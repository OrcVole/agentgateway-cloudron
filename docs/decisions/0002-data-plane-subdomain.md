# 0002: Expose the data plane on a dedicated HTTPS subdomain

Status: accepted (Cloudron multi-HTTP confirmed, 2026-06-24)

## Context

agentgateway has two surfaces: the admin UI (no native auth, must be protected) and the
data plane (the MCP and LLM endpoints, secured by agentgateway's own auth). Decision 0001
covered protecting the admin UI behind the Cloudron proxyAuth addon.

This package is intended to be an integration hub for other Cloudron apps: OpenWebUI,
LibreChat, and n8n consume the data plane, and external agents may too. Those clients need
a clean, stable, TLS-terminated endpoint such as `https://<host>/v1` and `https://<host>/mcp`.

The fallback of exposing the data plane on a Cloudron `tcpPort` works, but it gives clients
a bare host and port with no domain TLS, which is awkward to configure and to secure, and
it does not present well for an endpoint that other apps and external agents consume.

## Decision

Expose the data plane on its own HTTPS subdomain (for example `gw-api.example.com`) through a
manifest `httpPorts` entry, with no `proxyAuth`, secured by agentgateway's own auth (API key by
default, with JWT and OAuth 2.x available). Keep the admin UI on the primary domain behind
`proxyAuth`, per decision 0001.

Cloudron multi-HTTP is confirmed: a single app may declare additional `httpPorts`, each of which
gets its own subdomain, and `proxyAuth` scopes to the primary domain only, so an `httpPorts`
subdomain is not behind the single sign-on wall. This is the same pattern Cloudron's own MinIO
package uses (console on the primary domain, S3 API on a `minio-api` subdomain), so it is
idiomatic and supported.

Fallback: if a future Cloudron release changed this behaviour so `proxyAuth` did gate the
subdomain, expose the data plane on a `tcpPort` instead and document the resulting
`http://<host>:<port>/v1` and `/mcp` URLs. The first install verifies the subdomain is open with
a two-curl test (see DEBUGGING.md).

## Consequences

- Clients get a clean `https://<data-plane>/v1` and `/mcp`, which is what every integration
  recipe in INTEGRATIONS.md assumes.
- proxyAuth is never placed in front of the data plane, so programmatic clients are
  not broken.
- The package must document both the admin URL and the data-plane URL, and surface them in
  `postInstallMessage`.
- If the fallback tcpPort path is used, integration docs must show the host-and-port form
  instead, and operators lose domain TLS on the data plane unless agentgateway terminates
  TLS itself.
