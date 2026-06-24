# AGENTS.md

This file is the working contract for any AI agent or human who edits this repository.
Read it fully before changing anything. It encodes decisions that are already settled,
so that you do not relitigate them and do not regress conformance.

If you are an AI agent: treat the rules in "Golden rules" as hard constraints. When a
request conflicts with them, stop and surface the conflict rather than working around it.

This repository packages **agentgateway** (https://github.com/agentgateway/agentgateway,
Apache-2.0, a Linux Foundation project) as a **Cloudron-conformant application**. The
goals, in order: (1) it runs cleanly on our own Cloudron, (2) the repository is public so
others can use it, and (3) it is written to a standard where the Cloudron team could adopt
it as an official application.

---

## 1. Golden rules (non-negotiable)

1. **Conformance first.** The Cloudron packaging rules in section 5 override convenience.
   If a change would write outside the allowed paths, run as root, or skip the health
   check, it is wrong.
2. **Pin versions. Never use floating tags.** The upstream version lives in exactly one
   canonical place (the `AGENTGATEWAY_VERSION` build argument). See section 4.
3. **Do not break the topology.** The admin UI and the data plane are two different
   surfaces with two different security models. See section 6. Never place the Cloudron
   OAuth proxy in front of the data plane.
4. **Persisted state lives only in `/app/data`.** The config file is mutable because the
   UI rewrites it. Treat `/app/data/config.yaml` as the source of truth at runtime.
5. **Fail loud, log clearly.** Every script fails fast and prints greppable markers. An
   AI agent debugging this later should be able to find the failure from logs alone. See
   section 7.
6. **Every change updates its documentation.** Code and docs ship together. See section 8.
7. **House style for all prose:** Markdown and open formats only. No em dashes. Use full
   words rather than contractions. No proprietary file formats.
8. **Verify, do not assume.** When an upstream option, image layout, schema field, or
   Cloudron manifest capability might have changed, check the live docs and confirm
   empirically before relying on it. Record what you verified versus assumed.

---

## 2. What this repository is and is not

- It **is** a thin, reproducible packaging layer: a Dockerfile, a start script, a Cloudron
  manifest, a default configuration, and documentation.
- It **is not** a fork of agentgateway. We do not patch the binary. We consume the official
  release artifact and adapt only the runtime environment to Cloudron.
- Upstream owns the application behaviour. We own the packaging, the defaults, the
  topology, and the upgrade path.

---

## 3. Repository layout (expected)

```
.
├── AGENTS.md              # this file: the contract
├── CLAUDE.md             # pointer to AGENTS.md for Claude-based tools
├── CONTRIBUTING.md       # dev workflow and the path to official inclusion
├── DEBUGGING.md          # the runbook: how to diagnose a broken deploy
├── UPGRADING.md          # version policy and the ready upgrade to v1.3.0 stable
├── CHANGELOG.md          # package changelog, version sections
├── LICENSE               # license for the packaging (upstream is Apache-2.0)
├── README.md             # user-facing: install, topology, how to test
├── Dockerfile            # multi-stage; canonical AGENTGATEWAY_VERSION lives here
├── start.sh              # entrypoint: seed config, set env, drop privileges, exec
├── CloudronManifest.json # metadata, ports, addons, healthCheckPath
├── CloudronVersions.json # community publishing channel
├── .dockerignore
├── config/
│   └── config.yaml       # default config, copied to /app/data on first run
├── docs/
│   ├── decisions/        # one short ADR per non-obvious decision (see section 8)
│   └── screenshots/      # UI screenshot(s) for the README and store listing
└── logo.png              # 256x256 brand mark
```

If a file in this list is missing, that is a gap to close, not a license to invent a
different structure.

---

## 4. Pinned versions and the single source of truth

**Canonical upstream version:** the `AGENTGATEWAY_VERSION` build argument in `Dockerfile`.
Nothing else may hardcode the upstream version. The Cloudron manifest mirrors it in
`upstreamVersion`, but the Dockerfile argument is authoritative.

Current pins (confirm at build time, see below):

| Component                | Pin                          | Notes |
|--------------------------|------------------------------|-------|
| agentgateway (upstream)  | `v1.3.1`                     | Current stable, released 2026-06-22 (v1.3.0 went GA 2026-06-18). Verified to run on the base, see below. |
| agentgateway image       | `ghcr.io/agentgateway/agentgateway:v1.3.1` | Mirror: `cr.agentgateway.dev/agentgateway:v1.3.1`. Roughly 88 MB, single binary at `/app/agentgateway`, UI embedded, default user 65532. |
| Cloudron base image      | `cloudron/base:5.0.0`        | Ubuntu 24.04, glibc 2.39. Already bundles gosu 1.17, Node 22.14.0, curl, tini, ca-certificates. |
| Cloudron box (target)    | `9.1.x`                      | Our box is on the 9.1 line. |

The agentgateway v1.3.1 binary requires a maximum symbol version of `GLIBC_2.39`, which the base
(`cloudron/base:5.0.0`, glibc 2.39) provides exactly. This is a tight match, so every version bump
must re-run the linkage check (`ldd` plus `agentgateway -V` on the base image) before shipping. See
UPGRADING.md.

**Before every build, confirm these are still current:**

- Latest agentgateway tag: https://github.com/agentgateway/agentgateway/releases
- Latest Cloudron base image: https://docs.cloudron.io/packaging/ (cheat sheet)

If a newer tag than v1.3.1 is available, do not silently jump to it. Follow the
controlled procedure in UPGRADING.md.

**Why agentgateway is low-risk to upgrade:** the only persistent state is the YAML config
file, so there is no storage-format migration as there would be for a database. Updates are
close to a one-line version bump plus a test pass. The one nuance: the config schema can
evolve across versions, and agentgateway ships a `migrate` subcommand for exactly that.
`start.sh` validates the persisted config on every boot and runs `migrate` only if validation
fails (see the config ladder in DEBUGGING.md), and UPGRADING.md makes the linkage check and a
migration test a release gate. Storage is still migration-free; config is not guaranteed to be.

---

## 5. Cloudron conformance rules

- **Base image:** build `FROM cloudron/base:<pinned>`. Use a multi-stage build: copy the
  single agentgateway binary from the pinned official image (the admin UI is embedded in
  the binary, so it is one file), then assemble on the Cloudron base.
- **Verify linkage:** run `ldd` on the copied binary inside the base image and install any
  missing shared libraries. Confirm the binary starts on the base before going further.
- **Read-only root filesystem.** Only `/tmp`, `/run`, and `/app/data` are writable.
  `/app/data` requires the `localstorage` addon and is the only backed-up location.
- **Code under `/app/code`** (read-only at runtime). **Data under `/app/data`.**
- **Run as the `cloudron` user** via `gosu cloudron:cloudron`. Chown `/app/data` in
  `start.sh` before dropping privileges.
- **Health check:** `healthCheckPath` must return a 2xx code on the primary `httpPort`
  listener (the admin and UI port), because Cloudron polls only that port. Verified: the
  admin listener serves the UI at `/ui` and returns **200 on `/ui/`**, while the bare `/` is
  a 308 redirect, so do not use `/`. The semantic readiness probe `/healthz/ready` lives on a
  separate listener (`:15021`) that Cloudron does not map, so it cannot be the health path.
  Use `healthCheckPath` = `/ui/`. Recorded in DEBUGGING.md.
- **Instant usability:** no setup screen. The app must work with sane defaults right after
  install, with any generated secret surfaced through `postInstallMessage`.

---

## 6. Architecture and topology (the crux)

agentgateway exposes **two surfaces**:

- **Admin interface and UI**, default port `15000`, served at `/ui`. It binds to localhost
  by default and **has no authentication of its own**. Upstream explicitly warns against
  exposing it publicly. Change the bind with the config field **`adminAddr`** (there is no
  `ADMIN_ADDR` environment variable). We bind it to `0.0.0.0:<httpPort>` and re-assert that
  value on every boot, because the UI rewrites `config.yaml` and could otherwise drop it.
- **Data plane**, the proxy listener(s) defined in config (for example port `3000` for MCP
  at `/mcp` and `/sse`, or a port for the LLM endpoint at `/v1/chat/completions`). The
  data plane carries agentgateway's own auth (API key, OAuth 2.1, JWT RBAC).

Cloudron maps one HTTP port to a domain. Therefore the package makes a deliberate choice.

**Verified:** Cloudron box 9.1.x supports more than one HTTP endpoint per app through the
manifest `httpPorts` field, and each entry gets its own subdomain. Cloudron does not place an
authentication proxy in front of apps automatically; that is the opt-in **`proxyAuth` addon**,
which must be declared in the manifest and **cannot be added after first install**.

- **Chosen topology:** admin UI on the primary domain (for example
  `agentgateway.example.com`) protected by the `proxyAuth` addon; the data plane on its own
  `httpPorts` subdomain (for example `gw-api.example.com`) with no `proxyAuth`, secured by
  agentgateway's own auth (API key by default).
- **Open gate:** confirm at first install that `proxyAuth` scopes to the primary domain only
  and does not gate the `httpPorts` subdomain. If it gates the subdomain, fall back to
  exposing the data plane on a Cloudron `tcpPort` (agentgateway terminates its own TLS, and
  clients use `host:port`).

**Never** put `proxyAuth` in front of the data plane. It would break programmatic agent and
LLM clients, which is the entire point of the gateway.

Document the chosen topology and the exact client URLs and ports in README.md.

---

## 7. AI-debuggability requirements (how to write the code)

The point of this section is that a future agent, given only the repository and the logs,
can diagnose a failure without access to the person who built it.

- **`start.sh` begins with `#!/bin/bash` and `set -euo pipefail`.** A failing command must
  stop the script, not limp on.
- **Print phase markers** to stdout so logs are greppable, for example:
  `echo "==> [start] seeding config"`, `echo "==> [start] exec agentgateway ${AGENTGATEWAY_VERSION}"`.
  Prefix every package-emitted line with `==>` so it is distinguishable from
  agentgateway's own logs.
- **Echo the resolved configuration** at startup: the version, the admin bind address, the
  data-plane port(s), and the config file path. Never print secrets; print their presence,
  for example `echo "==> [start] api key: present"`.
- **First-run seeding must be idempotent.** Copy the default config to `/app/data` only if
  it is absent. Re-running `start.sh` must never clobber user data.
- **No hidden state.** All runtime state is files under `/app/data`. If you introduce new
  state, document it in DEBUGGING.md under "State on disk".
- **Deterministic build.** No `latest` tags, no unpinned `apt`/`npm`/`pip` installs that
  could drift. Pin what you reasonably can.
- **Comments explain why, not what.** A future agent can read what the code does. Record
  the reason a non-obvious thing exists, especially Cloudron-specific workarounds.
- **One concern per commit**, with a message that states the symptom fixed or the behaviour
  added. This is what makes `git log` useful to an agent later.
- **Fail with a hint.** When a precondition is missing, the error message should name the
  likely cause and the file to check.

---

## 8. Documentation requirements

- **Every change updates the docs it touches.** A behaviour change updates README.md and,
  if relevant, DEBUGGING.md. A version change updates CHANGELOG.md and UPGRADING.md.
- **Architecture Decision Records.** Each non-obvious decision gets one short file in
  `docs/decisions/NNNN-title.md` with: context, the decision, and the consequence. The
  topology choice (section 6), the choice to bundle `npx` and `uv`, and the health path are
  all ADR-worthy. Keep each ADR under one page.
- **DEBUGGING.md is a living runbook.** When you hit and fix a failure, add the symptom,
  the cause, and the fix. The next agent should find known failures by symptom.
- **Keep the version table in section 4 accurate.** It is the first thing a maintainer
  checks.

---

## 9. Build, install, test, update (canonical commands)

These are the only supported workflows. Keep them working; if you change them, update this
section.

```bash
# Build and push to your registry (run from the repo root, on a machine with Docker)
cloudron build

# Install on the target Cloudron (use --debug for a writable rootfs while iterating)
cloudron install --location agentgateway.example.com
cloudron install --debug --location agentgateway.example.com

# Logs (follow)
cloudron logs -f

# Interactive debugging on a debug install
cloudron exec
#   inside: find / -mmin -30 -not -path '/proc/*'   # what was written recently

# Update after a change (creates a backup first)
cloudron update
```

The full smoke-test ladder lives in DEBUGGING.md under "Verifying a deploy". A change is
not done until that ladder passes.

---

## 10. Security model (summary)

- The **admin UI** is unauthenticated by itself and is protected by the Cloudron `proxyAuth`
  addon (only logged-in Cloudron users reach it). The addon is opt-in and must be in the
  manifest from first install, because it cannot be added later.
- The **data plane** is protected by agentgateway's own auth. The default config must not
  leave it open: enable at least API-key auth, generate the key on first run, persist it in
  `/app/data`, and surface it via `postInstallMessage`. Document enabling OAuth 2.x and JWT
  RBAC as next steps.
- **stdio MCP backends launch local commands.** We bundle `npx` and `uv` so common MCP
  servers work, which means a configured backend can execute commands inside the container.
  Document this clearly so an operator understands the trust boundary.
- TLS for both the admin UI and the data-plane `httpPorts` subdomain comes from the Cloudron
  domain proxy (Let's Encrypt). Only the `tcpPort` fallback lacks domain TLS; in that case
  either let agentgateway terminate TLS or document plain HTTP for clients. Record the choice
  in an ADR.

---

## 11. Path to official Cloudron inclusion

Reviewers will look for: a clean multi-stage Dockerfile on the current base image, correct
read-only filesystem handling, a working health check, instant usability with no setup
screen, sensible default security, a complete manifest with metadata and icon, and clear
documentation. Keep the package thin and the upstream unpatched. The community-app channel
(`CloudronVersions.json`) is the route to make it installable by others before any official
review. See CONTRIBUTING.md.

---

## 12. Definition of done (pre-commit checklist)

- [ ] No write paths outside `/tmp`, `/run`, `/app/data`.
- [ ] Runs as `cloudron`, not root.
- [ ] Upstream version pinned in exactly one canonical place; manifest mirrors it.
- [ ] Topology unchanged, or the change is recorded in an ADR and README.
- [ ] `start.sh` uses `set -euo pipefail` and prints `==>` phase markers.
- [ ] First-run seeding is idempotent; user config is never clobbered.
- [ ] Health check returns 2xx and the path is documented.
- [ ] README, CHANGELOG, and DEBUGGING updated as relevant.
- [ ] Smoke-test ladder in DEBUGGING.md passes on the target Cloudron.
- [ ] Prose follows house style: no em dashes, full words, open formats.
