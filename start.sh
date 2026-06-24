#!/bin/bash
#
# Cloudron entrypoint for agentgateway.
#
# Runs as root, prepares /app/data, enforces the admin bind, validates (and if needed
# migrates) the config, then drops to the cloudron user and execs the gateway. Every
# package-emitted line is prefixed with "==>" so logs are greppable. See DEBUGGING.md for the
# boot ladder and UPGRADING.md for the release gates.

set -euo pipefail

CODE=/app/code
DATA=/app/data
BIN="${CODE}/agentgateway"
SEED="${CODE}/config.yaml"
CONFIG="${DATA}/config.yaml"
KEY_FILE="${DATA}/.api_key"
ADMIN_BIND="0.0.0.0:15000"
VERSION="${AGENTGATEWAY_VERSION:-unknown}"

echo "==> [start] agentgateway ${VERSION} booting"

# 1. Ownership. Backups and restores can reset it, so fix it before touching /app/data.
echo "==> [start] fixing ownership of ${DATA}"
chown -R cloudron:cloudron "${DATA}"

# 2. First run only: seed the default config and generate the data-plane API key.
#    Never clobber an existing config; that is the user's data.
if [[ ! -f "${CONFIG}" ]]; then
  echo "==> [start] first run: seeding config from ${SEED}"
  install -o cloudron -g cloudron -m 0640 "${SEED}" "${CONFIG}"

  echo "==> [start] generating data-plane API key"
  GEN_KEY="$(openssl rand -hex 32)"
  printf '%s\n' "${GEN_KEY}" > "${KEY_FILE}"
  chown cloudron:cloudron "${KEY_FILE}"
  chmod 0600 "${KEY_FILE}"
  GEN_KEY="${GEN_KEY}" yq -i '.binds[0].listeners[0].policies.apiKey.keys[0].key = strenv(GEN_KEY)' "${CONFIG}"
  unset GEN_KEY
  echo "==> [start] api key generated and stored at ${KEY_FILE}"
else
  echo "==> [start] existing config found at ${CONFIG}"
fi

# 3. Re-assert the admin bind on every boot. The genuine default is localhost only, and the
#    UI can drop the field on save, either of which would make the UI unreachable by Cloudron.
echo "==> [start] pinning config.adminAddr=${ADMIN_BIND}"
ADMIN_BIND="${ADMIN_BIND}" yq -i '.config.adminAddr = strenv(ADMIN_BIND)' "${CONFIG}"
chown cloudron:cloudron "${CONFIG}"

# 4. Validate. A missing environment reference is a user error that migrate cannot fix, so
#    fail fast on it and keep the user's comments intact. Any other failure may be a schema
#    change from an upgrade, so migrate (which rewrites in place) and validate again; if it is
#    still invalid, fail loudly rather than reseed over user data.
echo "==> [start] validating config"
if validate_out="$(gosu cloudron:cloudron "${BIN}" --validate-only -f "${CONFIG}" 2>&1)"; then
  echo "==> [start] config valid"
else
  printf '%s\n' "${validate_out}" | sed 's/^/    /'
  if printf '%s' "${validate_out}" | grep -q 'environment variable not found'; then
    echo "==> [start] FATAL: the config references an environment variable that is not set." >&2
    echo "==> [start] Set it in the app environment (the dashboard), or remove that reference from ${CONFIG}." >&2
    exit 1
  fi
  echo "==> [start] validation failed; running 'migrate' (config schema may have changed)"
  gosu cloudron:cloudron "${BIN}" migrate -f "${CONFIG}" || true
  if gosu cloudron:cloudron "${BIN}" --validate-only -f "${CONFIG}" >/dev/null 2>&1; then
    echo "==> [start] migrate succeeded; config now valid"
  else
    echo "==> [start] FATAL: ${CONFIG} is invalid even after migrate." >&2
    echo "==> [start] Compare it against ${SEED} and the schema at https://agentgateway.dev/schema/config." >&2
    echo "==> [start] Not reseeding (that would destroy your config). Fix the file or restore the pre-update backup." >&2
    exit 1
  fi
fi

# 4b. stdio MCP servers (npx, uvx) need a writable HOME and caches, but the rootfs is
#     read-only. Point them at /app/data (persistent, so downloaded servers survive
#     restarts). agentgateway passes this environment to the backends it launches.
export HOME=/app/data
export XDG_CACHE_HOME=/app/data/.cache
export XDG_DATA_HOME=/app/data/.local/share
export npm_config_cache=/app/data/.npm
export UV_CACHE_DIR=/app/data/.uv
mkdir -p "${XDG_CACHE_HOME}" "${XDG_DATA_HOME}" "${npm_config_cache}" "${UV_CACHE_DIR}"
chown -R cloudron:cloudron /app/data/.cache /app/data/.local /app/data/.npm /app/data/.uv

# 5. Report the resolved runtime facts (never secrets) and hand off.
echo "==> [start] version  : ${VERSION}"
echo "==> [start] adminAddr: ${ADMIN_BIND} (admin UI on the primary domain, behind Cloudron login)"
echo "==> [start] dataplane: container port 3000 -> ${DATA_PLANE_DOMAIN:-<gw-api subdomain>} (Bearer API key)"
echo "==> [start] api key  : $( [[ -s "${KEY_FILE}" ]] && echo present || echo MISSING )"
echo "==> [start] config   : ${CONFIG}"
echo "==> [start] exec agentgateway ${VERSION}"
exec gosu cloudron:cloudron "${BIN}" -f "${CONFIG}"
