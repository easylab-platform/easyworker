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
upload "${DIR}/dist/easyworker-linux-amd64"        "easyworker-linux-amd64"
upload "${DIR}/dist/easyworker-darwin-amd64"       "easyworker-darwin-amd64"
upload "${DIR}/dist/easyworker-darwin-arm64"       "easyworker-darwin-arm64"
upload "${DIR}/dist/easyworker-windows-amd64.exe"  "easyworker-windows-amd64.exe"
echo "Done. Verify with:"
echo "  curl -H 'Authorization: Bearer ${TOKEN}' ${BASE%/}/pkgs/generic/${NAME}/${VERSION}/easyworker-linux-amd64 -o /tmp/easyworker"
