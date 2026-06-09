#!/usr/bin/env bash
# test.sh — Auto-detect the project type and run tests + coverage.
# Emits JUnit XML and coverage XML into well-known paths under $RZ_WORK so
# parse-results.sh can read them. A TEST_COMMAND override replaces detection.
# Never aborts the pipeline on test failure — results are reported to the control
# plane; the build proceeds so the dashboard records the failing run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

JUNIT_GLOBS="${RZ_WORK}/junit-globs"   # newline-separated list of globs for parse-results
COVERAGE_FILE="${RZ_WORK}/coverage-path"  # single coverage XML path for parse-results
: > "$JUNIT_GLOBS"
: > "$COVERAGE_FILE"

record_junit() { echo "$1" >> "$JUNIT_GLOBS"; }
record_coverage() { printf '%s' "$1" > "$COVERAGE_FILE"; }

run() {
  echo "[runtimez] + $*"
  # Do not let a non-zero test exit kill the composite step.
  set +e
  bash -c "$*"
  local rc=$?
  set -e
  echo "[runtimez] test command exit code: ${rc}"
  return 0
}

if [ -n "${TEST_COMMAND:-}" ]; then
  echo "[runtimez] Using test-command override."
  run "${TEST_COMMAND}"
  # Best-effort discovery of common output locations for the override case.
  record_junit "target/surefire-reports/*.xml"
  record_junit "build/test-results/test/*.xml"
  record_junit "junit.xml"
  record_junit "**/junit*.xml"
  record_coverage "target/site/jacoco/jacoco.xml"
elif [ -f "pom.xml" ]; then
  echo "[runtimez] Detected Maven (pom.xml)."
  run "mvn -B test org.jacoco:jacoco-maven-plugin:report"
  record_junit "target/surefire-reports/TEST-*.xml"
  record_coverage "target/site/jacoco/jacoco.xml"
elif ls build.gradle build.gradle.kts >/dev/null 2>&1; then
  echo "[runtimez] Detected Gradle (build.gradle*)."
  run "./gradlew test jacocoTestReport"
  record_junit "build/test-results/test/TEST-*.xml"
  record_coverage "build/reports/jacoco/test/jacocoTestReport.xml"
elif [ -f "package.json" ]; then
  echo "[runtimez] Detected Node (package.json)."
  # jest-junit -> junit.xml ; jest cobertura -> coverage/cobertura-coverage.xml
  run "npm ci && JEST_JUNIT_OUTPUT_FILE=junit.xml npm test -- --coverage --coverageReporters=cobertura --reporters=default --reporters=jest-junit"
  record_junit "junit.xml"
  record_coverage "coverage/cobertura-coverage.xml"
elif [ -f "go.mod" ]; then
  echo "[runtimez] Detected Go (go.mod)."
  run "go test -json -coverprofile=cover.out ./... | go-junit-report -set-exit-code > go-junit.xml || true"
  run "gocover-cobertura < cover.out > coverage.xml || true"
  record_junit "go-junit.xml"
  record_coverage "coverage.xml"
elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ]; then
  echo "[runtimez] Detected Python (pyproject.toml/requirements.txt)."
  [ -f "requirements.txt" ] && run "pip install -r requirements.txt"
  run "pytest --junitxml=pytest-junit.xml --cov --cov-report=xml:coverage.xml"
  record_junit "pytest-junit.xml"
  record_coverage "coverage.xml"
else
  echo "[runtimez] No recognized project files — recording zero tests, continuing."
fi
