#!/usr/bin/env bash
# Stage 2 of the two-stage preset build: take a generic stage-1 toolchain image
# and inject easylab's capabilities (easyworker binary, this deployment's egress
# MITM CA, trust env) so the result runs as a zero-injection worker.
#
#   DISTRO=debian-trixie ./build-preset.sh node
#   DISTRO=alpine-3.24   ./build-preset.sh node
#
# Build ONE image at a time: pass a single language (the first arg). With no
# args it builds the base followed by every language of the selected distro.
# Stage 1 must have run first for the same distro/tag.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "${HERE}/config.sh"

DIR="${HERE}/toolchain/${DISTRO}"
[ -d "$DIR" ] || { echo "no toolchain dir for DISTRO=${DISTRO}: ${DIR}"; exit 1; }

LANGS="${*:-base ${PRESET_LANGS}}"

# The worker binary and the CA are both inputs and part of the build context,
# so fetch them once up front.
"${HERE}/extract-ca.sh"
"${HERE}/build-worker.sh"

build() { # proto
  local proto="$1" name dfproto df
  if [ "$proto" = "base" ]; then
    name="${PRESET_REPO}-base"
    df="${HERE}/inject/base.Dockerfile"
  else
    local dfproto="$proto"; [ "$proto" = "go" ] && dfproto="golang"
    name="${PRESET_REPO}-${proto}"
    df="${HERE}/inject/base.Dockerfile"
    # Runtime-specific injection (Java keytool, pip.conf, ...) is appended.
    # The JVM languages extend the java toolchain, so they inherit the JDK's
    # keystore and need the same CA import.
    local inject="${dfproto}"
    case "$proto" in
      kotlin|groovy|clojure|scala) inject="java" ;;
      gleam) inject="elixir" ;;
      bun|deno) inject="node" ;;
    esac
    if [ -f "${HERE}/inject/lang/${inject}.extra" ]; then
      df="${df} ${HERE}/inject/lang/${inject}.extra"
    fi
  fi
  local src="${REGISTRY}/${NAMESPACE}/${TOOLCHAIN_REPO}-${proto}:${TOOLCHAIN_TAG}"
  build_image "$name" "$df" "$PRESET_TAG" "$src" easyworker ca.crt
}

for l in ${LANGS}; do
  build "$l"
done
