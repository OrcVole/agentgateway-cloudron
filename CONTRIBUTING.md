# CONTRIBUTING.md

Thank you for working on this package. It packages agentgateway for Cloudron. The aim is a
thin, conformant, well-documented package that we run ourselves, that others can install,
and that the Cloudron team could adopt as an official application.

Read **AGENTS.md** first. It is the contract for both humans and AI agents and it holds the
rules that this file assumes.

---

## Development workflow

1. **Prerequisites:** Docker on your machine, a Docker registry you can push to, the
   Cloudron CLI (`npm install -g cloudron`), and access to the target Cloudron.
2. **Install the Cloudron packaging skills** if you use an AI editor, so the assistant has
   the current conformance rules:
   ```bash
   npx skills add https://git.cloudron.io/docs/skills.git --skill cloudron-app-packaging
   npx skills add https://git.cloudron.io/docs/skills.git --skill cloudron-app-publishing
   ```
3. **Build and install:**
   ```bash
   cloudron build
   cloudron install --location agentgateway.example.com
   ```
   Use `--debug` while iterating (see DEBUGGING.md).
4. **Test:** run the smoke-test ladder in DEBUGGING.md ("Verifying a deploy"). A change is
   not done until it passes.
5. **Document:** update the docs your change touches. Code and docs ship together.
6. **Commit:** one concern per commit, with a message that states the symptom fixed or the
   behaviour added.

---

## Conventions (short version, full version in AGENTS.md)

- Pin the upstream version in one canonical place (the `AGENTGATEWAY_VERSION` build
  argument). Never use `latest`.
- Persisted state lives only in `/app/data`. Run as the `cloudron` user. Keep the root
  filesystem read-only.
- Do not change the topology (admin UI behind the OAuth proxy; data plane secured by
  agentgateway's own auth) without an Architecture Decision Record in `docs/decisions/`.
- House style for prose: Markdown and open formats only, no em dashes, full words rather
  than contractions.

---

## Versioning

- The package version (manifest `version`) is our own semver. Bump it on every published
  change.
- `upstreamVersion` mirrors the pinned agentgateway version.
- Upstream upgrades follow UPGRADING.md. The move from v1.3.0-rc.2 to v1.3.0 stable is
  pre-planned there.

---

## Publishing as a community app

The community-app channel makes the package installable by others before any official
review:

1. Keep `CloudronManifest.json` metadata complete: id, title, author, description, tagline,
   website, contactEmail, icon, tags.
2. Maintain `CloudronVersions.json` as the version channel.
3. Publish per the `cloudron-app-publishing` skill and the docs at
   https://docs.cloudron.io/packaging/ .
4. Announce in the Cloudron forum so others can test, and link the public repository.

---

## Path to official inclusion

If the package is to be considered as an official Cloudron application, expect reviewers to
look for:

- A clean multi-stage Dockerfile on the current Cloudron base image, with the upstream
  unpatched and consumed from the official release artifact.
- Correct read-only filesystem handling and all writable state under `/app/data`.
- A working health check that returns 2xx.
- Instant usability: no setup screen, sane defaults, any generated secret surfaced through
  `postInstallMessage`.
- A sensible default security posture, including the topology decision and how the admin UI
  is protected.
- A complete manifest with metadata and a 256x256 icon.
- Clear documentation: README for users, AGENTS.md and DEBUGGING.md for maintainers,
  UPGRADING.md for version moves.

Keep the package thin. The less we diverge from upstream, the easier it is to maintain and
to adopt.

---

## Reporting problems

Open an issue in this repository with: what you did, what you expected, what happened, the
relevant `cloudron logs` output (the `==>` lines in particular), and the package and
upstream versions. If the problem is in agentgateway itself rather than the packaging,
report it upstream at https://github.com/agentgateway/agentgateway and link it here.
