#!/usr/bin/env bash
# Build and push the easyworker macOS (Sequoia) VM image.
#
#   ./images/macos/build.sh
#
# The image is a self-owned runtime (the generic qemux/qemu base + the vendored
# boot scripts in vendor/) wrapped around a pre-baked guest disk. Supply a
# *defragged* disk (uncompressed 1 MiB clusters) or the OCI layer will not
# compress — see repack-disk.sh.
#
# Expected layout (git-ignored, staged outside the repo):
#   images/macos/disk/data.qcow2        the guest disk
#   images/macos/disk/support/          boot.img, macos.rom/vars, identity
#
# Prerequisites: dist/easyworker-linux-amd64 + dist/easyworker-darwin-amd64.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-root}"
NAME="${NAME:-easyworker-macos}"
TAG="${TAG:-v1.7.0-base}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
DISK="${DISK:-${DIR}/disk/data.qcow2}"
SUPPORT="${SUPPORT:-${DIR}/disk/support}"
BUILDCTL="${BUILDCTL:-$(command -v buildctl || true)}"

for f in "${DIR}/Containerfile" "${DIR}/00-token.conf" "${DIR}/start.sh" "${DISK}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -d "${SUPPORT}" ] || { echo "missing support dir ${SUPPORT}" >&2; exit 1; }
[ -n "${BUILDCTL}" ] || { echo "buildctl not found (set BUILDCTL)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/disk/support"
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
cp "${DIR}/00-token.conf" "${DIR}/start.sh" "${WORK}/"
cp -r "${DIR}/vendor" "${WORK}/vendor"
ln "${DISK}" "${WORK}/disk/data.qcow2" 2>/dev/null || cp "${DISK}" "${WORK}/disk/data.qcow2"
# Boot support only; base.dmg (install media) is not shipped (see Containerfile).
for f in boot.img boot.sig macos.id macos.mac macos.mlb macos.rom macos.sn macos.vars; do
  [ -e "${SUPPORT}/$f" ] && cp -f "${SUPPORT}/$f" "${WORK}/disk/support/"
done

echo "Building ${NAME} -> ${DEST} (buildkitd=${BUILDKIT})"
echo "  disk: $(du -h "${WORK}/disk/data.qcow2" | cut -f1)"
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
