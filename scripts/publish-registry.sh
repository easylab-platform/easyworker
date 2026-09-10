#!/usr/bin/env bash
# Publish the cross-platform easyworker binaries to the easylab artifact
# registry (generic raw store) so consumers (easylab image builds, sandbox
# derived images, host runners) can fetch them over HTTP with no source tree.
#
#   <EASYLAB_ARTIFACT_URL>/pkgs/generic/easyworker/<version>/<filename>
#
# Reads dist/ binaries (run scripts/build-all.sh first). Uploads each platform;
# the linux/amd64 file is what easylab injects into sandbox base images.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAME="${WORKER_NAME:-easyworker}"
VERSION="${WORKER_VERSION:-v0.1.0}"
BASE="${EASYLAB_ARTIFACT_URL:-http://easylab.temp.svc.cluster.local}"
TOKEN="${ARTIFACT_TOKEN:-devtoken}"
DIR="$(pwd)"

upload() { # local-file remote-filename
  local file="$1" remote="$2"
  [ -f "$file" ] || { echo "missing $file (run scripts/build-all.sh)"; exit 1; }
  local url="${BASE%/}/pkgs/generic/${NAME}/${VERSION}/${remote}"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    --data-binary @"$file" "$url")"
  echo "  PUT ${remote} -> ${code}"
  [ "$code" = "200" ] || [ "$code" = "201" ] || exit 1
}

echo "Publishing ${NAME}@${VERSION} to ${BASE}/pkgs/generic/"
for os in linux windows darwin; do
  for arch in amd64 arm64; do
    sfx=""; [ "$os" = "windows" ] && sfx=".exe"
    upload "${DIR}/dist/easyworker-${os}-${arch}${sfx}" "easyworker-${os}-${arch}${sfx}"
  done
done
echo "Done. Verify with:"
echo "  curl -H 'Authorization: Bearer ${TOKEN}' ${BASE%/}/pkgs/generic/${NAME}/${VERSION}/easyworker-linux-amd64 -o /tmp/easyworker"
