#!/bin/bash
#
# Runtime smoke gate for the agentgateway Cloudron package. No box required: it runs the image the
# way Cloudron does (root entrypoint -> start.sh -> gosu cloudron) and asserts the package contract.
#
# The contract this exists to defend is the TWO-SURFACE TOPOLOGY (docs/decisions/0001 and 0002),
# which is the thing most likely to be broken silently by an upstream change:
#
#   * admin UI  on container port 15000, the primary Cloudron domain, behind the proxyAuth wall
#   * data plane on container port 3000, a separate subdomain, NOT behind the wall, secured by the
#     API key this package generates on first run
#
# Cloudron's proxyAuth wall lives in the platform, not in the image, so a local run cannot test the
# wall itself. What it CAN test, and what actually breaks, is everything the wall depends on:
# that the admin listener really binds 0.0.0.0:15000 (upstream's genuine default is localhost only,
# and the admin UI can rewrite config.yaml), that the data plane rejects an unkeyed request rather
# than serving it, and that the generated key is well-formed and does not leak into the logs.
#
# Usage:  test/smoke.sh [image]     (default: ghcr.io/orcvole/agentgateway-cloudron:dev)
#         ENGINE=docker test/smoke.sh   to use docker instead of podman
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

IMAGE="${1:-ghcr.io/orcvole/agentgateway-cloudron:dev}"
ENGINE="${ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
NAME="agw-smoke-$$"
VOL="agw-smoke-vol-$$"
ADMIN_PORT="${ADMIN_PORT:-15900}"
DATA_PORT="${DATA_PORT:-13900}"

fails=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails+1)); }

cleanup() {
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  "$ENGINE" volume rm "$VOL" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

echo "=== smoke: image=${IMAGE} engine=${ENGINE} ==="
"$ENGINE" volume create "$VOL" >/dev/null

# Run it as Cloudron does: read-only rootfs with tmpfs for the writable bits, /app/data on a volume.
"$ENGINE" run -d --name "$NAME" \
  --read-only --tmpfs /run --tmpfs /tmp \
  -v "$VOL":/app/data \
  -p 127.0.0.1:${ADMIN_PORT}:15000 \
  -p 127.0.0.1:${DATA_PORT}:3000 \
  -e CLOUDRON=1 \
  -e CLOUDRON_APP_ORIGIN="http://localhost:${ADMIN_PORT}" \
  "$IMAGE" >/dev/null 2>&1 || { echo "could not start container"; exit 1; }

# 1. Boots and the admin UI answers. The health check path is /ui/, so this is gate 0's local twin.
up=0
for i in $(seq 1 60); do
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ADMIN_PORT}/ui/" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { up=1; ok "admin UI /ui/ returns 200 (~$((i*2))s)"; break; }
  "$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -q "^${NAME}$" || { bad "container exited early"; "$ENGINE" logs "$NAME" 2>&1 | tail -30; exit 1; }
  sleep 2
done
[ "$up" = 1 ] || { bad "admin UI never answered (last code=$code)"; "$ENGINE" logs "$NAME" 2>&1 | tail -30; exit 1; }

# 2. The admin listener is bound to 0.0.0.0, not localhost. If this regresses, Cloudron's proxy
#    cannot reach the UI at all and the app is dead on the platform while passing every local test
#    that talks to it inside the container. Asserted from OUTSIDE the container (the port mapping
#    above only works on a 0.0.0.0 bind), and from the config the process actually loaded.
#    Read the VALUE with yq (bundled in the image) rather than grepping the file: the seed config
#    explains adminAddr in a comment, and a grep matches the prose and passes regardless.
bind=$("$ENGINE" exec "$NAME" yq -r '.config.adminAddr // "unset"' /app/data/config.yaml 2>/dev/null | tr -d '\r\n')
[ "$bind" = "0.0.0.0:15000" ] && ok "config.adminAddr pinned to 0.0.0.0:15000" \
  || bad "config.adminAddr='${bind}' (want 0.0.0.0:15000)"
#    Corroborate from the running process: the bind is what the listener actually established.
#    -a and -F: the log stream can carry bytes grep treats as binary, and a fixed string avoids
#    the whitespace between the tab-separated fields mattering.
"$ENGINE" logs "$NAME" 2>&1 | grep -aqF 'address=0.0.0.0:15000' \
  && ok "admin listener established on 0.0.0.0:15000" \
  || bad "no admin listener on 0.0.0.0:15000 in the logs"

# 3. THE SECURITY CONTRACT: the data plane must reject an unkeyed request. A 200 here would mean
#    the MCP/LLM endpoint is open to anyone who can reach the subdomain, which proxyAuth does NOT
#    cover by design (decision 0002).
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DATA_PORT}/" 2>/dev/null || echo 000)
case "$code" in
  401|403) ok "data plane rejects an unkeyed request (HTTP $code)" ;;
  000)     bad "data plane :3000 unreachable — the listener did not come up" ;;
  *)       bad "data plane returned HTTP $code without a key (expected 401/403)" ;;
esac

# 4. The generated key works where the unkeyed request failed. This is the other half of 3: a data
#    plane that rejects EVERYTHING would also pass the check above.
KEY=$("$ENGINE" exec "$NAME" cat /app/data/.api_key 2>/dev/null | tr -d '\r\n')
[ "${#KEY}" = 64 ] && ok "API key is 64 hex characters" || bad "API key length=${#KEY} (want 64)"
if [ -n "$KEY" ]; then
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "http://127.0.0.1:${DATA_PORT}/" 2>/dev/null || echo 000)
  [ "$code" != "401" ] && [ "$code" != "403" ] && [ "$code" != "000" ] \
    && ok "data plane accepts the generated key (HTTP $code)" \
    || bad "data plane rejected its own generated key (HTTP $code)"
fi

# 5. Key file permissions, and the key must not reach the logs. A Cloudron restore returns files
#    0644, so start.sh re-asserts 0600 on every boot; this catches that regressing.
perms=$("$ENGINE" exec "$NAME" stat -c '%a %U:%G' /app/data/.api_key 2>/dev/null)
[ "$perms" = "600 cloudron:cloudron" ] && ok "key file is 600 cloudron:cloudron" || bad "key file perms='$perms' (want 600 cloudron:cloudron)"
if [ -n "$KEY" ]; then
  "$ENGINE" logs "$NAME" 2>&1 | grep -qF "$KEY" && bad "API key leaked into the logs" || ok "no API key in the logs"
fi

# 6. Dropped privileges. start.sh runs as root to prepare /app/data, then gosu's to cloudron.
u=$("$ENGINE" exec "$NAME" sh -c 'ps -o user= -C agentgateway 2>/dev/null | head -1' 2>/dev/null | tr -d ' ')
[ "$u" = "cloudron" ] && ok "agentgateway runs as cloudron" || bad "agentgateway runs as '${u:-unknown}' (want cloudron)"

# 7. The bundled MCP runtimes resolve. Upstream ships stdio MCP servers launched via npx/uvx, and
#    the read-only rootfs makes their HOME/cache placement fragile (see start.sh step 4b).
for t in uv uvx node; do
  "$ENGINE" exec "$NAME" sh -c "command -v $t >/dev/null 2>&1" && ok "runtime '$t' present" || bad "runtime '$t' missing"
done

echo
echo "=== smoke result: ${fails} failure(s) ==="
[ "$fails" = 0 ] || "$ENGINE" logs "$NAME" 2>&1 | tail -40
exit $((fails > 0 ? 1 : 0))
