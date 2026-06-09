#!/usr/bin/env bash
# build.sh — Build the customer image.
#   - If DOCKERFILE_PATH is set, OR a ./Dockerfile exists => docker buildx build.
#   - Otherwise => Cloud Native Buildpacks (`pack build`), which auto-detects the
#     language/runtime, so no runtime input is required.
# Exports imageRef and imageTag to $GITHUB_OUTPUT for downstream steps.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

: "${REGISTRY_HOST:?registry-host input is required}"
: "${IMAGE_REPO:?image-repo input is required}"

IMAGE_TAG="$(rz_short_sha)"
IMAGE_REF="$(rz_image_ref)"

DOCKERFILE="${DOCKERFILE_PATH:-}"
if [ -z "$DOCKERFILE" ] && [ -f "Dockerfile" ]; then
  DOCKERFILE="Dockerfile"
fi

if [ -n "$DOCKERFILE" ]; then
  echo "[runtimez] Building with Dockerfile: ${DOCKERFILE} -> ${IMAGE_REF}"
  docker buildx build -f "$DOCKERFILE" -t "$IMAGE_REF" --load .
else
  echo "[runtimez] No Dockerfile — building with buildpacks (builder=${BUILDPACK_BUILDER}) -> ${IMAGE_REF}"
  # GitHub-hosted runners don't ship the pack CLI — install it on demand.
  if ! command -v pack >/dev/null 2>&1; then
    PACK_VERSION="${PACK_VERSION:-0.35.1}"
    echo "[runtimez] pack CLI not found — installing v${PACK_VERSION} ..."
    _tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/buildpacks/pack/releases/download/v${PACK_VERSION}/pack-v${PACK_VERSION}-linux.tgz" -o "${_tmp}/pack.tgz"
    tar -xzf "${_tmp}/pack.tgz" -C "${_tmp}" pack
    if sudo -n mv "${_tmp}/pack" /usr/local/bin/pack 2>/dev/null; then
      :
    else
      mkdir -p "${HOME}/.local/bin" && mv "${_tmp}/pack" "${HOME}/.local/bin/pack" && export PATH="${HOME}/.local/bin:${PATH}"
    fi
    rm -rf "${_tmp}"
    pack version
  fi
  pack build "$IMAGE_REF" --builder "${BUILDPACK_BUILDER}"
fi

echo "[runtimez] Built ${IMAGE_REF}"
printf '%s' "$IMAGE_REF" > "${RZ_WORK}/image-ref"
printf '%s' "$IMAGE_TAG" > "${RZ_WORK}/image-tag"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "imageRef=${IMAGE_REF}" >> "$GITHUB_OUTPUT"
  echo "imageTag=${IMAGE_TAG}" >> "$GITHUB_OUTPUT"
fi
