#!/usr/bin/env bash
# push.sh — docker login to the customer registry, then push the built image.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

: "${REGISTRY_HOST:?registry-host input is required}"
: "${REGISTRY_USERNAME:?registry-username input is required}"
: "${REGISTRY_PASSWORD:?registry-password input is required}"

REF="${IMAGE_REF:-}"
if [ -z "$REF" ] && [ -f "${RZ_WORK}/image-ref" ]; then
  REF="$(cat "${RZ_WORK}/image-ref")"
fi
: "${REF:?image reference not available — build step must run first}"

echo "[runtimez] docker login ${REGISTRY_HOST} ..."
printf '%s' "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" \
  --username "${REGISTRY_USERNAME}" --password-stdin

echo "[runtimez] docker push ${REF} ..."
docker push "${REF}"
echo "[runtimez] Pushed ${REF}"
