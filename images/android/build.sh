#!/usr/bin/env bash
# Build and push the easyworker Android (emulator) sandbox image.
#
#   ./images/android/build.sh
#
# The image carries an Android build toolchain (JDK 21, Gradle, Android SDK)
# plus the official Android emulator and an Android 35 system image, so one job
# can build an APK and install/run it in the KVM-accelerated guest. The screen
# is shared over noVNC (see entrypoint.sh).
#
# Prerequisites:
#   * dist/easyworker-linux-amd64    (scripts/build-all.sh)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

REGISTRY="${REGISTRY:-forgejo.develop.10.199.64.20.nip.io}"
NAMESPACE="${NAMESPACE:-root}"
NAME="${NAME:-easyworker-android}"
TAG="${TAG:-v1.1.0}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.temp.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/easyworker-linux-amd64}"

for f in "${DIR}/Dockerfile" "${DIR}/entrypoint.sh" \
         "${DIR}/bridge/server.js" "${DIR}/bridge/index.html" "${DIR}/bridge/jmuxer.min.js" \
         "${DIR}/sdk-init.gradle" "${WORKER_BIN}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done

BUILDCTL="${BUILDCTL:-$(command -v buildctl || echo /opt/tools/mise/installs/aqua-moby-buildkit/0.32.2/bin/buildctl)}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${DIR}/Dockerfile" "${DIR}/entrypoint.sh" "${DIR}/sdk-init.gradle" "${WORK}/"
mkdir -p "${WORK}/bridge"
cp "${DIR}/bridge/server.js" "${DIR}/bridge/index.html" "${DIR}/bridge/jmuxer.min.js" "${WORK}/bridge/"
cp "${WORKER_BIN}" "${WORK}/easyworker"

echo "Building ${NAME} -> ${DEST} (buildkitd=${BUILDKIT})"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:REGISTRY=${REGISTRY}/root" \
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
