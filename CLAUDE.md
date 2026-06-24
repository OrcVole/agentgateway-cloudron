# CLAUDE.md

The canonical instructions for this repository live in **AGENTS.md**. Read it first and
follow it in full.

This file exists only so that tools which look for `CLAUDE.md` are pointed at the single
source of truth. Do not duplicate guidance here, because two copies drift apart. If you
believe something belongs in the agent contract, edit AGENTS.md.

Quick reminders that are easy to forget:

- Pin the upstream version in one place only (the `AGENTGATEWAY_VERSION` build argument).
- The admin UI is unauthenticated; protect it with the Cloudron proxyAuth addon. Never put
  proxyAuth in front of the data plane.
- The config file is mutable and lives in `/app/data`. Seed it idempotently on first run.
- `set -euo pipefail` in `start.sh`, and print `==>` phase markers so logs are greppable.
- House style: no em dashes, full words rather than contractions, open formats only.

To upgrade the upstream version (for example to a newer stable tag than v1.3.1), follow
**UPGRADING.md**. To diagnose a broken deploy, follow **DEBUGGING.md**.
