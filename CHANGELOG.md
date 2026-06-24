# Changelog

All notable changes to this Cloudron package are recorded here. The package version is our own
semver and is independent of the upstream agentgateway version.

[1.0.0]

- Initial release. Packages agentgateway v1.3.1 on cloudron/base:5.0.0.
- Admin UI on the primary domain, behind the Cloudron proxyAuth addon.
- Data plane (MCP and the OpenAI-compatible LLM endpoint) on a dedicated httpPorts subdomain,
  secured by an API key generated on first install.
- Bundles uv for uvx-based MCP servers; Node is provided by the base image.
- Ships a removable MCP "everything" demo server at `/mcp` so the gateway works immediately.
