#!/usr/bin/env bash
# report-start.sh — POST {runtimez-url}/eac/api/ci/runs to open a build run.
# Body: { gitSha, branch, ghRunUrl }  (matches CiRunRequest).
# Captures the returned runId to $GITHUB_OUTPUT and to $RZ_WORK/run-id.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

: "${RUNTIMEZ_URL:?runtimez-url input is required}"
: "${RUNTIMEZ_TOKEN:?token input is required}"

GIT_SHA="${GITHUB_SHA:-}"
BRANCH="${GITHUB_REF_NAME:-}"
GH_RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

BODY_FILE="$(mktemp "${RZ_WORK}/run-req.XXXXXX")"
python3 - "$GIT_SHA" "$BRANCH" "$GH_RUN_URL" > "$BODY_FILE" <<'PY'
import json, sys
git_sha, branch, gh_run_url = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"gitSha": git_sha, "branch": branch, "ghRunUrl": gh_run_url}))
PY

echo "[runtimez] Opening run: gitSha=${GIT_SHA} branch=${BRANCH}"
RESP="$(rz_post "${RUNTIMEZ_URL%/}/eac/api/ci/runs" "$BODY_FILE")"

# ApiResponse envelope: { success, data: { runId } }
RUN_ID="$(printf '%s' "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("data") or {}).get("runId",""))')"
if [ -z "$RUN_ID" ]; then
  echo "::error::Control plane did not return a runId. Response: ${RESP}" >&2
  exit 1
fi

echo "[runtimez] runId=${RUN_ID}"
printf '%s' "$RUN_ID" > "${RZ_WORK}/run-id"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "runId=${RUN_ID}" >> "$GITHUB_OUTPUT"
fi
