# agentgateway is installed

## Admin UI

Open $CLOUDRON-APP-ORIGIN and sign in with your Cloudron account. The admin UI is on the primary
domain and is protected by Cloudron login, so only your Cloudron users can reach it.

## Data plane (MCP and LLM)

The programmatic endpoint is on the separate domain you assigned to the "Data plane" port during
install (the suggested name was `gw-api`). You can see or change it under this app's Location
settings. It is intentionally not behind Cloudron login, because automated agents and LLM clients
cannot complete an interactive sign-in. It is protected by an API key instead.

A demo MCP server (the reference "everything" server) is already wired up at `/mcp`, so you can
test right away.

## Your API key

A data-plane API key was generated on first start. The simplest way to see it is in the admin UI
(above): open the data-plane listener and look at its API key policy. The same value is also
written to the app's storage, so from a terminal you can run `cloudron exec` for this app and
`cat /app/data/.api_key` (it is also present in `/app/data/config.yaml`).

Clients send it as a bearer token, for example:

    curl https://<your-data-plane-domain>/mcp -H "Authorization: Bearer <the-key>"

## Next steps

- Add LLM and MCP backends in the admin UI, or by editing `/app/data/config.yaml`.
- To enable the OpenAI-compatible `/v1` endpoint, set the provider key in this app's Environment,
  then add the route (see the README and the `config/examples/` files).
- Rotate or add API keys in the admin UI.

Until you configure an LLM, the admin panel shows "LLM config is not initialized". That is expected
and harmless: the gateway is healthy and MCP works. The OpenAI-compatible `/v1` endpoint is a
data-plane route you add separately (see `config/examples/ollama.yaml`); it works on its own,
independent of that panel message.

The README covers the full topology, the exact client URLs, and the security model. Report issues at the project's public issue tracker.
