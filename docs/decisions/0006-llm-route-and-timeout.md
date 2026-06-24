# 0006: LLM data-plane route and the cold-load timeout

Status: accepted

## Context

The default config ships the LLM `/v1` route inactive, because a fresh install must not reference
an environment variable that is unset (agentgateway refuses to start otherwise). Operators activate
it to point at an OpenAI-compatible upstream. We had to determine the exact route shape and handle
a real constraint with slow models on a CPU-only box.

## Decision

- Serve `/v1` with a route-level `ai` backend on the data-plane listener, not the top-level `llm:`
  section (which serves on its own port, not the data-plane domain).
- Point at a custom OpenAI-compatible host with `hostOverride` (a `host:port` string) and add the
  `backendTLS` policy so the upstream call is HTTPS. Cloudron apps listen on `:443`, so without
  `backendTLS` agentgateway sends plain HTTP to an HTTPS port and the upstream returns 400.
- Put the upstream credential in a `backendAuth` policy as a `$VAR` reference, set in the app
  environment, never written into the file.
- Accept and document the cold-load timeout: Cloudron's reverse proxy severs a request that exceeds
  its read window (about 60 seconds), and there is no per-app setting to raise it. An internal call
  that bypasses the proxy completes, which confirms the proxy is the limiter, not agentgateway.

## Consequences

- `config/examples/ollama.yaml` carries the proven shape, anonymized.
- A large model on a CPU-only box can time out on its first, cold call until it is warm. The fix is
  to keep the model warm (`OLLAMA_KEEP_ALIVE` on the upstream) and to use streaming clients. This is
  an upstream-and-proxy property, not a fault in this package, and it is documented in the README
  and DEBUGGING.md.
- The `/v1` route serves chat completions, not the model-list endpoint, so a client's automatic
  model fetch (`GET /v1/models`) does not work; clients add the model by hand. Also documented.
