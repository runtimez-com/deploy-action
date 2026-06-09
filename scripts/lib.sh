#!/usr/bin/env bash
# lib.sh — shared helpers sourced by every step script.
# Not executed directly. Provides:
#   - RZ_WORK: a per-run scratch dir under $RUNNER_TEMP (falls back to /tmp) that
#     threads parsed artifacts (results.json fragments) between steps.
#   - rz_short_sha / rz_image_ref: deterministic image naming.
#   - rz_post: POST JSON to the control plane with bearer auth; fail on non-2xx.
set -euo pipefail

# Per-run scratch directory shared across composite steps. Stable for one job.
RZ_WORK="${RUNNER_TEMP:-/tmp}/runtimez-deploy-action"
mkdir -p "$RZ_WORK"
export RZ_WORK

# Short git sha used as the image tag. Falls back to "latest" outside Actions.
rz_short_sha() {
  local sha="${GITHUB_SHA:-}"
  if [ -n "$sha" ]; then
    printf '%s' "${sha:0:12}"
  else
    printf '%s' "latest"
  fi
}

# Full image reference: <host>/<repo>:<short-sha>
rz_image_ref() {
  printf '%s/%s:%s' "${REGISTRY_HOST}" "${IMAGE_REPO}" "$(rz_short_sha)"
}

# rz_post <url> <json-file> — POST JSON with bearer auth.
# Echoes the response body to stdout. Exits non-zero (printing the body) on any
# non-2xx response from the control plane.
rz_post() {
  local url="$1" body_file="$2"
  local resp_file http_code
  resp_file="$(mktemp "${RZ_WORK}/resp.XXXXXX")"

  http_code="$(curl -sS -o "$resp_file" -w '%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Bearer ${RUNTIMEZ_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${body_file}" || echo "000")"

  if [ "${http_code:0:1}" != "2" ]; then
    echo "::error::runtimez control plane returned HTTP ${http_code} for POST ${url}" >&2
    echo "--- response body ---" >&2
    cat "$resp_file" >&2 || true
    echo "" >&2
    rm -f "$resp_file"
    exit 1
  fi

  cat "$resp_file"
  rm -f "$resp_file"
}
