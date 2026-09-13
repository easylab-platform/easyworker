#!/usr/bin/env bash
# Build and push the easyworker Linux labwc desktop sandbox image.
#
#   ./images/linux-desktop/build.sh
#
# Stages the linux/amd64 worker binary (dist/ or WORKER_BIN) plus the image
# files into a temporary build context, then builds via the shared in-cluster
# buildkitd and pushes to forgejo. Mirrors build-image.sh conventions.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

REGISTRY="${REGISTRY:-forgejo.develop.10.199.64.20.nip.io}"
NAMESPACE="${NAMESPACE:-root}"
NAME="${NAME:-easyworker-linux-desktop}"
TAG="${TAG:-v1.0.0}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.temp.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/easyworker-linux-amd64}"

if [ ! -f "${WORKER_BIN}" ]; then
  echo "missing worker binary: ${WORKER_BIN}" >&2
  echo "run scripts/build-all.sh, or set WORKER_BIN=/path/to/easyworker-linux-amd64" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${DIR}/Dockerfile" "${DIR}/entrypoint.sh" "${WORK}/"
cp "${DIR}/labwc/rc.xml" "${WORK}/rc.xml"
cp "${DIR}/session-bin/gui-run" "${WORK}/gui-run"
cp "${WORKER_BIN}" "${WORK}/easyworker"

echo "Building ${NAME} -> ${DEST} (buildkitd=${BUILDKIT})"
echo "worker binary: ${WORKER_BIN} ($(stat -c%s "${WORKER_BIN}") bytes)"

# buildkitd has no registry credentials, so export a docker archive and push
# with skopeo (same flow as build-image.sh).
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
