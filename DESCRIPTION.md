agentgateway is an open source proxy for AI traffic. It sits in front of your model providers
and tool servers and gives agents a single, governed entry point.

This package runs agentgateway on Cloudron with a clean, secure topology:

- The admin interface and UI run on the app's primary domain, behind Cloudron login, so only
  your Cloudron users can configure the gateway.
- The data plane (the Model Context Protocol endpoint and the OpenAI-compatible LLM endpoint)
  runs on a separate subdomain that programmatic clients reach directly, protected by an API
  key that is generated for you on first install.

Use it to:

- Expose MCP tool servers (stdio, SSE, streamable HTTP, or remote) to your agents through one
  endpoint, with authentication and access policies.
- Put an OpenAI-compatible front door in front of one or more LLM providers, with key
  management, failover, and cost visibility.

agentgateway is an Apache-2.0 licensed Linux Foundation project. This package tracks its stable
releases and keeps the upstream binary unmodified.

Issues and questions about this package go to its public issue tracker.
