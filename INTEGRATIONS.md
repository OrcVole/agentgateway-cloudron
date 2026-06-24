# INTEGRATIONS.md

How this agentgateway package connects to the other software you are likely to run on the
same Cloudron, and how to avoid the problems that come from Cloudron's app isolation model.

Read AGENTS.md first for the package rules. This file is about wiring agentgateway to its
neighbours. It is both design intent (the package lays groundwork for these) and an
operator guide (recipes, issues, and solutions).

---

## 1. Mental model: agentgateway is the hub

Everything is one of two things relative to the gateway.

- **Upstream backends**: things the gateway routes traffic *to*. These are LLM servers,
  MCP and tool servers, and HTTP or REST services. The gateway holds their credentials and
  exposes them through one governed surface.
- **Downstream clients**: things that consume the gateway. These point at the gateway's
  data-plane endpoint instead of talking to providers directly, so they inherit failover,
  cost tracking, auth, and a unified tool catalogue.

Some apps are both.

| App        | Role relative to gateway      | Mechanism                                              | Transport |
|------------|-------------------------------|-------------------------------------------------------|-----------|
| Ollama     | Upstream LLM backend          | OpenAI-compatible provider (`baseUrl` + `apiKey`)     | HTTP /v1  |
| LM Studio / LAN host | Upstream LLM backend | OpenAI-compatible provider                          | HTTP /v1  |
| OpenWebUI  | Downstream client             | Point its OpenAI endpoint at the gateway data plane   | HTTP /v1  |
| LibreChat  | Downstream client             | Custom OpenAI-compatible endpoint in `librechat.yaml` | HTTP /v1  |
| n8n        | Both                          | Client via AI/HTTP nodes; backend via webhook or MCP  | HTTP, MCP |
| Qdrant     | Upstream tool (MCP)           | `mcp-server-qdrant` as a stdio MCP backend (uvx)      | MCP/stdio |
| Baserow    | Upstream tool (MCP)           | OpenAPI-to-MCP from Baserow's REST API                | MCP/HTTP  |
| RustFS     | Upstream tool (MCP) or backend| S3 MCP server, or HTTP backend                        | MCP/HTTP  |

---

## 2. The Cloudron networking model (read this before anything breaks)

This is the single most common source of integration failure on Cloudron, so it comes
first.

**Cloudron apps are isolated containers.** Inside one app, `localhost` is that app, not
another app. The Ollama example in upstream docs uses `localhost:11434`; on Cloudron that
will not reach the separate Ollama app. This is exactly the trap that catches people: the
upstream tutorials assume one host, Cloudron gives you many.

**Use public domains for app-to-app traffic.** The robust, supported way for one Cloudron
app to reach another is the other app's public HTTPS domain, for example
`https://ollama.example.com` or `https://qdrant.example.com`. The traffic goes out to the
reverse proxy and back, which adds a small hop, but it is stable across restarts, it is TLS
terminated, and it does not depend on container internals.

**Do not rely on internal container IPs.** You can find another app's Docker bridge IP from
a shell, but it changes across restarts and updates. Configurations built on it break
silently later. Treat it as a last resort for debugging only, never as a deployment.

**Each backend keeps its own credentials.** Ollama has an API key, Qdrant has an API key,
Baserow has an API token, RustFS has access keys, cloud LLM providers have their own keys.
agentgateway centralises these as backend credentials. Store them as environment variables
and reference them in config with `$VAR` (see section 3), so the secret is never written
into the config file the UI rewrites.

**Reaching machines outside Cloudron.** An LLM server on your own LAN or VPN (LM Studio, Ollama,
and similar) is not on the Cloudron box. The Cloudron host must be able to reach it over the
network: a LAN address, a VPN such as Tailscale, or a tunnel. Bind that inference server to
`0.0.0.0` and firewall it to the gateway host only.

---

## 3. Groundwork this package provides

So that the integrations above are easy rather than a fight, the package does the following.
If you are building or reviewing the package, keep these in place.

1. **Bundles `npx` (Node.js) and `uvx` (uv).** This is what lets stdio MCP servers run
   inside the gateway container, including `mcp-server-qdrant` and many others. Without
   these, only HTTP, SSE, and remote MCP backends work.
2. **Ships example configs** in `config/examples/` in the repository, so an operator can copy
   working snippets rather than starting blank.
3. **Uses an environment-variable convention for secrets.** Backend credentials live in the
   Cloudron app environment (set in the dashboard), and the config references them as `$VAR`.
   This matters specifically because the admin UI overwrites `config.yaml` on save: a `$VAR`
   reference survives the rewrite, a pasted secret might be exposed or lost.
4. **Sets a sensible default CORS policy** on data-plane routes so browser-based clients
   (OpenWebUI, the MCP Inspector, web frontends) can call the gateway. MCP needs the
   `mcp-protocol-version` header allowed and `Mcp-Session-Id` exposed.
5. **Surfaces the data-plane URL** in `postInstallMessage`, so integrators know exactly
   where to point clients.
6. **Recommends a dedicated data-plane subdomain** (see docs/decisions/0002), so clients get
   a clean `https://<data-plane>/v1` and `/mcp` rather than a bare host and port.

---

## 4. Upstream LLM backends

### Ollama (Cloudron app)

Ollama exposes an OpenAI-compatible API. Point the gateway at the Ollama app's public
domain and pass its API key. See `config/examples/ollama.yaml`.

```yaml
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
llm:
  models:
    - name: "*"
      provider: openAI
      params:
        baseUrl: "https://ollama.example.com"   # the Ollama Cloudron app domain, not localhost
        apiKey: "$OLLAMA_API_KEY"               # from the Ollama app data dir
```

- **Issue:** requests go to api.openai.com and return 429 or 401. **Cause:** `baseUrl` not
  applied. **Fix:** confirm the gateway started with this config file and that the logs show
  the endpoint as your Ollama domain, not api.openai.com.
- **Issue:** model not found. **Cause:** the model in the request was not pulled in Ollama.
  **Fix:** pull it in the Ollama app first; the request model name must match.
- **Note:** a CPU-only Cloudron Ollama app is best kept to small models. Use a more capable host
  on your own network for heavy inference.

### LM Studio or Ollama on a LAN or VPN host

Same provider type, different host. The `baseUrl` is the host address reachable from the Cloudron
host (LAN or VPN). See `config/examples/hub.yaml` for an LLM and MCP behind one gateway.

- **Issue:** connection refused. **Cause:** the inference server binds to localhost on that host,
  or the gateway host cannot reach it. **Fix:** bind LM Studio or Ollama to `0.0.0.0`, open the
  port to the gateway host only, and verify reachability with curl from the Cloudron host.

### Putting them together (virtual models and failover, v1.3)

With v1.3 you can define a virtual model that prefers a local host and fails over to a cloud
provider. The client sends one model name and the gateway chooses the backend. This is the clean
way to express local-first, cloud-on-demand routing as policy.

---

## 5. Downstream clients

### OpenWebUI

Point OpenWebUI's OpenAI connection at the gateway data plane.

- Base URL: `https://<data-plane>/v1` (the data-plane subdomain, or `http://host:<tcpPort>/v1`
  if you used the tcpPort fallback).
- API key: a gateway virtual key, not a provider key.
- Result: OpenWebUI sees every model the gateway exposes, with failover and cost tracking.

**Issue:** OpenWebUI also has a native Ollama connector. Do not point it at Ollama directly
if you want governance; route through the gateway instead.

### LibreChat

Add the gateway as a custom OpenAI-compatible endpoint in `librechat.yaml`.

- **Known issue:** LibreChat has historically had a quirk where an endpoint literally named
  `ollama` triggers legacy header handling and returns 401 against gateways and proxies.
  **Fix:** name the custom endpoint something other than `ollama` (for example
  `agentgateway`), and set the API key explicitly.
- Base URL: `https://<data-plane>/v1`. API key: a gateway virtual key.

### n8n (client side)

n8n's AI and HTTP Request nodes can call the gateway.

- In an OpenAI-style node, set the base URL to `https://<data-plane>/v1` and the key to a
  gateway virtual key.
- **Known issue:** n8n trying to reach another app on `localhost` or `127.0.0.1` fails,
  because that is n8n's own container. **Fix:** use the gateway's public data-plane domain.

---

## 6. Tool backends (MCP)

### Qdrant (vector search as an MCP tool)

Run the official `mcp-server-qdrant` as a stdio MCP backend inside the gateway, pointed at
your Qdrant Cloudron app. This needs `uvx`, which the package bundles. See
`config/examples/qdrant-mcp.yaml`.

```yaml
backends:
  - mcp:
      targets:
        - name: qdrant
          stdio:
            cmd: uvx
            args: ["mcp-server-qdrant"]
            env:
              QDRANT_URL: "https://qdrant.example.com"
              QDRANT_API_KEY: "$QDRANT_API_KEY"
              COLLECTION_NAME: "knowledge"
```

- **Verify:** confirm the current environment variable names and the package name against
  the mcp-server-qdrant README before relying on this; that project's options evolve.
- **Issue:** the backend never starts. **Cause:** `uvx` missing, or no network egress to
  the Qdrant domain. **Fix:** confirm `uvx` is on PATH in the container and that the Qdrant
  domain is reachable.

### Baserow (database rows as MCP tools)

Baserow exposes a REST API with per-database OpenAPI documentation. Use agentgateway's
OpenAPI-to-MCP capability to turn it into tools with no custom code, authenticated with a
Baserow API token. See `config/examples/baserow-openapi-mcp.yaml`, which is a template:
confirm the exact OpenAPI-to-MCP schema fields against the agentgateway docs, because this
part of the schema is the least stable.

- **Issue:** too many tools generated. **Cause:** a large OpenAPI surface becomes a large,
  noisy tool catalogue. **Fix:** scope the spec or filter operations so agents see only the
  endpoints you intend.

### RustFS (object storage)

RustFS is S3-compatible. Two options: expose it as MCP tools via an S3 MCP server (run with
`uvx` or `npx`), or route plain HTTP to it as a backend. Prefer the MCP route if you want
agents to list, get, and put objects as governed tools.

- **Caveat:** RustFS is young. Pin its version, test the S3 surface you actually use, and do
  not assume full S3 API parity. Keep the access keys in the environment, referenced as
  `$VAR`.

---

## 7. Cross-cutting issues and solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| App cannot reach another app on `localhost` | Cloudron app isolation | Use the other app's public HTTPS domain |
| Config built on a container IP breaks after restart | Internal IPs are not stable | Use public domains; never hardcode container IPs |
| Secret disappears or leaks after a UI save | The admin UI rewrites `config.yaml` | Keep secrets in env vars; reference them as `$VAR` |
| Browser client blocked by CORS | Data-plane route lacks CORS for the client | Allow the client origin and the MCP headers; expose `Mcp-Session-Id` |
| LLM streaming or MCP SSE stalls | Proxy buffering or short timeouts | Confirm the Cloudron proxy passes SSE and long-lived connections; raise client stream timeouts for large local models |
| stdio MCP backend will not launch | `npx` or `uvx` missing | Ensure both are bundled and on PATH for the cloudron user |
| Data-plane endpoint is ugly or has no TLS | Exposed on a tcpPort | Prefer a dedicated HTTPS data-plane subdomain (docs/decisions/0002) |
| Workstation model unreachable | Bound to localhost or firewalled | Bind to `0.0.0.0`, firewall to the gateway host, verify with curl |

---

## 8. Testing an integration

For any backend you add, work up this ladder:

1. **Reachability:** from the Cloudron host or the gateway container, curl the backend's
   public domain and confirm a response.
2. **Through the gateway:** call the gateway data-plane endpoint and confirm the request
   reaches the backend (check the gateway logs for the resolved endpoint).
3. **From a real client:** point OpenWebUI, LibreChat, the MCP Inspector, or n8n at the
   gateway and exercise it end to end.
4. **Governance:** confirm the call shows up in the gateway logs and, for LLM traffic on
   v1.3, that token and cost are attributed.

Record any new failure and its fix in DEBUGGING.md so the next person does not rediscover
it.
