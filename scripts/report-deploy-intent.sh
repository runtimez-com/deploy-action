#!/usr/bin/env bash
# report-deploy-intent.sh — POST {runId}/deploy-intent with imageRef/imageTag to
# signal the control plane that the image is pushed and a rollout can be queued.
# Body matches CiDeployIntentRequest { imageRef, imageTag }.
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

IMAGE_REF="${IMAGE_REF:-}"
if [ -z "$IMAGE_REF" ] && [ -f "${RZ_WORK}/image-ref" ]; then
  IMAGE_REF="$(cat "${RZ_WORK}/image-ref")"
fi
IMAGE_TAG="${IMAGE_TAG:-}"
if [ -z "$IMAGE_TAG" ] && [ -f "${RZ_WORK}/image-tag" ]; then
  IMAGE_TAG="$(cat "${RZ_WORK}/image-tag")"
fi
: "${IMAGE_REF:?imageRef not available — build step must run first}"
: "${IMAGE_TAG:?imageTag not available — build step must run first}"

BODY_FILE="$(mktemp "${RZ_WORK}/deploy-intent.XXXXXX")"
python3 - "$IMAGE_REF" "$IMAGE_TAG" > "$BODY_FILE" <<'PY'
import json, sys
print(json.dumps({"imageRef": sys.argv[1], "imageTag": sys.argv[2]}))
PY

echo "[runtimez] Reporting deploy intent for run ${RUN_ID}: ${IMAGE_REF}"
RESP="$(rz_post "${RUNTIMEZ_URL%/}/eac/api/ci/runs/${RUN_ID}/deploy-intent" "$BODY_FILE")"
echo "[runtimez] Deploy intent accepted: ${RESP}"
