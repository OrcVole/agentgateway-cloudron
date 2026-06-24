# UPGRADING.md

How to move this package to a new upstream agentgateway version, safely and repeatably.

agentgateway is low-risk to upgrade because the only persistent state is the YAML config
file, so there is no storage-format migration as a database package would have. An upgrade is
a version bump, a rebuild, and a test pass. There is one nuance: the config schema itself can
change across versions. agentgateway ships a `migrate` subcommand for that, and `start.sh`
runs it automatically when a persisted config fails validation (see the boot sequence in
DEBUGGING.md). So storage never needs migration, but the config sometimes does, and the two
release gates below exist to catch the two ways a bump can break.

---

## Version policy

- The upstream version is pinned in exactly one canonical place: the `AGENTGATEWAY_VERSION`
  build argument in `Dockerfile`. The Cloudron manifest mirrors it in `upstreamVersion`, but
  the Dockerfile argument is authoritative.
- Never use a floating tag such as `latest`. A reproducible build is the whole point.
- We track stable tags only. agentgateway ships release candidates (`x.y.z-rc.N`) before each
  stable `x.y.z`; we do not pin those.
- The package version (`version` in the manifest) is our own semver and is independent of the
  upstream version. Bump it on every published change.

---

## Current pin

- Upstream: `v1.3.1` (stable, released 2026-06-22; v1.3.0 went GA 2026-06-18).
- Image: `ghcr.io/agentgateway/agentgateway:v1.3.1` (mirror `cr.agentgateway.dev/agentgateway:v1.3.1`).
- Image digest at packaging time:
  `sha256:2e25455a0185f3c5a0e0f5e0f36ccc860c754d4d26632bfa5cc41c2f5bd35141`.

This is the first stable of the v1.3 line, which carries the rebuilt UI, AI cost analysis,
virtual models, reusable providers, and guardrails. The binary lives at `/app/agentgateway`
in the official image, the UI is embedded in it, and the image runs as user 65532.

---

## Release gates (run on every version bump, no exceptions)

Three checks gate every upstream bump. All are mandatory, not advice.

### Gate 1: binary and base linkage

The agentgateway binary is dynamically linked against glibc. At the current pin it requires a
maximum symbol version of `GLIBC_2.39`, which `cloudron/base:5.0.0` provides exactly. This is
a tight match. A future upstream toolchain bump to `GLIBC_2.40` or higher would fail on this
base, and it would fail at runtime, not at build time. So before shipping any new version,
extract the new binary and run, against the target base image:

```bash
ldd /app/code/agentgateway     # every line must resolve on cloudron/base:<pinned>
/app/code/agentgateway -V      # must print the version and exit 0
```

If `ldd` shows an unresolved symbol or `-V` fails, do not ship. Either wait for a newer
`cloudron/base` with a higher glibc, or hold the pin.

### Gate 2: config migration

Storage never migrates, but the config schema can. agentgateway ships
`agentgateway migrate --file <f>`, which rewrites a config in place to the current schema. It
also normalises formatting, so it can drop comments. `start.sh` runs it automatically only
when `--validate-only` fails on the persisted config. Before shipping a bump, test the upgrade
path on a config saved by the previous version:

```bash
agentgateway --validate-only -f /app/data/config.yaml   # may fail after a schema change
agentgateway migrate         -f /app/data/config.yaml   # fixes it in place
agentgateway --validate-only -f /app/data/config.yaml   # must now pass
```

Confirm `migrate` is a semantic no-op on an already-current config, so the boot ladder cannot
loop. A user's live config in `/app/data` is theirs: `start.sh` never reseeds over it. If
validation still fails after `migrate`, the app exits loudly and the operator restores from
the pre-update backup.

### Gate 3: a user-modified config survives the update

An update rebuilds the container and re-runs `start.sh`, but a user's live config in `/app/data`
must not be touched. `start.sh` seeds the default only when `/app/data/config.yaml` is absent, so an
update never reseeds over it. Verified on a real update: a config with an added route, a changed
model, and the boot-time `adminAddr` re-assert all survived, and a round-trip still worked. On every
bump, after `cloudron update`, confirm the customized config is intact and a request still succeeds.
If an update ever reseeded over a user's config, every user would silently lose their
customizations, which is a package-wide defect.

---

## Standard bump steps

1. Confirm the new stable tag exists on the upstream releases page
   (https://github.com/agentgateway/agentgateway/releases) and that the image is published.
   Rely on the tag and the image, not on a blog post.
2. Change the version in the two canonical places:
   - `Dockerfile`: `ARG AGENTGATEWAY_VERSION=v<new>`
   - `CloudronManifest.json`: `upstreamVersion` to `<new>`, and bump `version` (our package
     semver) according to the change. A pure upstream patch is a patch bump.
3. Run both release gates above.
4. Add a CHANGELOG.md entry naming the upstream version, and update the version table in
   AGENTS.md section 4.
5. `cloudron build`, then `cloudron update`, then run the full smoke-test ladder in
   DEBUGGING.md. Cloudron takes a backup before the update, so rollback (revert the two
   version lines, rebuild, update again) is safe.

---

## What to watch for in upstream changes

- **Admin bind:** our topology depends on the admin UI binding to the Cloudron-facing
  interface. The bind is the config field `adminAddr` (there is no `ADMIN_ADDR` environment
  variable), and the genuine default is localhost only, so `start.sh` pins and re-asserts
  `0.0.0.0:15000` every boot. If upstream changes the admin bind mechanism, update `start.sh`
  and re-test the proxied UI.
- **Default ports:** admin 15000, readiness 15021, stats 15020. If these change, update the
  manifest, `start.sh`, and the health path.
- **Image base or binary path:** the multi-stage copy depends on the binary location
  (`/app/agentgateway`) in the official image. Re-verify on any major image change and re-run
  Gate 1.
- **Config schema:** referenced at https://agentgateway.dev/schema/config. Validate the
  default `config/config.yaml` against the new version, and run Gate 2 on a real saved config.
