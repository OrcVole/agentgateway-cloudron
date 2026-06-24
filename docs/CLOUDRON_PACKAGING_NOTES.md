# Packaging applications for Cloudron: field notes

These are practical, hard-won notes for packaging a third-party application as a Cloudron app,
written for the next packager, human or AI. They complement the official Cloudron packaging
documentation, and in a few places they sharpen or correct it. They were distilled from packaging
this repository (an MCP and LLM gateway), but the lessons are general.

## 1. Topology: match each surface to an auth model

Many modern applications expose two kinds of surface that need different protection:

- A human admin interface, often with weak or no authentication of its own. Put it on the primary
  domain behind the `proxyAuth` addon, so Cloudron single sign-on guards it.
- A programmatic or data-plane API that automated clients call and that cannot complete an
  interactive login. Put it on its own subdomain through a plural `httpPorts` entry, with no
  `proxyAuth`, secured by the application's own credential (an API key, a token).

The rule that prevents the most common mistake: never put `proxyAuth` in front of a programmatic
client. It redirects unauthenticated requests to a login page, which a non-browser client cannot
satisfy, so every call breaks with a redirect instead of a clean 401.

Two facts that bite:
- `proxyAuth` cannot be added after the first install. Declare it in the manifest from the start.
- The addon key is camelCase `proxyAuth`. The packaging reference has shown it lowercase, which
  fails manifest validation.

## 2. The image

- Build `FROM cloudron/base`, pinned by digest. The base provides a known glibc, gosu, Node, curl,
  and tini.
- Prefer a multi-stage build that copies a single binary out of the upstream image. Keep the
  runtime surface small.
- The root filesystem is read-only at runtime. Only `/tmp`, `/run`, and `/app/data` are writable.
  Point any cache (npm, uv, XDG) at `/app/data`.
- Run as the `cloudron` user via `gosu`, not as root.
- `/app/data` is the only persistent state, provided by the `localstorage` addon. The box mounts it
  before the entrypoint runs, so changing its ownership in the entrypoint works on the box. It does
  not exist when you run the image standalone, so for a local smoke test you must mount a volume at
  `/app/data` or the entrypoint fails at the first `chown`.
- `healthCheckPath` must return a 2xx. If the application's readiness endpoint is on a separate port
  (reverse proxies map one port), use a path the main port actually serves, for example the UI path.

## 3. Config and first-run seeding

- Seed the default config into `/app/data` only when none exists. Never overwrite a user's config on
  boot.
- Re-assert the handful of fields the platform requires (for example a bind address of
  `0.0.0.0:<port>`) on every boot. The admin UI rewrites the config file when a user saves, and that
  rewrite can drop fields and strips comments. A YAML-aware tool in the image makes this reliable; a
  blind text edit does not.
- Ship an inert default. If the application refuses to start when its config references an unset
  environment variable, do not reference any in the shipped default. Some applications interpolate
  `$VAR` from the raw file text, including inside comments, so a commented-out example with a `$VAR`
  can still break boot. Keep the default free of them.

## 4. Building without a Docker daemon

- Rootless `podman` is enough. `cloudron build` will drive it over the podman socket if you export
  `DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock`; it uses BuildKit through the
  docker-container driver.
- A fully cached rebuild cannot be pushed. If nothing in the image filesystem changed, BuildKit
  reports that the result will only remain in the build cache, and the subsequent push fails with
  "image not known." This matters because a manifest-only change (see the icon, below) produces no
  new image and no new digest.
- Read the pushed digest from the registry, not from the local image. A local podman build reports a
  different local manifest digest than the registry stores. Use
  `skopeo inspect --format '{{.Digest}}' docker://<repo>:<tag>`.

## 5. The icon is not in the Docker image

This one is easy to get wrong. The dashboard icon is not baked into the image filesystem. The
cloudron CLI reads `logo.png` (the manifest `icon: file://...` reference) at install or update time
and uploads it to the box, which stores it. Consequences:

- Changing the icon does not require an image rebuild. It requires a `cloudron update` that re-reads
  the file.
- An installed app keeps the icon it was given at install. Refresh it with an update.
- A community install via a versions URL takes its icon from `iconUrl` (a raw repository URL),
  because there is no local file to resolve. So `iconUrl` is what the public sees; the `file://`
  icon is what an on-server build embeds at build time.
- The required size is a square 256x256 PNG.

## 6. Publishing as a community app

- Registry package visibility is separate from repository visibility. After the first push the image
  package is private; flip the package itself to public in the registry web UI (for GitHub Container
  Registry: profile, Packages, the package, Package settings, Danger Zone, Change visibility). There
  is no REST endpoint for this. An anonymous pull returning `unauthorized` means the package is still
  private.
- Pin the image by digest, never by tag, in both `CloudronManifest.json` (`dockerImage`) and the
  versions file.
- Prove an anonymous pull by digest, from a logged-out context, before publishing the repository.
  The published repository must never point at an image strangers cannot pull.
- Install path: `cloudron install --versions-url <raw CloudronVersions.json URL>`. The box fetches
  the versions file, reads the digest-pinned image, and pulls it anonymously.
- `cloudron update` has no `--versions-url`. An app installed by on-server build updates via
  `--image <digest>` or a rebuild, not via the versions URL.

## 7. The strict appstore schema (cloudron versions add)

`cloudron versions add` writes the versions file, but it enforces a stricter schema than
`cloudron install` does, and it needs prior `cloudron build` state. It rejects, one cascading error
at a time:

- a `contactEmail` that is not a valid email format. A neutral noreply address satisfies it.
- an empty `iconUrl`.
- an empty `mediaLinks`. It wants at least one screenshot URL.
- a changelog that is not in its bracket format. The parser looks for a literal `[x.y.z]` line, not a
  markdown `## x.y.z` header, and collects the lines under it until the next `[`.

It also records `dockerImage` as the tag; replace it with the `@sha256:` digest afterward. A versions
entry has the shape
`{ "stable": true, "versions": { "x.y.z": { "manifest": { ...with dockerImage... }, "publishState": "published" } } }`.

## 8. Verification gates worth running every release

- Binary-to-base linkage. The upstream binary is dynamically linked to a specific glibc. A future
  upstream build on a newer toolchain fails silently on the pinned base. Run `ldd` and the version
  flag on the new binary inside the built image; if either fails, raise and re-pin the base.
- Anonymous pull by digest, before pushing the repository.
- Config migration, when the upstream config schema changes. A same-schema update does not exercise
  the migration transform, so it stays unproven until a schema change ships.
- The real community path. Install a throwaway instance from the public versions URL on a spare
  subdomain, confirm the app log shows the image being pulled by its digest, run the smoke checks,
  then uninstall. This is the only test that exercises what a stranger does.

## 9. Operational gotchas

- The platform reverse proxy has a read timeout of about sixty seconds, with no per-app setting. A
  slow first response (a cold model load, a long computation) gets cut. Mitigate with a keep-alive on
  the backend and by preferring streaming, which keeps bytes flowing and resets the window.
- A route that serves an endpoint and a top-level registry that a dashboard reads can be independent.
  A request can succeed through the route and be recorded in the logs while the dashboard, which
  reads the empty registry, shows nothing and warns that it is not initialized. Do not assume an
  empty dashboard means no traffic; check the logs.
- An OpenAI-compatible chat route that serves only `POST /v1/chat/completions` returns an error on
  `GET /v1/models`, so a client like OpenWebUI cannot auto-list models. The user adds the model name
  by hand. This is expected, not a fault.
- `localhost` may resolve to IPv6 while a rootless port map is IPv4 only. Use `127.0.0.1` when
  smoke-testing a locally run container.

## 10. The meta-lesson

Verify against the running system, not the documentation. Check the binary against the base with the
dynamic linker. Validate the config with the application's own validate-only mode. Inspect the
running container. Test the real install path end to end. Every assumption carried from a brief or a
reference document, and not checked against the running system, needed correction at least once,
including a point in the official packaging reference itself.
