#!/usr/bin/env bash
# Build and push the easyworker Android (emulator) sandbox image.
#
#   ./images/android/build.sh [aosp|gms]        # default: aosp
#   FLAVOR=gms TAG=v1.2.0-gms ./images/android/build.sh
#
# RUN-ONLY: the image ships the official Android emulator, a system image, adb
# and the screen bridge — no JDK/Gradle/build-tools/cmdline-tools. Build the
# APK elsewhere, push it with FileWrite, install it with adb.
#
# Flavors (one Containerfile, SYSTEM_IMAGE picks the guest):
#   aosp -> system-images;android-35;default;x86_64       (no GMS)
#   gms  -> system-images;android-35;google_apis;x86_64   (GMS, no Play Store)
#
# Prerequisites:
#   * dist/easyworker-linux-amd64    (scripts/build-all.sh)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

FLAVOR="${1:-${FLAVOR:-aosp}}"
case "$FLAVOR" in
  aosp) SYSTEM_IMAGE="system-images;android-35;default;x86_64" ;;
  gms)  SYSTEM_IMAGE="system-images;android-35;google_apis;x86_64" ;;
  *) echo "unknown flavor '$FLAVOR' (want aosp|gms)" >&2; exit 2 ;;
esac

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-root}"
NAME="${NAME:-easyworker-android}"
TAG="${TAG:-v1.2.0-$FLAVOR}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/easyworker-linux-amd64}"

for f in "${DIR}/Containerfile" "${DIR}/entrypoint.sh" \
         "${DIR}/bridge/server.js" "${DIR}/bridge/index.html" "${DIR}/bridge/jmuxer.min.js" \
         "${WORKER_BIN}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done

BUILDCTL="${BUILDCTL:-$(command -v buildctl || echo /opt/tools/mise/installs/aqua-moby-buildkit/0.32.2/bin/buildctl)}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
cp "${DIR}/entrypoint.sh" "${WORK}/"
mkdir -p "${WORK}/bridge"
cp "${DIR}/bridge/server.js" "${DIR}/bridge/index.html" "${DIR}/bridge/jmuxer.min.js" "${WORK}/bridge/"
cp "${WORKER_BIN}" "${WORK}/easyworker"

echo "Building ${NAME}:${TAG} (flavor=${FLAVOR}, buildkitd=${BUILDKIT})"
echo "  system image: ${SYSTEM_IMAGE}"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:REGISTRY=${REGISTRY}/root" \
  --opt "build-arg:SYSTEM_IMAGE=${SYSTEM_IMAGE}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --output "type=oci,dest=${WORK}/image.oci,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
mkdir -p "${WORK}/oci" && tar -xf "${WORK}/image.oci" -C "${WORK}/oci"
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
  --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "oci:${WORK}/oci" "docker://${DEST}"

echo "Verifying push:"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  --tls-verify=false "docker://${DEST}" >/dev/null 2>&1 \
  && echo "OK ${DEST}" \
  || echo "inspect failed for ${DEST} (image may still be present)"
