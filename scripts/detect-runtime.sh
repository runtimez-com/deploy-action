#!/usr/bin/env bash
# detect-runtime.sh — Detect the app's language + runtime version from project
# files at the repo root, and:
#   1. Emit lang / *_version keys to $GITHUB_OUTPUT so action.yml can gate the
#      matching `actions/setup-*` step (installs the runtime on the runner so the
#      `mvn`/`npm`/`pytest`/`go` test step uses it).
#   2. Export BP_* build env to $GITHUB_ENV so the Paketo buildpack installs the
#      matching runtime inside the `pack build`.
#
# Defensive by design: detection never fails the job. If a version can't be
# parsed we fall back to a sane default and continue. If nothing matches,
# lang=unknown with blank versions.
set -uo pipefail

# --- output sinks (fall back to /dev/null outside Actions) -------------------
GH_OUT="${GITHUB_OUTPUT:-/dev/null}"
GH_ENV="${GITHUB_ENV:-/dev/null}"

emit_out() { echo "$1=$2" >> "$GH_OUT"; }
emit_env() { echo "$1=$2" >> "$GH_ENV"; }

LANG="unknown"
JAVA_VERSION=""
NODE_VERSION=""
PYTHON_VERSION=""
GO_VERSION=""

# Strip a leading "1." (1.8 -> 8) and keep only the leading integer.
norm_major() {
  local v="$1"
  v="${v#1.}"            # 1.8 -> 8 ; 1.21 -> 21 ; 21 -> 21
  # keep only leading digits (e.g. "17.0.2" -> "17", "20.x" -> "20")
  v="$(printf '%s' "$v" | grep -oE '^[0-9]+' || true)"
  printf '%s' "$v"
}

# Extract the text of the FIRST matching XML element from a file. Tolerant of
# whitespace; ignores namespaces. Echoes empty string if not found.
xml_first() {
  local file="$1" tag="$2"
  grep -oE "<${tag}>[^<]*</${tag}>" "$file" 2>/dev/null \
    | head -n1 \
    | sed -E "s#<${tag}>([^<]*)</${tag}>#\1#" \
    | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Java: pom.xml or build.gradle*
# ---------------------------------------------------------------------------
detect_java() {
  local v=""
  if [ -f "pom.xml" ]; then
    v="$(xml_first pom.xml 'maven.compiler.release')"
    [ -z "$v" ] && v="$(xml_first pom.xml 'java.version')"
    [ -z "$v" ] && v="$(xml_first pom.xml 'maven.compiler.target')"
    # <release> inside the compiler plugin config
    [ -z "$v" ] && v="$(xml_first pom.xml 'release')"
  fi
  if [ -z "$v" ]; then
    local gradle=""
    for f in build.gradle build.gradle.kts; do
      [ -f "$f" ] && gradle="$f" && break
    done
    if [ -n "$gradle" ]; then
      # sourceCompatibility / targetCompatibility = '17' | JavaVersion.VERSION_17 | "17"
      v="$(grep -oE '(source|target)Compatibility[[:space:]]*=?[[:space:]]*[^ ]*' "$gradle" 2>/dev/null \
            | head -n1 \
            | grep -oE '(VERSION_)?[0-9]+(\.[0-9]+)?' | tail -n1 | sed 's/VERSION_//')"
      # languageVersion = JavaLanguageVersion.of(17) | languageVersion.set(...)
      [ -z "$v" ] && v="$(grep -oE 'languageVersion[^0-9]*[0-9]+' "$gradle" 2>/dev/null \
            | head -n1 | grep -oE '[0-9]+' | tail -n1)"
    fi
  fi
  v="$(norm_major "$v")"
  [ -z "$v" ] && v="21"
  JAVA_VERSION="$v"
  LANG="java"
}

# ---------------------------------------------------------------------------
# Node: package.json (engines.node) or .nvmrc
# ---------------------------------------------------------------------------
detect_node() {
  local v=""
  if [ -f "package.json" ] && command -v python3 >/dev/null 2>&1; then
    v="$(python3 -c '
import json,sys
try:
    d=json.load(open("package.json"))
    print((d.get("engines",{}) or {}).get("node","") or "")
except Exception:
    print("")
' 2>/dev/null)"
  fi
  if [ -z "$v" ] && [ -f "package.json" ]; then
    # Fallback without python: grep engines.node line
    v="$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]*"' package.json 2>/dev/null \
          | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  fi
  if [ -z "$v" ] && [ -f ".nvmrc" ]; then
    v="$(head -n1 .nvmrc 2>/dev/null)"
  fi
  # strip ^ >= > v ~ and whitespace, take the major
  v="$(printf '%s' "$v" | sed -E 's/[\^~]|>=|<=|>|<|=|v//g' | tr -d '[:space:]')"
  v="$(printf '%s' "$v" | grep -oE '^[0-9]+' || true)"
  [ -z "$v" ] && v="20"
  NODE_VERSION="$v"
  LANG="node"
}

# ---------------------------------------------------------------------------
# Python: .python-version, pyproject.toml (requires-python), runtime.txt
# ---------------------------------------------------------------------------
detect_python() {
  local v=""
  if [ -f ".python-version" ]; then
    v="$(head -n1 .python-version 2>/dev/null)"
  fi
  if [ -z "$v" ] && [ -f "pyproject.toml" ]; then
    v="$(grep -oE 'requires-python[[:space:]]*=[[:space:]]*"[^"]*"' pyproject.toml 2>/dev/null \
          | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  fi
  if [ -z "$v" ] && [ -f "runtime.txt" ]; then
    # heroku-style: python-3.12.2
    v="$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' runtime.txt 2>/dev/null | head -n1)"
  fi
  # keep major.minor (3.12)
  v="$(printf '%s' "$v" | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -z "$v" ] && v="3.12"
  PYTHON_VERSION="$v"
  LANG="python"
}

# ---------------------------------------------------------------------------
# Go: go.mod (go 1.xx)
# ---------------------------------------------------------------------------
detect_go() {
  local v=""
  if [ -f "go.mod" ]; then
    v="$(grep -oE '^go[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?' go.mod 2>/dev/null \
          | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
  fi
  [ -z "$v" ] && v="1.22"
  GO_VERSION="$v"
  LANG="go"
}

# --- detection priority -----------------------------------------------------
# Java and Node are the common buildpack targets; check by presence of the
# canonical manifest. First match wins.
if [ -f "pom.xml" ] || ls build.gradle build.gradle.kts >/dev/null 2>&1; then
  detect_java
elif [ -f "package.json" ] || [ -f ".nvmrc" ]; then
  detect_node
elif [ -f ".python-version" ] || [ -f "pyproject.toml" ] || [ -f "runtime.txt" ] || [ -f "requirements.txt" ]; then
  detect_python
elif [ -f "go.mod" ]; then
  detect_go
fi

# --- emit GITHUB_OUTPUT -----------------------------------------------------
emit_out "lang" "$LANG"
emit_out "java_version" "$JAVA_VERSION"
emit_out "node_version" "$NODE_VERSION"
emit_out "python_version" "$PYTHON_VERSION"
emit_out "go_version" "$GO_VERSION"

# --- emit BP_* build env for the buildpack ----------------------------------
case "$LANG" in
  java)   [ -n "$JAVA_VERSION" ]   && emit_env "BP_JVM_VERSION"     "$JAVA_VERSION" ;;
  node)   [ -n "$NODE_VERSION" ]   && emit_env "BP_NODE_VERSION"    "$NODE_VERSION" ;;
  python) [ -n "$PYTHON_VERSION" ] && emit_env "BP_CPYTHON_VERSION" "$PYTHON_VERSION" ;;
  go)     [ -n "$GO_VERSION" ]     && emit_env "BP_GO_VERSION"      "$GO_VERSION" ;;
esac

echo "[runtimez] detected lang=${LANG} java=${JAVA_VERSION} node=${NODE_VERSION} python=${PYTHON_VERSION} go=${GO_VERSION}"
