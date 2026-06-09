#!/usr/bin/env bash
# scan.sh — SCA (Trivy) + SAST (SonarQube).
#   SCA:  trivy image <ref> (falls back to trivy fs .) -> $RZ_WORK/trivy.json
#   SAST: sonar-scanner against SONAR_HOST_URL, then poll the CE task for the
#         analysisId (mirrors eac buildspec-phases/sonar/scan.sh).
# Writes:
#   $RZ_WORK/trivy.json        raw Trivy report (the trivyReport payload)
#   $RZ_WORK/sonar-analysis-id analysisId (empty if Sonar skipped/failed)
# Never aborts the pipeline — a scanner outage must not crash the build.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

TRIVY_JSON="${RZ_WORK}/trivy.json"
SONAR_ANALYSIS_ID_FILE="${RZ_WORK}/sonar-analysis-id"
echo '{}' > "$TRIVY_JSON"
: > "$SONAR_ANALYSIS_ID_FILE"

# ── SCA: Trivy ──────────────────────────────────────────────────────────────
if command -v trivy >/dev/null 2>&1; then
  REF="${IMAGE_REF:-}"
  if [ -n "$REF" ]; then
    echo "[runtimez] Trivy scanning image ${REF} ..."
    trivy image --quiet --format json --output "$TRIVY_JSON" "$REF" \
      || { echo "[runtimez] WARN: trivy image failed — falling back to fs scan"; \
           trivy fs --quiet --format json --output "$TRIVY_JSON" . || echo '{}' > "$TRIVY_JSON"; }
  else
    echo "[runtimez] Trivy fs scanning workspace ..."
    trivy fs --quiet --format json --output "$TRIVY_JSON" . || echo '{}' > "$TRIVY_JSON"
  fi
else
  echo "[runtimez] WARN: trivy not installed — skipping SCA."
fi

# ── SAST: SonarQube ─────────────────────────────────────────────────────────
SONAR_HOST_URL="${SONAR_HOST_URL:-https://sonar.runtimez.io}"
if [ -z "${SONAR_TOKEN:-}" ] || [ -z "${SONAR_PROJECT_KEY:-}" ]; then
  echo "[runtimez] sonar-token / sonar-project-key not provided — skipping SAST."
  exit 0
fi
if ! command -v sonar-scanner >/dev/null 2>&1; then
  echo "[runtimez] WARN: sonar-scanner not installed — skipping SAST."
  exit 0
fi

# Ensure project exists (idempotent — 400 on duplicate is normal).
echo "[runtimez] Ensuring Sonar project ${SONAR_PROJECT_KEY} exists ..."
CREATE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -u "${SONAR_TOKEN}:" \
  -X POST "${SONAR_HOST_URL}/api/projects/create" \
  -d "name=${SONAR_PROJECT_KEY}&project=${SONAR_PROJECT_KEY}" 2>/dev/null || echo "000")"
if [ "$CREATE_CODE" != "200" ] && [ "$CREATE_CODE" != "400" ]; then
  echo "[runtimez] WARN: project create returned ${CREATE_CODE} — scan may fail if project does not pre-exist"
fi

echo "[runtimez] Running sonar-scanner for ${SONAR_PROJECT_KEY} ..."
SCAN_EXIT=0
sonar-scanner \
  "-Dsonar.host.url=${SONAR_HOST_URL}" \
  "-Dsonar.token=${SONAR_TOKEN}" \
  "-Dsonar.projectKey=${SONAR_PROJECT_KEY}" \
  "-Dsonar.sources=." || SCAN_EXIT=$?

if [ "$SCAN_EXIT" -ne 0 ]; then
  echo "[runtimez] WARN: sonar-scanner exited ${SCAN_EXIT} — Sonar metrics will be unavailable."
  exit 0
fi

# Parse ceTaskId from the scanner work directory.
CE_TASK_ID=""
REPORT_TASK_FILE=".scannerwork/report-task.txt"
if [ -f "$REPORT_TASK_FILE" ]; then
  CE_TASK_ID="$(grep '^ceTaskId=' "$REPORT_TASK_FILE" 2>/dev/null | cut -d= -f2 || true)"
fi
if [ -z "$CE_TASK_ID" ]; then
  echo "[runtimez] WARN: ceTaskId not found in ${REPORT_TASK_FILE} — skipping analysis polling."
  exit 0
fi

echo "[runtimez] Polling Sonar CE task ${CE_TASK_ID} ..."
MAX_POLLS=30
for i in $(seq 1 $MAX_POLLS); do
  TASK_JSON="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/ce/task?id=${CE_TASK_ID}" 2>/dev/null || echo '{}')"
  STATUS="$(printf '%s' "$TASK_JSON" | python3 -c 'import json,sys;print((json.load(sys.stdin).get("task") or {}).get("status","UNKNOWN"))' 2>/dev/null || echo "UNKNOWN")"
  echo "[runtimez] Sonar CE task status=${STATUS} (poll ${i}/${MAX_POLLS})"
  if [ "$STATUS" = "SUCCESS" ]; then
    ANALYSIS_ID="$(printf '%s' "$TASK_JSON" | python3 -c 'import json,sys;print((json.load(sys.stdin).get("task") or {}).get("analysisId",""))' 2>/dev/null || echo "")"
    printf '%s' "$ANALYSIS_ID" > "$SONAR_ANALYSIS_ID_FILE"
    echo "[runtimez] Sonar analysis complete. analysisId=${ANALYSIS_ID}"
    exit 0
  fi
  if [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
    echo "[runtimez] WARN: Sonar analysis ${STATUS} — metrics unavailable."
    exit 0
  fi
  sleep 10
done
echo "[runtimez] WARN: Sonar polling timed out after 5 min — proceeding without analysisId."
