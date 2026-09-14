#!/usr/bin/env bash
# Build and push the easyworker Android (BlissOS) sandbox image.
#
#   ./images/android-blessos/build.sh
#
# Stages the linux/amd64 worker binary, the ws-scrcpy dist, and the golden
# qcow2 into a build context, then builds via the shared in-cluster buildkitd
# and pushes to forgejo. Mirrors build-image.sh conventions.
#
# Prerequisites:
#   * dist/easyworker-linux-amd64          (scripts/build-all.sh)
#   * images/android-blessos/golden.qcow2  (see golden-construct.sh)
#   * images/android-blessos/ws-scrcpy/    (npm run dist output + node_modules)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

REGISTRY="${REGISTRY:-forgejo.develop.10.199.64.20.nip.io}"
NAMESPACE="${NAMESPACE:-root}"
NAME="${NAME:-easyworker-android-blessos}"
TAG="${TAG:-v1.0.0}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.temp.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/easyworker-linux-amd64}"
GOLDEN="${GOLDEN:-${DIR}/golden.qcow2}"
WSDIST="${WSDIST:-${DIR}/ws-scrcpy}"

for f in "${WORKER_BIN}" "${GOLDEN}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${DIR}/Dockerfile" "${DIR}/entrypoint.sh" "${WORK}/"
cp "${WORKER_BIN}" "${WORK}/easyworker"
cp "${GOLDEN}" "${WORK}/golden.qcow2"
cp -a "${WSDIST}" "${WORK}/ws-scrcpy"

echo "Building ${NAME} -> ${DEST} (buildkitd=${BUILDKIT})"
buildctl --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:REGISTRY=${REGISTRY}/root" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --output "type=docker,name=${NAMESPACE}/${NAME}:${TAG},dest=${WORK}/image.tar" \
  --progress plain

echo "Pushing to forgejo ${DEST}"
skopeo copy \
  --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  --dest-tls-verify=false \
  "docker-archive:${WORK}/image.tar:${NAMESPACE}/${NAME}:${TAG}" \
  "docker://${DEST}"

echo "Verifying push:"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  --tls-verify=false "docker://${DEST}" >/dev/null 2>&1 \
  && echo "OK ${DEST}" \
  || echo "inspect failed for ${DEST} (image may still be present)"
