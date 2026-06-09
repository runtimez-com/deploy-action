#!/usr/bin/env bash
# parse-results.sh — Assemble the CiResultsRequest body from JUnit XML, coverage
# XML, the raw Trivy report, and Sonar measures. Writes $RZ_WORK/results.json
# which report-results.sh POSTs verbatim.
#
# Field names map 1:1 to the backend DTOs:
#   testSummary     -> KubeDeploymentRunDocument.TestSummary
#                       {total, passed, failed, skipped, durationMs}
#   coverageSummary -> KubeDeploymentRunDocument.CoverageSummary
#                       {lineCoveragePercent, linesCovered, linesMissed,
#                        branchCoveragePercent, branchesCovered, branchesMissed}
#   qualitySummary  -> KubeDeploymentRunDocument.QualitySummary
#                       (sonar* fields + vulnCritical/vulnHigh/vulnTotal/vulnIds + gate)
#   testCases       -> raw parsed JUnit test-cases (list)
#   coverageFiles   -> raw parsed per-file coverage (list)
#   trivyReport     -> raw Trivy JSON
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

JUNIT_GLOBS="${RZ_WORK}/junit-globs"
COVERAGE_PATH_FILE="${RZ_WORK}/coverage-path"
TRIVY_JSON="${RZ_WORK}/trivy.json"
OUT="${RZ_WORK}/results.json"

# Resolve JUnit XML files from recorded globs (may be empty -> zero tests).
JUNIT_FILES=()
if [ -f "$JUNIT_GLOBS" ]; then
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    for f in $g; do [ -f "$f" ] && JUNIT_FILES+=("$f"); done
  done < "$JUNIT_GLOBS"
fi

COVERAGE_FILE=""
if [ -f "$COVERAGE_PATH_FILE" ]; then
  c="$(cat "$COVERAGE_PATH_FILE")"
  [ -n "$c" ] && [ -f "$c" ] && COVERAGE_FILE="$c"
fi

[ -f "$TRIVY_JSON" ] || echo '{}' > "$TRIVY_JSON"

echo "[runtimez] Parsing ${#JUNIT_FILES[@]} JUnit file(s); coverage='${COVERAGE_FILE:-none}'."

JUNIT_LIST="$(printf '%s\n' "${JUNIT_FILES[@]:-}")" \
COVERAGE_FILE="$COVERAGE_FILE" \
TRIVY_JSON="$TRIVY_JSON" \
OUT="$OUT" \
python3 - <<'PY'
import os, sys, json, glob
import xml.etree.ElementTree as ET

junit_files = [f for f in os.environ.get("JUNIT_LIST", "").splitlines() if f.strip()]
coverage_file = os.environ.get("COVERAGE_FILE", "").strip()
trivy_json = os.environ.get("TRIVY_JSON", "").strip()
out = os.environ["OUT"]

# ── JUnit -> TestSummary {total, passed, failed, skipped, durationMs} + testCases ──
total = failed = skipped = errors = 0
duration_s = 0.0
test_cases = []
for f in junit_files:
    try:
        root = ET.parse(f).getroot()
    except Exception:
        continue
    suites = [root] if root.tag == "testsuite" else root.iter("testsuite")
    for ts in suites:
        for tc in ts.iter("testcase"):
            total += 1
            t = tc.get("time")
            try:
                dur = float(t) if t else 0.0
            except ValueError:
                dur = 0.0
            duration_s += dur
            fail = tc.find("failure") is not None
            err = tc.find("error") is not None
            skip = tc.find("skipped") is not None
            status = "passed"
            if fail:
                failed += 1; status = "failed"
            elif err:
                errors += 1; status = "error"
            elif skip:
                skipped += 1; status = "skipped"
            test_cases.append({
                "name": tc.get("name", ""),
                "classname": tc.get("classname", ""),
                "time": dur,
                "status": status,
            })

# Backend TestSummary has no "errors" field — fold errors into failed.
failed_total = failed + errors
passed = total - failed_total - skipped
if passed < 0:
    passed = 0

test_summary = {
    "total": total,
    "passed": passed,
    "failed": failed_total,
    "skipped": skipped,
    "durationMs": int(round(duration_s * 1000)),
}

# ── Coverage -> CoverageSummary + coverageFiles ──────────────────────────────
coverage_summary = None
coverage_files = []

def pct(covered, total_):
    return round(100.0 * covered / total_, 2) if total_ else None

if coverage_file:
    try:
        root = ET.parse(coverage_file).getroot()
    except Exception:
        root = None
    if root is not None:
        tag = root.tag.lower()
        if tag == "report":
            # JaCoCo: <report><counter type="LINE" covered="" missed=""/>
            def jacoco_counter(node, ctype):
                for c in node.findall("counter"):
                    if c.get("type") == ctype:
                        return int(c.get("covered", 0)), int(c.get("missed", 0))
                return 0, 0
            lc, lm = jacoco_counter(root, "LINE")
            bc, bm = jacoco_counter(root, "BRANCH")
            coverage_summary = {
                "lineCoveragePercent": pct(lc, lc + lm),
                "linesCovered": lc,
                "linesMissed": lm,
                "branchCoveragePercent": pct(bc, bc + bm),
                "branchesCovered": bc,
                "branchesMissed": bm,
            }
            for pkg in root.iter("package"):
                for sf in pkg.findall("sourcefile"):
                    flc, flm = jacoco_counter(sf, "LINE")
                    coverage_files.append({
                        "path": sf.get("name", ""),
                        "linesCovered": flc,
                        "linesMissed": flm,
                        "lineCoveragePercent": pct(flc, flc + flm),
                    })
        elif tag == "coverage":
            # Cobertura: line-rate/branch-rate + <lines-valid>/<lines-covered>
            def to_int(v):
                try: return int(v)
                except (TypeError, ValueError): return 0
            def to_float(v):
                try: return float(v)
                except (TypeError, ValueError): return 0.0
            lines_valid = to_int(root.get("lines-valid"))
            lines_covered = to_int(root.get("lines-covered"))
            line_rate = to_float(root.get("line-rate"))
            branch_rate = to_float(root.get("branch-rate"))
            branches_valid = to_int(root.get("branches-valid"))
            branches_covered = to_int(root.get("branches-covered"))
            if lines_valid == 0:
                # Derive by counting <line> elements if attributes absent.
                covered = missed = 0
                for ln in root.iter("line"):
                    if to_int(ln.get("hits")) > 0: covered += 1
                    else: missed += 1
                lines_covered, lines_valid = covered, covered + missed
            lines_missed = max(lines_valid - lines_covered, 0)
            branches_missed = max(branches_valid - branches_covered, 0)
            coverage_summary = {
                "lineCoveragePercent": round(line_rate * 100, 2) if line_rate else pct(lines_covered, lines_valid),
                "linesCovered": lines_covered,
                "linesMissed": lines_missed,
                "branchCoveragePercent": round(branch_rate * 100, 2) if branch_rate else pct(branches_covered, branches_valid),
                "branchesCovered": branches_covered,
                "branchesMissed": branches_missed,
            }
            for cls in root.iter("class"):
                clines = list(cls.iter("line"))
                cov = sum(1 for ln in clines if to_int(ln.get("hits")) > 0)
                coverage_files.append({
                    "path": cls.get("filename", ""),
                    "linesCovered": cov,
                    "linesMissed": max(len(clines) - cov, 0),
                    "lineCoveragePercent": pct(cov, len(clines)),
                })

# ── Trivy -> vulnCritical / vulnHigh / vulnTotal / vulnIds ───────────────────
vuln_crit = vuln_high = vuln_total = 0
vuln_ids = []
trivy_report = {}
try:
    with open(trivy_json) as fh:
        trivy_report = json.load(fh)
except Exception:
    trivy_report = {}
for res in (trivy_report.get("Results") or []):
    for v in (res.get("Vulnerabilities") or []):
        vuln_total += 1
        sev = (v.get("Severity") or "").upper()
        if sev == "CRITICAL": vuln_crit += 1
        elif sev == "HIGH": vuln_high += 1
        vid = v.get("VulnerabilityID")
        if vid and vid not in vuln_ids:
            vuln_ids.append(vid)

quality_summary = {
    "vulnCritical": vuln_crit,
    "vulnHigh": vuln_high,
    "vulnTotal": vuln_total,
    "vulnIds": vuln_ids,
}

body = {
    "testSummary": test_summary,
    "coverageSummary": coverage_summary,
    "qualitySummary": quality_summary,
    "testCases": test_cases,
    "coverageFiles": coverage_files,
    "trivyReport": trivy_report,
}
with open(out, "w") as fh:
    json.dump(body, fh)

print(f"[runtimez] tests total={total} passed={passed} failed={failed_total} skipped={skipped}; "
      f"vulns total={vuln_total} crit={vuln_crit} high={vuln_high}", file=sys.stderr)
PY

echo "[runtimez] Wrote ${OUT}"
