#!/usr/bin/env bash
# Stage 1 of the two-stage preset build: build the *generic* language/tool
# dev images for one distro and push them. They contain NOTHING
# deployment-specific — no easyworker binary, no egress CA, no trust env — and
# are usable as plain `docker run` dev shells. Stage 2 (build-preset.sh) layers
# easylab on top.
#
#   DISTRO=debian-trixie ./build-toolchain.sh node
#   DISTRO=alpine-3.24   ./build-toolchain.sh node
#
# Build ONE image at a time: pass a single language (the first arg). With no
# args it builds the base followed by every language of the selected distro.
#
# Artifact URLs come from toolchain/<distro>/urls.env (canonical upstream)
# overridden by toolchain/urls.local.env if present (written by mirror.sh), so
# builds can be pointed at an internal mirror without editing the Dockerfiles.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "${HERE}/config.sh"

DIR="${HERE}/toolchain/${DISTRO}"
[ -d "$DIR" ] || { echo "no toolchain dir for DISTRO=${DISTRO}: ${DIR}"; exit 1; }

LANGS="${*:-base ${PRESET_LANGS}}"
TOOLCHAIN_BASE_REF="${REGISTRY}/${NAMESPACE}/${TOOLCHAIN_REPO}-base:${TOOLCHAIN_TAG}"

# Make sure every artifact the target Dockerfiles COPY is in the local cache;
# the build context then needs no network for the toolchain tarballs.
"${HERE}/fetch-artifacts.sh" ${LANGS}

build() { # proto  (proto "base" -> the shared toolchain base)
  local proto="$1" name df
  if [ "$proto" = "base" ]; then
    name="${TOOLCHAIN_REPO}-base"
    df="${DIR}/base.Dockerfile"
    # The base sits on the distro's own upstream image.
    build_image "$name" "$df" "$TOOLCHAIN_TAG" "$DISTRO_BASE"
    return
  else
    # "go" is the toolchain label; the Dockerfile is Dockerfile.golang (a file
    # named Dockerfile.go would be picked up by `go build ./...`).
    local dfproto="$proto"; [ "$proto" = "go" ] && dfproto="golang"
    name="${TOOLCHAIN_REPO}-${proto}"
    df="${DIR}/Dockerfile.${dfproto}"
  fi
  [ -f "$df" ] || { echo "no Dockerfile for ${proto} in ${DISTRO}: ${df}"; exit 1; }
  build_image "$name" "$df" "$TOOLCHAIN_TAG" "$TOOLCHAIN_BASE_REF"
}

for l in ${LANGS}; do
  build "$l"
done
