#!/usr/bin/env bash
# Build and push the easyworker macOS (Sequoia) VM image.
#
#   ./images/macos/build.sh
#
# The image is a thin wrapper around a pre-baked guest disk: the quality of the
# image therefore depends entirely on the golden qcow2 handed in here. Supply a
# *defragged* disk (uncompressed 1 MiB clusters) or the OCI layer will not
# compress — see repack-disk.sh for the numbers and the extra shrink step.
#
# Expected layout (all git-ignored, staged outside the repo):
#   images/macos/golden.qcow2           the guest disk
#   images/macos/support/               dockur boot files (OpenCore/OVMF/...)
#
# Prerequisites:
#   * dist/easyworker-linux-amd64 + dist/easyworker-darwin-amd64
#     (scripts/build-all.sh; darwin is the guest-side binary)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

REGISTRY="${REGISTRY:-forgejo.develop.10.199.64.20.nip.io}"
NAMESPACE="${NAMESPACE:-root}"
NAME="${NAME:-easyworker-macos}"
TAG="${TAG:-v1.5.0-base}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.temp.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
GOLDEN="${GOLDEN:-${DIR}/golden.qcow2}"
SUPPORT="${SUPPORT:-${DIR}/support}"
LINUX_BIN="${LINUX_BIN:-${ROOT}/dist/easyworker-linux-amd64}"
DARWIN_BIN="${DARWIN_BIN:-${ROOT}/dist/easyworker-darwin-amd64}"
BUILDCTL="${BUILDCTL:-$(command -v buildctl || true)}"

for f in "${DIR}/Dockerfile" "${DIR}/00-token.conf" "${DIR}/start.sh" \
         "${GOLDEN}" "${LINUX_BIN}" "${DARWIN_BIN}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -d "${SUPPORT}" ] || { echo "missing support dir ${SUPPORT}" >&2; exit 1; }
[ -n "${BUILDCTL}" ] || { echo "buildctl not found (set BUILDCTL)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/disk"
cp "${DIR}/Dockerfile" "${DIR}/00-token.conf" "${DIR}/start.sh" "${WORK}/"
cp "${LINUX_BIN}"  "${WORK}/easyworker-linux"
cp "${DARWIN_BIN}" "${WORK}/easyworker-darwin"
ln "${GOLDEN}" "${WORK}/disk/data.qcow2" 2>/dev/null || cp "${GOLDEN}" "${WORK}/disk/data.qcow2"
cp -r "${SUPPORT}" "${WORK}/disk/support"

echo "Building ${NAME} -> ${DEST} (buildkitd=${BUILDKIT})"
echo "  disk: $(du -h "${WORK}/disk/data.qcow2" | cut -f1)"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
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

echo
echo "Next: defrag + repack to shrink the disk layer:"
echo "  qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M golden.qcow2 golden.defrag.qcow2"
echo "  ./images/macos/repack-disk.sh <kind> golden.defrag.qcow2 ${TAG} <newtag>"
