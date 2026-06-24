# 0001: Protect the admin UI with the Cloudron proxyAuth addon

Status: accepted

## Context

agentgateway exposes an admin interface and UI on port 15000. It has no authentication of its
own, and upstream warns against exposing it publicly. On Cloudron an app's HTTP endpoints are
reachable directly unless the app opts into authentication, because Cloudron does not place a
login proxy in front of apps automatically. The mechanism for opting in is the `proxyAuth`
addon, which authenticates visitors against Cloudron's own identity (single sign-on).

## Decision

Make the admin UI the app's primary `httpPort` (container port 15000) and protect it with the
Cloudron `proxyAuth` addon, declared plainly as `"addons": { "proxyAuth": {} }` with no `path`
restriction, so the entire primary domain requires a logged-in Cloudron user.

Bind the admin listener to `0.0.0.0:15000` through the config field `adminAddr`, and re-assert
that bind on every boot (the genuine default is localhost only, and the UI can rewrite
`config.yaml`). Do not set `basicAuth` or `supportsBearerAuth` on the addon, so there is no way
to bypass the single sign-on wall on the admin domain.

Declare `proxyAuth` from first install, because Cloudron cannot add authentication to an
existing app later (confirmed platform limitation: it requires a reinstall).

## Consequences

- Only logged-in Cloudron users can reach the admin UI, which closes the unauthenticated-admin
  risk that upstream warns about.
- The internal health check (`healthCheckPath` = `/ui/`) reaches the container directly and is
  not affected by `proxyAuth`.
- The data plane must not share this domain. It lives on a separate `httpPorts` subdomain that
  `proxyAuth` does not cover (see decision 0002), so programmatic agent and LLM clients are
  never redirected to a login page.
- Disabling the wall later (for example to substitute a different front-door auth) is a
  manifest change plus reinstall, not a runtime toggle.
