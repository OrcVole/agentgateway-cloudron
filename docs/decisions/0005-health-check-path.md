# 0005: Health check on /ui/

Status: accepted

## Context

Cloudron polls `healthCheckPath` on the primary `httpPort` and expects a 2xx response.
agentgateway's admin listener (the primary `httpPort`, container port 15000) serves the UI at
`/ui`. The readiness probe (`/healthz/ready`) and the metrics endpoint (`/metrics`) live on
separate listeners (`:15021` and `:15020`) that the manifest does not map, so neither can be the
health path.

## Decision

Use `healthCheckPath` = `/ui/`, with the trailing slash. Verified on the admin listener: `/ui/`
returns 200, while the bare `/` is a 308 redirect, which is not a reliable 2xx. Cloudron's internal
health check reaches the container directly, so the `proxyAuth` wall on the public side does not
interfere.

## Consequences

- The app reports healthy exactly when the admin UI is being served, which also implies the binary
  started and bound the admin interface.
- A future upstream change to the admin path or the UI mount point would break the health check.
  UPGRADING.md lists the admin bind and the default ports as things to re-verify on a bump.
