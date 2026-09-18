#!/usr/bin/env bash
# Cross-compile the easyworker binary used by the preset base image.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH:-amd64}" \
  go build -C "${ROOT}" -trimpath -ldflags "-s -w" -o "${HERE}/easyworker" ./cmd/easyworker
ls -l "${HERE}/easyworker"
