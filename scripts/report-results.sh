#!/usr/bin/env bash
# report-results.sh — Enrich qualitySummary with Sonar measures (if a scan ran),
# then POST the assembled CiResultsRequest to {runId}/results.
#
# Sonar measures are fetched with the same endpoints/metric keys the eac backend
# buildspec uses (api/measures/component, api/qualitygates/project_status,
# api/issues/search) and mapped onto QualitySummary.sonar* fields.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

: "${RUNTIMEZ_URL:?runtimez-url input is required}"
: "${RUNTIMEZ_TOKEN:?token input is required}"

RUN_ID="${RUN_ID:-}"
if [ -z "$RUN_ID" ] && [ -f "${RZ_WORK}/run-id" ]; then
  RUN_ID="$(cat "${RZ_WORK}/run-id")"
fi
: "${RUN_ID:?runId not available — report-start step must run first}"

RESULTS="${RZ_WORK}/results.json"
[ -f "$RESULTS" ] || { echo '{"testSummary":{"total":0,"passed":0,"failed":0,"skipped":0,"durationMs":0}}' > "$RESULTS"; }

SONAR_HOST_URL="${SONAR_HOST_URL:-https://sonar.runtimez.io}"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-}"
ANALYSIS_ID=""
[ -f "${RZ_WORK}/sonar-analysis-id" ] && ANALYSIS_ID="$(cat "${RZ_WORK}/sonar-analysis-id")"

MEASURES_JSON="${RZ_WORK}/sonar-measures.json"
QG_JSON="${RZ_WORK}/sonar-qg.json"
BUGS_JSON="${RZ_WORK}/sonar-bugs.json"
echo '{}' > "$MEASURES_JSON"; echo '{}' > "$QG_JSON"; echo '{}' > "$BUGS_JSON"

# Fetch Sonar measures only if we have a project key + token (a scan that produced
# an analysisId implies the project exists). Token may be reused from the scan env.
if [ -n "$SONAR_PROJECT_KEY" ] && [ -n "${SONAR_TOKEN:-}" ]; then
  echo "[runtimez] Fetching Sonar measures for ${SONAR_PROJECT_KEY} ..."
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/measures/component?component=${SONAR_PROJECT_KEY}&metricKeys=bugs,vulnerabilities,security_hotspots,code_smells,coverage,duplicated_lines_density,reliability_rating,security_rating,sqale_rating,sqale_index,tests,test_failures,test_errors,skipped_tests,test_success_density,test_execution_time,line_coverage,lines_to_cover,uncovered_lines" \
    -o "$MEASURES_JSON" 2>/dev/null || echo '{}' > "$MEASURES_JSON"
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${SONAR_PROJECT_KEY}" \
    -o "$QG_JSON" 2>/dev/null || echo '{}' > "$QG_JSON"
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/issues/search?componentKeys=${SONAR_PROJECT_KEY}&types=BUG&severities=BLOCKER,CRITICAL,MAJOR&resolved=false&ps=1&facets=severities" \
    -o "$BUGS_JSON" 2>/dev/null || echo '{}' > "$BUGS_JSON"
fi

BODY_FILE="${RZ_WORK}/results-final.json"

RESULTS="$RESULTS" MEASURES_JSON="$MEASURES_JSON" QG_JSON="$QG_JSON" BUGS_JSON="$BUGS_JSON" \
SONAR_PROJECT_KEY="$SONAR_PROJECT_KEY" SONAR_HOST_URL="$SONAR_HOST_URL" \
SONAR_ANALYSIS_ID="$ANALYSIS_ID" OUT="$BODY_FILE" \
python3 - <<'PY'
import os, json

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception:
        return {}

body = load(os.environ["RESULTS"])
measures = load(os.environ["MEASURES_JSON"])
qg = load(os.environ["QG_JSON"])
bugs = load(os.environ["BUGS_JSON"])
project_key = os.environ.get("SONAR_PROJECT_KEY", "")
host = os.environ.get("SONAR_HOST_URL", "")
analysis_id = os.environ.get("SONAR_ANALYSIS_ID", "")

quality = body.get("qualitySummary") or {}

def m(key):
    for x in (measures.get("component", {}).get("measures") or []):
        if x.get("metric") == key:
            return x.get("value")
    return None

def as_int(v):
    try: return int(float(v)) if v not in (None, "") else None
    except (TypeError, ValueError): return None

def as_float(v):
    try: return float(v) if v not in (None, "") else None
    except (TypeError, ValueError): return None

def facet(sev):
    for f in (bugs.get("facets") or []):
        if f.get("property") == "severities":
            for val in (f.get("values") or []):
                if val.get("val") == sev:
                    return val.get("count", 0)
    return None

if project_key:
    quality["sonarProjectKey"] = project_key
    quality["sonarDashboardUrl"] = f"{host}/dashboard?id={project_key}"
if analysis_id:
    quality["sonarAnalysisId"] = analysis_id

# Only attach Sonar metric fields when a measures payload was actually returned.
if measures.get("component"):
    quality["sonarBugs"] = as_int(m("bugs"))
    quality["sonarVulnerabilities"] = as_int(m("vulnerabilities"))
    quality["sonarSecurityHotspots"] = as_int(m("security_hotspots"))
    quality["sonarCodeSmells"] = as_int(m("code_smells"))
    quality["sonarCoverage"] = as_float(m("coverage"))
    quality["sonarDuplications"] = as_float(m("duplicated_lines_density"))
    quality["sonarReliabilityRating"] = m("reliability_rating")
    quality["sonarSecurityRating"] = m("security_rating")
    quality["sonarMaintainabilityRating"] = m("sqale_rating")
    quality["sonarTechnicalDebtMinutes"] = as_int(m("sqale_index"))
    quality["sonarTests"] = as_int(m("tests"))
    quality["sonarTestFailures"] = as_int(m("test_failures"))
    quality["sonarTestErrors"] = as_int(m("test_errors"))
    quality["sonarTestsSkipped"] = as_int(m("skipped_tests"))
    quality["sonarTestSuccessDensity"] = as_float(m("test_success_density"))
    quality["sonarTestExecutionTimeMs"] = as_int(m("test_execution_time"))
    quality["sonarLineCoverage"] = as_float(m("line_coverage"))
    quality["sonarLinesToCover"] = as_int(m("lines_to_cover"))
    quality["sonarUncoveredLines"] = as_int(m("uncovered_lines"))
    quality["sonarBugsBlocker"] = facet("BLOCKER")
    quality["sonarBugsCritical"] = facet("CRITICAL")
    quality["sonarBugsMajor"] = facet("MAJOR")

status = (qg.get("projectStatus") or {}).get("status")
if status:
    quality["sonarQualityGate"] = status
    quality["qualityGateResult"] = status
    reasons = []
    for c in ((qg.get("projectStatus") or {}).get("conditions") or []):
        if c.get("status") == "ERROR":
            reasons.append(f"{c.get('metricKey')} {c.get('comparator','')} {c.get('errorThreshold','')} (actual {c.get('actualValue','')})".strip())
    if reasons:
        quality["gateFailureReasons"] = reasons

# Drop null values so the backend keeps its own defaults.
quality = {k: v for k, v in quality.items() if v is not None}
body["qualitySummary"] = quality

with open(os.environ["OUT"], "w") as f:
    json.dump(body, f)
PY

echo "[runtimez] Reporting results for run ${RUN_ID} ..."
rz_post "${RUNTIMEZ_URL%/}/eac/api/ci/runs/${RUN_ID}/results" "$BODY_FILE" >/dev/null
echo "[runtimez] Results accepted for run ${RUN_ID}."
