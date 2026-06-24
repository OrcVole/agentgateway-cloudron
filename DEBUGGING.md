# DEBUGGING.md

A runbook for diagnosing this package on Cloudron. It is written so that an AI agent with
only the repository and the logs can find and fix a failure. When you fix a new failure,
add it to "Known failures" with the symptom, the cause, and the fix.

---

## State on disk (where to look first)

Everything the package persists lives under `/app/data`:

- `/app/data/config.yaml` is the runtime configuration and the source of truth. The admin
  UI rewrites this file on save.
- `/app/data/.api_key` holds the generated data-plane API key (mode 600), written on first
  run when the default config enables key auth.
- Any TLS material, if the data plane terminates TLS itself, lives under `/app/data`.

If you introduce new persistent state, add it to this list.

The rest of the filesystem is read-only except `/tmp` and `/run`. A write attempt anywhere
else is a bug, not a permissions accident.

---

## Boot sequence (the config ladder)

`start.sh` is deliberately strict, so a bad config fails visibly rather than silently. On
every start it runs this ladder, printing `==>` markers at each step:

1. **Seed if absent.** If `/app/data/config.yaml` does not exist, copy the default from
   `/app/code/config.yaml`, generate the data-plane API key, and write it into the config and
   into `/app/data/.api_key`.
2. **Pin the admin bind.** Re-assert `config.adminAddr = 0.0.0.0:15000` with `yq`, every boot.
   This is load-bearing: the genuine no-config default is localhost only, so if the admin UI
   drops the field on a save, Cloudron could no longer reach the UI and the app would
   crash-loop. Re-asserting makes that impossible.
3. **Validate.** Run `agentgateway --validate-only -f /app/data/config.yaml`.
4. **Migrate only on failure.** If validation fails (typically after an upgrade changed the
   schema), run `agentgateway migrate -f /app/data/config.yaml` and validate again. `migrate`
   rewrites in place and normalises formatting, so it can drop comments; it runs only on
   failure, so steady state is untouched and the loop converges.
5. **Fail loud, or exec.** If validation still fails, log the error and exit non-zero. The app
   never reseeds over a user's config, because that would destroy their work on a
   merely-incompatible file. A visible crash in `cloudron logs` is the correct failure mode:
   the operator restores from the pre-update backup or fixes the file. Only on success does
   `start.sh` drop privileges with `gosu cloudron:cloudron` and exec the binary.

If the app is crash-looping after an update, the last `==>` marker names the rung that failed.
A failure at step 5 means the persisted config is incompatible even after migration: compare
it against `/app/code/config.yaml` and the schema.

---

## Reading the logs

Package-emitted lines are prefixed with `==>`. agentgateway's own lines are not. To see the
package startup sequence:

```bash
cloudron logs -f | grep '==>'
```

A healthy start prints, in order: config seeding (or "config present"), the resolved
version, the admin bind address, the data-plane port(s), api key presence, and the exec
line. If the sequence stops early, the last `==>` marker names the phase that failed.

---

## Verifying a deploy (the smoke-test ladder)

A change is not done until this passes on the target Cloudron.

1. **Health.** The app shows healthy in the Cloudron dashboard. Confirm the configured
   `healthCheckPath` returns 2xx.
2. **Admin UI.** Open the app domain. You should be sent through Cloudron login (OAuth
   proxy), then see the agentgateway admin UI with its listeners and backends.
3. **MCP.** Add the example "everything" server as a backend (it runs via `npx
   @modelcontextprotocol/server-everything`). From a client machine, connect MCP Inspector
   to the data-plane MCP endpoint and list and call a tool:
   ```bash
   npx @modelcontextprotocol/inspector
   # connect to the data-plane URL, path /mcp or /sse
   ```
4. **LLM.** Configure a provider with a key, then call the OpenAI-compatible endpoint:
   ```bash
   curl -s <data-plane-url>/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"<configured-model>","messages":[{"role":"user","content":"Say hello in one sentence."}]}' | jq .
   ```
   On v1.3 you should then see token and dollar cost for that call in the UI.
5. **Persistence.** Change something in the UI, restart the app, and confirm the change
   survived. This proves the `/app/data` wiring.
6. **Update safety.** Run `cloudron update` to a one-version-higher build and confirm config
   and behaviour survive.

---

## Iterating with a debug install

A debug install gives a writable root filesystem and unlimited memory, which is the fastest
way to find what the app tried to write:

```bash
cloudron install --debug --location agentgateway.example.com
cloudron exec
#   inside the container:
find / -mmin -30 -not -path '/proc/*' -not -path '/sys/*'   # files changed recently
ls -la /app/data
cat /app/data/config.yaml
```

Turn debug mode off once fixed: `cloudron configure --no-debug`.

---

## Known failures

Add entries here as you encounter and fix them. Format: Symptom / Cause / Fix.

### Install fails: "Invalid CloudronManifest.json: must NOT have additional properties @ /addons"
- **Symptom:** `cloudron install` rejects the manifest at validation, before any build, pointing at `/addons`.
- **Cause:** an addon key is not in the box's allowed set. The proxy-authentication addon key is
  camelCase **`proxyAuth`**, not `proxyauth`. The Cloudron packaging skill's addon reference lists
  it lowercase, which the box rejects. `localstorage` is lowercase and correct.
- **Fix:** `"addons": { "localstorage": {}, "proxyAuth": {} }`.

### First MCP call is slow or times out, later calls are fast
- **Symptom:** the first request to a stdio MCP backend (for example the everything server via
  `npx`) takes many seconds or times out; subsequent calls are quick.
- **Cause:** `npx`/`uvx` fetches the server package on first launch, and agentgateway starts stdio
  backends lazily, so the download happens on the first request (into the cache under `/app/data`
  that start.sh configures).
- **Fix:** not a fault. Allow a generous client timeout on the first call. The package is cached in
  `/app/data/.npm` (or `/app/data/.uv`) and persists across restarts.

### LLM /v1/models returns an error; a chat UI's model dropdown will not populate
- **Symptom:** `GET https://<data-plane>/v1/models` returns 503 ("failed to parse request: EOF
  while parsing a value"), and a client like OpenWebUI cannot auto-list models.
- **Cause:** the data-plane `ai` route serves chat completions (`POST /v1/chat/completions`), not
  the model-list endpoint. agentgateway tries to parse the empty GET body and fails.
- **Fix:** in the client, add the model name manually and disable the model-list fetch for this
  connection. Chat works normally. The gateway pins the model server-side anyway.

### LLM request cuts off at about 60 seconds on a slow cold model load
- **Symptom:** the first request to a large model on a CPU-only box fails with the client seeing
  "unexpected eof"; agentgateway logs a 60-second request with no HTTP status.
- **Cause:** Cloudron's reverse-proxy read window severs the connection while agentgateway is still
  waiting on the upstream model. agentgateway has no such timeout of its own (its own timeout would
  log a 504), and Cloudron exposes no per-app proxy-timeout setting. An internal call to
  `localhost:<data-plane-port>` (bypassing the proxy) completes fine, which confirms the proxy is
  the limiter.
- **Fix:** keep the model warm so calls finish inside the window (set `OLLAMA_KEEP_ALIVE` on the
  Ollama app, for example `24h` or `-1`), and use streaming clients (streamed tokens keep the
  connection alive for long responses). Streaming does not help the very first cold load.

### App fails to start: "environment variable not found"
- **Symptom:** logs show `error looking key 'X' up: environment variable not found`, or start.sh
  exits with a FATAL message about an unset environment variable.
- **Cause:** agentgateway interpolates environment references (a leading dollar sign plus a NAME)
  from the raw config text, **including inside comments**. A reference to a variable that is not
  set stops startup. The `$schema` modeline does not trigger this, but an uppercase name like
  `$OPENAI_API_KEY` does, even when the line is commented out.
- **Fix:** set the variable in the app environment (the dashboard), or remove the reference from
  `/app/data/config.yaml`. start.sh deliberately fails fast on this rather than running `migrate`,
  because migrate cannot supply the value and would strip your comments.

### App is marked unhealthy on first start
- **Symptom:** Cloudron reports the app unhealthy shortly after install.
- **Likely causes:** `healthCheckPath` does not return 2xx; the admin interface is bound to
  localhost only, so Cloudron cannot reach it; or the binary failed to start (missing shared
  library).
- **Fix:** confirm the health path against a running instance. Confirm `ADMIN_ADDR` (or
  `config.adminAddr`) binds the admin interface to the interface Cloudron proxies, not
  localhost. Check `ldd` on the binary inside the base image and install any missing
  library. Look for the last `==>` marker in the logs.

### Admin UI loads but the data plane is unreachable from clients
- **Symptom:** the UI works on the domain, but agents cannot reach `/mcp` or
  `/v1/chat/completions`.
- **Likely cause:** the data-plane listener is not exposed. With the default topology the
  data plane is on a Cloudron `tcpPort`, not on the domain.
- **Fix:** confirm the `tcpPort` mapping in the manifest and use the assigned host port in
  the client URL. Do not place the OAuth proxy in front of the data plane.

### Config changes are lost on restart or update
- **Symptom:** edits made in the UI disappear after a restart.
- **Likely cause:** the config file is being read from `/app/code` (read-only) or reseeded
  on every start instead of only when absent.
- **Fix:** the runtime config must be `/app/data/config.yaml`, passed with `-f`. First-run
  seeding copies the default only if the file does not already exist.

### stdio MCP backend fails to launch
- **Symptom:** an MCP backend configured with `npx` or `uvx` does not start.
- **Likely cause:** Node.js or `uv` is not present in the image, or the command is not on
  `PATH` for the `cloudron` user.
- **Fix:** confirm `npx` and `uv` are installed in the Dockerfile and resolvable at runtime.
  If you chose not to bundle them, the README must say only HTTP, SSE, and remote MCP
  backends are supported.

### A write fails with a read-only filesystem error
- **Symptom:** a startup error mentions a read-only file system.
- **Likely cause:** the app is writing outside `/tmp`, `/run`, or `/app/data`.
- **Fix:** redirect that path into `/app/data` (persisted) or `/tmp` (ephemeral). Find the
  path with the `find` command above on a debug install.

---

## When you are stuck

- Re-read AGENTS.md sections 5 and 6. Most failures are a conformance or topology mistake.
- Check the upstream docs for the pinned version at https://agentgateway.dev/docs/standalone/
  and the config schema at https://agentgateway.dev/schema/config.
- Reproduce locally first with `docker run` and the same config before blaming Cloudron.
- Record whatever you learn here so the next agent does not start from zero.
