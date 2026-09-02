[1.0.2]

- Update agentgateway 1.4.1 -> 1.5.0
- Security: Go runtime updated to 1.26.5 to fix a CVE, JWT issuer and audience claims are now enforced, cross-namespace route delegation requires an explicit ReferenceGrant, sensitive request headers are redacted from trace and debug output, client-supplied moderation and routing headers are no longer trusted, JWKS targets are restricted, and Helm RBAC roles are scoped to the namespace
- LLM token counts now include prompt-cache tokens; set AGENTGATEWAY_LEGACY_LLM_USAGE_TOKEN_SEMANTICS=true to restore previous behaviour
- Backend and attached LLM policies now merge field by field instead of the backend policy fully replacing the attached policy; managed API key metadata now uses the agentgateway.dev/ prefix
- Legacy Istio identity TLV support has been removed; native mTLS must be used for workload identity in sandwich topologies
- Packaging: pin moved in Dockerfile ARG and the upstream FROM digest; no manifest, addon or start.sh change

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
