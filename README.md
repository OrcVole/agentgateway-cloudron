# agentgateway for Cloudron

This repository packages [agentgateway](https://github.com/agentgateway/agentgateway) (an
Apache-2.0 Linux Foundation project) as a Cloudron application. agentgateway is a proxy for AI
traffic: it sits in front of your model providers and Model Context Protocol (MCP) tool servers
and gives agents one governed entry point, with authentication, access policies, failover, and
cost and token visibility.

The package keeps the upstream binary unmodified. It adds only a Cloudron-conformant runtime: a
multi-stage Dockerfile, an entrypoint that seeds and guards the config, a manifest, and a sane
default configuration.

## Topology

agentgateway has two surfaces with two different security models. This package puts them on two
domains:

| Surface | Domain (example) | Behind Cloudron login | Authentication |
|---|---|---|---|
| Admin interface and UI | `agentgateway.example.com` (primary) | Yes (the `proxyAuth` addon) | Cloudron single sign-on |
| Data plane (MCP and LLM) | `gw-api.example.com` (a secondary domain) | No | agentgateway API key |

The admin UI has no authentication of its own, so it sits on the primary domain behind Cloudron
login, where only your Cloudron users can reach it. The data plane carries programmatic agent and
LLM traffic that cannot complete an interactive sign-in, so it sits on its own domain, open at the
network level and protected by an API key. This is the same pattern Cloudron's own MinIO package
uses (console behind login, S3 API on a separate open domain), so it is supported and idiomatic.

You choose both domains at install time. The data-plane domain is suggested as `gw-api` and you can
change it under the app's Location settings. Cloudron terminates TLS (Let's Encrypt) for both.

## Client URLs

After install, with `<admin>` and `<data>` being the two domains you chose:

- Admin UI: `https://<admin>/` (sign in with Cloudron)
- MCP endpoint: `https://<data>/mcp`
- LLM endpoint (OpenAI-compatible): `https://<data>/v1/chat/completions`

Programmatic clients send the API key as a bearer token:

```
curl https://<data>/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Hello"}]}'
```

A request with no key, or the wrong key, returns `401`.

## The API key

An API key is generated on first start. The simplest way to see it is in the admin UI: open the
data-plane listener and read its API key policy. It is also stored on disk, so from a terminal you
can run `cloudron exec` for this app and `cat /app/data/.api_key`. Rotate it, or add more keys, in
the admin UI or by editing `/app/data/config.yaml`.

## What ships by default

The default config is deliberately self-sufficient so a fresh install boots cleanly:

- The admin UI, bound so Cloudron can reach it.
- One data-plane listener, with a single API key required on every route.
- A removable MCP demo: the reference "everything" server at `/mcp`, so the gateway works the
  moment it is installed.
- The LLM route is documented but inactive (see below).

## Adding MCP backends

Edit the config in the admin UI, or edit `/app/data/config.yaml` and restart. The image bundles
`uv` (for `uvx`) and Node (for `npx`), so stdio MCP servers work out of the box, alongside SSE,
streamable HTTP, and remote MCP backends. For example, to expose a Python MCP server:

```yaml
backends:
  - mcp:
      targets:
        - name: my-tools
          stdio:
            cmd: uvx
            args: ["some-mcp-server"]
```

The first call to a freshly added stdio server is slow while `npx` or `uvx` fetches it into the
cache under `/app/data`; later calls are fast.

## Adding an LLM endpoint

The OpenAI-compatible `/v1` endpoint is off by default, because agentgateway refuses to start if
the config references an environment variable that is not set (and a provider key would be unset on
a fresh install). To enable it, add a `/v1` route with an `ai` backend. To point it at a custom
OpenAI-compatible server (rather than OpenAI itself), set `hostOverride` (a `host:port` string) and
add `backendTLS` so the upstream call uses HTTPS:

```yaml
- name: llm
  matches:
    - path:
        pathPrefix: /v1
  policies:
    backendAuth:
      key: "$PROVIDER_API_KEY"   # set this in the app's Environment first
    backendTLS: {}               # upstream is HTTPS
  backends:
    - ai:
        name: my-provider
        provider:
          openAI:
            model: "your-model"
        hostOverride: "llm.example.com:443"
```

The model in `provider.openAI.model` is the model agentgateway sends upstream; it overrides the
model in the client request. Keys are referenced as `$VAR` and set in the app's Environment, so
they survive admin-UI saves and never live in the file. See `config/examples/` for complete
recipes.

The admin panel shows "LLM config is not initialized" until agentgateway's top-level `llm:` model
registry is set. That message is harmless and concerns the admin LLM dashboard only, not the
data-plane `/v1` route, which serves chat on its own. The route and the dashboard registry are
independent (the registry adds no extra listener); populating the dashboard is optional. See
`config/examples/llm-dashboard.yaml` for the top-level `llm:` registry and `config.modelCatalog`
(pricing for the cost view; cost reads zero for local models that have no pricing).

## Testing

- MCP: connect an MCP client (for example `npx @modelcontextprotocol/inspector`) to
  `https://<data>/mcp` with the bearer key, list tools, and call one.
- LLM: `POST https://<data>/v1/chat/completions` with the bearer key (see the curl above). On the
  v1.3 line, token counts appear in the UI; dollar cost appears for providers that have pricing.

## Connecting a chat UI (OpenWebUI and similar)

A human-facing chat UI such as OpenWebUI is a client of the data plane, which is the intended
pattern: the UI sits behind Cloudron login, and it makes outbound calls to the open, API-key
protected data plane. There is no sign-on collision, because the UI is the caller, not a target.

In the UI's settings, add an OpenAI-compatible connection:

- Base URL: `https://<data-plane>/v1`
- API key: the data-plane API key

One caveat: the data-plane `/v1` route serves chat completions, not the model-list endpoint, so
`GET /v1/models` returns an error and the UI's automatic model dropdown will not populate. Add the
model name by hand and turn off the model-list fetch for that connection. Chat itself works
normally, and streaming is recommended (it also avoids the cold-load timeout described under
Updating and in DEBUGGING.md).

## Backup and restore

All persistent state lives in `/app/data` (the config and the API key), which Cloudron backs up
through the `localstorage` addon. There is no database. Restoring the app restores the config and
key as they were.

## Updating

`cloudron update` rebuilds and updates the app. The upstream version is pinned in one place (the
`AGENTGATEWAY_VERSION` build argument), and updates are low risk because the only state is the YAML
config. See UPGRADING.md for the two release gates (binary-to-base linkage, and config migration)
that run on every version bump.

## Security

- The admin UI is protected by the Cloudron `proxyAuth` addon. It cannot be added after install, so
  it is declared from the start.
- The data plane is protected by an API key, generated on first run. Enabling OAuth 2.x and JWT
  RBAC for MCP are documented next steps.
- stdio MCP backends launch local commands inside the container. A configured backend can run
  programs, so add only servers you trust. This is the trade-off for out-of-the-box `uvx` and `npx`
  support.

## Install

This package is published as a public image on GitHub Container Registry,
`ghcr.io/orcvole/agentgateway-cloudron`, and as a Cloudron community versions file. To install it,
point the Cloudron CLI at the versions URL and choose your two domains:

```
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/agentgateway-cloudron/main/CloudronVersions.json \
  --location agentgateway.example.com \
  --secondary-domains DATA_PLANE_DOMAIN=gw-api.example.com
```

The image is pinned by digest in `CloudronVersions.json`, so every install pulls the exact build
that was published. The primary `--location` is the admin UI; the `DATA_PLANE_DOMAIN` secondary
domain (suggested `gw-api`) is the data plane.

## Build from source

To build the image yourself instead of pulling the published one, clone this repository and run the
Cloudron build flow (it builds on the server, so no local Docker is needed), then install the
result:

```
cloudron build
cloudron install --location agentgateway.example.com \
  --secondary-domains DATA_PLANE_DOMAIN=gw-api.example.com
```

See CONTRIBUTING.md for the development workflow, AGENTS.md for the packaging contract, and
DEBUGGING.md for the runbook.
