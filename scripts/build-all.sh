#!/usr/bin/env bash
# Cross-compile easyworker + ewtest for all three platforms into dist/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

build() { # GOOS GOARCH suffix
  echo "-> easyworker-$1-$2 + ewtest-$1-$2"
  CGO_ENABLED=0 GOOS=$1 GOARCH=$2 go build -trimpath -ldflags "-s -w" -o "dist/easyworker-$1-$2" ./cmd/easyworker
  CGO_ENABLED=0 GOOS=$1 GOARCH=$2 go build -trimpath -ldflags "-s -w" -o "dist/ewtest-$1-$2" ./cmd/ewtest
  [ "$3" != "" ] && mv "dist/easyworker-$1-$2" "dist/easyworker-$1-$2$3" && mv "dist/ewtest-$1-$2" "dist/ewtest-$1-$2$3" || true
}

rm -rf dist && mkdir -p dist
build linux  amd64 ""
build windows amd64 ".exe"
build darwin amd64 ""
# darwin/arm64 for real Apple Silicon hosts (the dockur VM is x86_64):
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o dist/easyworker-darwin-arm64 ./cmd/easyworker
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o dist/ewtest-darwin-arm64 ./cmd/ewtest

ls -lh dist/
