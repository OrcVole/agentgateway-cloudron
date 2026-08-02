# Changelog

All notable changes to this Cloudron package are recorded here. The package version is our own
semver and is independent of the upstream agentgateway version.

[1.0.1]

- Upstream agentgateway v1.3.1 to v1.4.1. Adds upstream's new OAuth support for backend and MCP
  traffic (token exchange, cross-app access, client authentication), and changes to the OIDC and
  MCP session handling. This is the gateway authenticating outbound and MCP traffic; the Cloudron
  single sign-on wall on the admin UI is unchanged.
- Pin the upstream image by digest rather than by tag alone, so the build is reproducible.
- Note: upstream's `virtualkeys-to-configmap` migration command ships in their Kubernetes
  controller, which this package does not include. It does not apply to a Cloudron install.

[1.0.0]

- Initial release. Packages agentgateway v1.3.1 on cloudron/base:5.0.0.
- Admin UI on the primary domain, behind the Cloudron proxyAuth addon.
- Data plane (MCP and the OpenAI-compatible LLM endpoint) on a dedicated httpPorts subdomain,
  secured by an API key generated on first install.
- Bundles uv for uvx-based MCP servers; Node is provided by the base image.
- Ships a removable MCP "everything" demo server at `/mcp` so the gateway works immediately.
