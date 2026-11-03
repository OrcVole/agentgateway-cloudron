#!/bin/bash
# trivy-scan.sh - the known-vulnerability gate for the published image. CANONICAL COPY.
#
# SCAN_VERSION below is the consolidation handle, same idea as secret-scan.sh: this script is
# copied into every package, so the only defence against the drift that produced twelve different
# secret gates is a version stamp CI can compare. Bump it when this file changes; never edit a
# package's copy in place.
SCAN_VERSION=2026-11-03.2
#
# WHY THIS EXISTS ALONGSIDE secret-scan.sh
# secret-scan answers "does this artefact leak something of ours". Nothing answered "does this
# artefact ship something already known to be broken", which is a different question with a
# different owner (upstream, not us) and a different fix (a base bump, not an edit). Without it the
# only vulnerability check on a published image is whoever happens to read the advisory list that
# week, and a package can sit public on GHCR for months carrying a fixed-months-ago glibc.
#
# WHAT IT SCANS, and why these two surfaces
#   1. the built IMAGE - OS packages and language dependencies as installed. This is the artefact
#      the world pulls, so it is the one whose findings count.
#   2. the REPO CONFIG - Dockerfile and friends, for the misconfigurations trivy's config scanner
#      knows about (root user, missing USER, ADD where COPY would do, unset healthcheck, ...).
#      Cheap, and it catches the class of mistake a reviewer stops seeing after the tenth read.
#
# SEVERITY POLICY. HIGH and CRITICAL fail. MEDIUM and below are printed and do not - a gate that
# fails on a MEDIUM in a transitive dependency of a base image is a gate everyone learns to bypass.
# --ignore-unfixed is ON for the image scan: an advisory with no fixed version anywhere cannot be
# acted on by this repository, and blocking on it means the release never goes out. That exclusion
# is PRINTED, counted, and named, so "unfixed and unactionable" is visible rather than silent.
#
# THE ALLOWLIST. `.trivyignore` holds one finding ID per line, each with a reason beside it. Same
# doctrine as `.scan-allowlist`: a line is a REVIEWABLE CLAIM that the finding does not apply here,
# never a way to quieten a real one. Empty is the normal state. Anything that needs an entry should
# first be tested against a fix (base bump, dependency bump) - an exception without an attempt at a
# fix is a decision someone will inherit without the context.
#
# FAIL CLOSED. If trivy is missing, this script SKIPS with a loud note when run by hand, and FAILS
# when CI is set (CI=true, GITHUB_ACTIONS, or TRIVY_REQUIRE=1). A gate that cannot run must never
# report the same green as a gate that ran and found nothing - that is the defect this whole family
# of scripts exists to prevent.
#
# TRIVY_REPORT_ONLY=1 exists for ONE evidence-gathering pass, identical in spirit to
# SCAN_REPORT_ONLY: it prints findings and exits 0, and leaving it set turns the gate into a log
# nobody reads. Unset it as soon as the findings are triaged.
#
# Usage: test/trivy-scan.sh [IMAGE]
#   IMAGE defaults to $SCAN_IMAGE, else the dockerImage in CloudronManifest.json, else image-only
#   scan is skipped and only the config scan runs.
#   TRIVY_MIN_VERSION   minimum acceptable trivy (default 0.58.0)
#   TRIVY_REPORT_DIR    write JSON and SARIF evidence there (off by default: they are large)
#   SCAN_SBOM=<path>    also write a CycloneDX software bill of materials for the image. This is
#                       the artefact an assessor asks for and the thing that answers "which
#                       packages were in the build that shipped", so CI produces it every run
#                       rather than reconstructing it months later from an image nobody kept.
#   TRIVY_SEVERITY      override the failing severities (default HIGH,CRITICAL)
#   TRIVY_REPORT_ONLY=1 print, do not enforce
#
# Exit status: 0 clean (or report-only), 1 findings or a gate that could not run, 2 usage/setup.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
MIN_VERSION="${TRIVY_MIN_VERSION:-0.58.0}"
REPORT_DIR="${TRIVY_REPORT_DIR:-}"

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
FAIL=0

say "==================================================="
say "trivy-scan $SCAN_VERSION - known vulnerabilities in the published image"
say "  severities that fail: $SEVERITY"
say "==================================================="

# --- is there a scanner, and is it new enough ---------------------------------- #
TRIVY=""
for candidate in "${TRIVY_BIN:-}" "$(command -v trivy 2>/dev/null || true)" /usr/local/bin/trivy; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { TRIVY="$candidate"; break; }
done

if [ -z "$TRIVY" ]; then
  if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${TRIVY_REQUIRE:-0}" = "1" ]; then
    printf 'FAIL: trivy is not installed, and this is CI (or TRIVY_REQUIRE=1).\n'
    note "A vulnerability gate that silently skips is worse than no gate: it reports green."
    note "Install it (the workflow pins a version), or set TRIVY_REPORT_ONLY=1 for one deliberate pass."
    exit 1
  fi
  say "SKIP: trivy is not installed - the vulnerability gate did NOT run."
  note "this is a skip, not a pass; install trivy to check the artefact"
  note "the workflow installs a pinned trivy and would fail here, not skip"
  exit 0
fi

TRIVY_VER="$("$TRIVY" --version 2>/dev/null | awk '/^Version:/ { print $2; exit }')"
say "scanner: $TRIVY (version ${TRIVY_VER:-unknown}, minimum $MIN_VERSION)"
if [ -n "$TRIVY_VER" ]; then
  # Sort both as version strings; the minimum must not sort after the installed one.
  lowest="$(printf '%s\n%s\n' "$MIN_VERSION" "$TRIVY_VER" | sort -V | head -1)"
  if [ "$lowest" != "$MIN_VERSION" ]; then
    fail "trivy $TRIVY_VER is older than the minimum this gate was written against ($MIN_VERSION) - its rule set may miss findings"
  fi
fi

IGNORE_ARGS=()
if [ -s .trivyignore ]; then
  say "allowlist: .trivyignore ($(grep -cvE '^[[:space:]]*(#|$)' .trivyignore) finding(s) excepted)"
  IGNORE_ARGS=(--ignorefile .trivyignore)
fi

report() {  # <format> <path>
  [ -n "$REPORT_DIR" ] || return 0
  mkdir -p "$REPORT_DIR"
  "$@" >/dev/null 2>&1 || true
}

# --- 1. the image --------------------------------------------------------------- #
IMAGE="${1:-${SCAN_IMAGE:-}}"
if [ -z "$IMAGE" ] && [ -f CloudronManifest.json ]; then
  IMAGE="$(sed -n 's/.*"dockerImage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' CloudronManifest.json | head -1)"
fi

if [ -z "$IMAGE" ]; then
  say "image: none given (no argument, no SCAN_IMAGE, no dockerImage in the manifest)"
  note "the image surface was NOT scanned - only the config scan below"
else
  say ""
  say "-- image: $IMAGE"
  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    note "no podman or docker on PATH: assuming trivy can reach the image itself"
  fi
  if [ -n "$REPORT_DIR" ]; then
    report "$TRIVY" image --quiet --format json --output "$REPORT_DIR/trivy-image.json" "$IMAGE"
    report "$TRIVY" image --quiet --format sarif --output "$REPORT_DIR/trivy-image.sarif" "$IMAGE"
  fi
  # The SBOM is generated from the same image the gate inspects, in the same run, so the two can
  # never disagree about what was scanned. Not fatal: an SBOM that costs a build failure is worse
  # than none, but the omission is said out loud.
  if [ -n "${SCAN_SBOM:-}" ]; then
    if "$TRIVY" image --quiet --format cyclonedx --output "$SCAN_SBOM" "$IMAGE" >/dev/null 2>&1; then
      note "sbom: $SCAN_SBOM ($(wc -c <"$SCAN_SBOM" 2>/dev/null || echo 0) bytes, cyclonedx)"
    else
      note "sbom NOT written: trivy could not emit cyclonedx for $IMAGE"
    fi
  fi
  image_args=(image --quiet --severity "$SEVERITY" --ignore-unfixed --exit-code 1
              --scanners vuln "${IGNORE_ARGS[@]}" "$IMAGE")
  # Trivy's exit code cannot separate "found something" from "could not run" once --exit-code is
  # set: a FATAL from a missing DB or an unreachable registry also arrives as 1. So the text is
  # read as well, and "the gate did not run" is reported as its own failure rather than as a
  # vulnerability. That distinction is the whole point of the script.
  image_out="$("$TRIVY" "${image_args[@]}" 2>&1)"; image_rc=$?
  printf '%s\n' "$image_out"
  if printf '%s' "$image_out" | grep -qE 'FATAL|scan error|unable to (initialize|download|open|cache)|no space left'; then
    fail "the image scan could not run (trivy exit $image_rc) - this is NOT a clean result"
    note "common causes: no vulnerability DB reachable, an image that will not pull, a cache lock"
    note "from a concurrent run, or no space (set TRIVY_CACHE_DIR to somewhere with room)"
  elif [ "$image_rc" -eq 1 ]; then
    fail "the image carries $SEVERITY vulnerabilities with a fix available (above)"
  elif [ "$image_rc" -ne 0 ]; then
    fail "the image scan exited $image_rc (above)"
  fi

  # Printed deliberately: these are the advisories nobody can act on from here, and hiding them
  # behind --ignore-unfixed without showing them would make the gate look cleaner than it is.
  unfixed="$("$TRIVY" image --quiet --severity "$SEVERITY" --scanners vuln --format json "$IMAGE" 2>/dev/null \
            | grep -c '"FixedVersion": ""' || true)"
  [ "${unfixed:-0}" -gt 0 ] && note "($unfixed $SEVERITY finding(s) have no fixed version anywhere and are not enforced)"
fi

# --- 2. the repo config --------------------------------------------------------- #
say ""
say "-- config: Dockerfile and friends"
cfg_out="$("$TRIVY" config --quiet --severity "$SEVERITY" --exit-code 1 "${IGNORE_ARGS[@]}" . 2>&1)"; cfg_rc=$?
printf '%s\n' "$cfg_out"
if printf '%s' "$cfg_out" | grep -qE 'FATAL|scan error|unable to (initialize|download|open|cache)'; then
  fail "the config scan could not run (trivy exit $cfg_rc) - this is NOT a clean result"
elif [ "$cfg_rc" -eq 1 ]; then
  fail "the build manifests carry $SEVERITY misconfigurations (above)"
elif [ "$cfg_rc" -ne 0 ]; then
  fail "the config scan exited $cfg_rc (above)"
fi

say ""
if [ "$FAIL" -ne 0 ]; then
  if [ "${TRIVY_REPORT_ONLY:-0}" = "1" ]; then
    say "trivy-scan REPORT-ONLY: the findings above were NOT enforced (TRIVY_REPORT_ONLY=1)."
    note "this exists for one evidence-gathering pass. Unset it as soon as they are triaged."
    exit 0
  fi
  say "trivy-scan FAILED ($FAIL surface(s))."
  note "fix by bumping the base image or the dependency, not by adding to .trivyignore"
  note "if a finding genuinely does not apply, add it there WITH a reason and say why in the PR"
  exit 1
fi
say "trivy-scan OK: no $SEVERITY vulnerabilities with a fix, no $SEVERITY misconfigurations."
