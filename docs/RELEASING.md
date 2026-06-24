# Releasing

This is the repeatable release runbook for the agentgateway Cloudron package. Following it for a
version bump should require no rediscovery of the steps that were worked out for the first release.

The package version and the upstream agentgateway version move independently. The package version is
plain semver in `CloudronManifest.json`. The upstream version is the `AGENTGATEWAY_VERSION` build
argument in the `Dockerfile`, which is the single source of truth for what upstream binary ships.

## Identity (every release)

All published artifacts use the neutral OrcVole identity and nothing else:

- Repository: `github.com/OrcVole/agentgateway-cloudron`
- Image: `ghcr.io/orcvole/agentgateway-cloudron`
- Commit author and committer: `OrcVole <OrcVole@users.noreply.github.com>`, unsigned

Run the anonymity sweep before every push. No personal host, email, username, or registry may
appear in any tracked file. The private personal mirror is a convenience only; its URL must never
appear in a tracked file.

## Prerequisites

- A container builder. On a host without the Docker daemon, rootless `podman` is enough. `cloudron
  build` also works over the podman socket by exporting
  `DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock`.
- `skopeo`, for reading the registry digest. ImageMagick (`magick`), only if the icon changes.
- The `cloudron` CLI logged in to a box, for the optional end-to-end install check.
- A classic GitHub Personal Access Token for OrcVole with scopes `repo`, `write:packages`, and
  `read:packages`. Keep it in `orcvole-token.txt`, which is gitignored and dockerignored. Delete it
  after the release (see step 12).

## Release sequence

### 1. Bump the upstream version

Change `AGENTGATEWAY_VERSION` in the `Dockerfile`, and nowhere else, to the new upstream tag. Update
`upstreamVersion` in `CloudronManifest.json`. If the package itself changed, bump the package
`version` too. Add a new `[x.y.z]` entry to `CHANGELOG.md` (the bracket form is required, see step 5).

### 2. Linkage gate (Gate 1, mandatory)

The upstream binary is dynamically linked and depends on an exact glibc version. A future upstream
build on a newer toolchain can fail silently on the pinned `cloudron/base` image: the build
succeeds, and the binary only fails at runtime. Prove the new binary runs on the pinned base before
pinning or pushing anything. The built image is the binary on the base, so test it directly:

```
podman build --pull -t ghcr.io/orcvole/agentgateway-cloudron:<ver> -f Dockerfile .
podman run --rm ghcr.io/orcvole/agentgateway-cloudron:<ver> ldd /app/code/agentgateway
podman run --rm ghcr.io/orcvole/agentgateway-cloudron:<ver> /app/code/agentgateway --version
```

The `ldd` output must show no `not found` lines and no `GLIBC_x.y not found` errors, and the version
flag must print the expected version. If either fails, the upstream toolchain has outrun the base.
Stop, raise the `cloudron/base` pin to a newer digest that provides the required glibc, re-run this
gate, and only then continue.

### 3. Push the image

```
printf '%s' "$TOKEN" | podman login ghcr.io -u OrcVole --password-stdin
podman push ghcr.io/orcvole/agentgateway-cloudron:<ver>
```

`cloudron build build --repository ghcr.io/orcvole/agentgateway-cloudron --tag <ver>` over the
podman socket is an equivalent path and produced the same registry digest.

### 4. Capture the registry digest

Read the digest from the registry, not from the local image. A local podman build reports a
different local manifest digest than the registry stores, so always read the tag from the registry:

```
skopeo inspect --format '{{.Digest}}' docker://ghcr.io/orcvole/agentgateway-cloudron:<ver>
```

### 5. Generate the versions entry

`cloudron versions add --state published` writes the new version into `CloudronVersions.json` (a
`version -> manifest-with-dockerImage` map). It needs prior `cloudron build` state and enforces the
strict appstore manifest schema. The fields it demands, which are easy to rediscover the slow way,
are:

- `contactEmail`: must match the email format (`OrcVole@users.noreply.github.com`).
- `iconUrl`: a non-empty URL (the raw `logo.png`).
- `mediaLinks`: at least one entry (the raw screenshot under `screenshots/`).
- `changelog`: the parser wants a literal `[x.y.z]` line, not a markdown `## x.y.z` header. It
  collects the lines under that bracket line until the next `[`.

`cloudron versions add` records `dockerImage` as the tag. Replace it with the digest in step 6.

### 6. Pin the digest

Set the digest reference, never the tag, in both files:

- `CloudronManifest.json` field `dockerImage`
- `CloudronVersions.json` field `versions["<ver>"].manifest.dockerImage`

The form is `ghcr.io/orcvole/agentgateway-cloudron@sha256:<digest>`.

### 7. GHCR visibility

GHCR packages are private by default. The first publish needed a one-time manual flip to public:
profile, then Packages, then the package, then Package settings, then Danger Zone, then Change
visibility, then Public. There is no REST API for this. A normal version bump to the existing
package stays public and needs no action here. Only a change of package name or namespace would
create a new, private package that needs the manual flip again. Note it so that does not surprise a
future maintainer.

### 8. Anonymous-pull-by-digest gate

Before pushing the repository, prove a stranger can pull the exact image. Remove the local copy, log
out, and pull by digest with no credentials:

```
podman rmi -f ghcr.io/orcvole/agentgateway-cloudron@sha256:<digest>
podman logout ghcr.io
printf '{"auths":{}}' > /tmp/empty.json
podman pull --authfile /tmp/empty.json ghcr.io/orcvole/agentgateway-cloudron@sha256:<digest>
```

It must succeed. An `unauthorized` result means the package is still private: fix step 7, and do not
push the repository. This gate exists so the published repository never points at an image strangers
cannot pull.

### 9. Commit and sweep

Stage the changes and commit as OrcVole, unsigned. The repository git config is already set to the
OrcVole identity with `commit.gpgsign=false`, so a plain commit is correct:

```
git add -A
git commit -m "..."
```

Re-run the anonymity sweep over all tracked files plus `CloudronVersions.json`. Confirm no personal
host, email, username, registry, key, or token, and that the only new identifiers are the digest,
`ghcr.io/orcvole`, and the OrcVole URLs.

### 10. Push the repository, token-free

Authenticate as OrcVole without writing a credential into git config or the process arguments, using
`GIT_ASKPASS`:

```
printf '%s' "$TOKEN" > /tmp/.ghtok; chmod 600 /tmp/.ghtok
cat > /tmp/askpass.sh <<'EOF'
#!/bin/sh
case "$1" in Username*) echo OrcVole;; Password*) cat /tmp/.ghtok;; esac
EOF
chmod 700 /tmp/askpass.sh
GIT_ASKPASS=/tmp/askpass.sh GIT_TERMINAL_PROMPT=0 git push github main
rm -f /tmp/askpass.sh /tmp/.ghtok
```

Leave the named remote URL token-free.

### 11. Config-migration gate (Gate 3)

A same-schema update does not exercise the migration transformation, so it stays unproven until an
upstream release actually changes the configuration schema. When upstream changes the schema, run
the migrate transformation against an old configuration before shipping, and confirm the app comes
up on the migrated config. See UPGRADING.md for the full description of this gate alongside the
binary-to-base linkage gate and the update-survival gate.

### 12. Token cleanup

Delete `orcvole-token.txt` after the release. It is a live credential in plaintext on disk. Revoke
the PAT on GitHub as well if no near-term updates are planned.

## The gates, in one place

1. Linkage (Gate 1): the new binary runs on the pinned base, proven by `ldd` and the version flag.
   Mandatory on every bump, because the failure is silent at build time.
2. Anonymous pull: the published digest is pullable with no credentials, checked before the repo
   push.
3. Config migration (Gate 3): exercise the migrate transformation on an old config whenever upstream
   changes the configuration schema. Cross-referenced in UPGRADING.md.
