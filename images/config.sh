#!/usr/bin/env bash
# Shared knobs for the two-stage preset build. Sourced by build-toolchain.sh,
# build-preset.sh and build-image.sh (not executed).
#
# DISTRO selects the libc base. Each distro has its own directory under
# toolchain/ and its own tag suffix, so both sets coexist in the registry:
#
#   DISTRO=debian-trixie   debian:trixie-slim   tags  :trixie
#   DISTRO=alpine-3.24     alpine:3.24          tags  :alpine3.24
#
# Stage 1 (build-toolchain.sh) pushes GENERIC language dev images. They have
# NO easylab content: the only external touch-point is a mirror URL for each
# pinned artifact, overridable per distro via toolchain/<distro>/urls.env.
#
#   ${TOOLCHAIN_REPO}-base:<distro-tag>     plain distro + utilities
#   ${TOOLCHAIN_REPO}-<lang>:<distro-tag>   + one toolchain
#
# Stage 2 (build-preset.sh) pushes the easylab-ready images:
#   ${PRESET_REPO}-<lang>:<distro-tag>      toolchain + worker + baked CA
#
# Override anything with an environment variable:
#   DISTRO=alpine-3.24 REGISTRY=... NAMESPACE=... TOOLCHAIN_TAG=...

DISTRO="${DISTRO:-debian-trixie}"
case "$DISTRO" in
  debian-trixie) DISTRO_TAG="${DISTRO_TAG:-debian-trixie}"; DISTRO_BASE="${DISTRO_BASE:-debian:trixie-slim}" ;;
  alpine-3.24)   DISTRO_TAG="${DISTRO_TAG:-alpine-3.24}";   DISTRO_BASE="${DISTRO_BASE:-alpine:3.24}" ;;
  *) echo "unknown DISTRO=${DISTRO} (debian-trixie|alpine-3.24)" >&2; exit 1 ;;
esac

REGISTRY="${REGISTRY:-forgejo.develop.10.199.64.20.nip.io}"
NAMESPACE="${NAMESPACE:-easylab}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.temp.svc.cluster.local:1234}"
# fetch-artifacts.sh downloads the toolchain tarballs through this proxy (host
# side, so builds never need it). apt/apk use the in-region mirror directly.
BUILD_PROXY="${BUILD_PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
FORGEJO_USER="${FORGEJO_USER:-root}"
FORGEJO_PASS="${FORGEJO_PASS:-devpassword}"

# Generic toolchain images (stage 1).
TOOLCHAIN_REPO="${TOOLCHAIN_REPO:-toolchain}"
TOOLCHAIN_TAG="${TOOLCHAIN_TAG:-${DISTRO_TAG}}"

# easylab-ready presets (stage 2). EASYLAB is the in-cluster base URL of the
# artifact service the sidecar rules point at.
EASYLAB="${EASYLAB:-http://easylab.temp.svc.cluster.local}"
PRESET_REPO="${PRESET_REPO:-easyworker}"
PRESET_TAG="${PRESET_TAG:-${DISTRO_TAG}}"

# Which languages have a Dockerfile in the selected distro. Alpine/musl has no
# builds for some toolchains:
#   swift  - glibc-only, no musl toolchain at all
#   dart   - no musl SDK, and the glibc SDK cannot run without a glibc layer
#   elixir - debian-only by decision
#   conda/pixi - conda-forge publishes no musl subdir, so no conda ecosystem
#                tool can build an environment on alpine (pixi's static musl
#                binary starts but installs glibc packages). Debian has both:
#                `conda` and `pixi`.
case "$DISTRO" in
  debian-trixie)
    # Order matters for images with a `<lang>.base` parent: parents first.
    PRESET_LANGS="${PRESET_LANGS:-node python go rust java kotlin groovy clojure scala dotnet ruby php elixir gleam dart swift conan conda pixi bun deno julia crystal ocaml haskell zig perl lua r cc cpp}" ;;
  alpine-3.24)
    PRESET_LANGS="${PRESET_LANGS:-node python go rust java kotlin groovy clojure scala dotnet ruby php gleam conan bun zig crystal ocaml haskell lua}" ;;
esac

# build_image <repo-name> <dockerfile> <tag> <base-image-ref> [extra-context...]
#
# <dockerfile> may be a single file or a list of fragments that are
# concatenated (stage 2 = inject/base.Dockerfile + inject/lang/<lang>.extra).
#
# Runs in a subshell so the temp dir is cleaned up even on failure, and a
# failure (set -e / explicit exit) aborts the sourcing script. `extra-context`
# names files from $HERE to place next to the Dockerfile (stage 2 passes the
# worker binary + the baked CA).
build_image() (
  set -euo pipefail
  local name="$1" df="$2" tag="$3" base="$4"
  shift 4
  local work ctx f
  work="$(mktemp -d)"; ctx="${work}/ctx"; mkdir -p "${ctx}"
  trap 'rm -rf "${work}"' EXIT
  if [ -f "${df}" ]; then
    cp "${df}" "${ctx}/Dockerfile"
  else
    local frag
    : > "${ctx}/Dockerfile"
    for frag in ${df}; do
      [ -f "${frag}" ] || { echo "missing Dockerfile fragment: ${frag}"; exit 1; }
      cat "${frag}" >> "${ctx}/Dockerfile"
    done
  fi
  for f in "$@"; do
    [ -f "${HERE}/${f}" ] || { echo "missing build context file: ${HERE}/${f}"; exit 1; }
    cp "${HERE}/${f}" "${ctx}/${f}"
  done
  # Stage-1 toolchain Dockerfiles COPY cache/<file> from the context; the cache
  # is populated by fetch-artifacts.sh (no downloads during the build). Only the
  # files the Dockerfile actually references are added, so the context stays
  # small and a build never needs a sibling language's tarball.
  local cf
  while read -r cf; do
    [ -n "$cf" ] || continue
    if [ ! -f "${HERE}/cache/${DISTRO}/${cf}" ]; then
      echo "missing cached artifact: ${HERE}/cache/${DISTRO}/${cf}" >&2
      echo "run: ./fetch-artifacts.sh <lang>" >&2
      exit 1
    fi
    mkdir -p "${ctx}/cache"
    cp "${HERE}/cache/${DISTRO}/${cf}" "${ctx}/cache/${cf}"
  done < <(sed -n 's#^COPY cache/\([^ ]*\).*#\1#p' "${ctx}/Dockerfile")

  local dest="${REGISTRY}/${NAMESPACE}/${name}:${tag}"
  echo "== build ${name}:${tag} on ${BUILDKIT} (from ${base}) =="
  # Toolchain tarballs are COPYed from the context (fetch-artifacts.sh), so no
  # proxy is needed inside the build. Only the base image's apt/apk step talks
  # to the network, and that uses the in-region mirror directly.
  buildctl --addr "${BUILDKIT}" build \
    --frontend dockerfile.v0 \
    --local "context=${ctx}" \
    --local "dockerfile=${ctx}" \
    --opt "filename=Dockerfile" \
    --opt "build-arg:BASE_IMAGE=${base}" \
    --output "type=docker,name=${name}:${tag},dest=${work}/image.tar" \
    --progress plain
  echo "== push ${dest} =="
  skopeo copy --dest-creds "${FORGEJO_USER}:${FORGEJO_PASS}" --dest-tls-verify=false \
    "docker-archive:${work}/image.tar:${name}:${tag}" "docker://${dest}"
  skopeo inspect --creds "${FORGEJO_USER}:${FORGEJO_PASS}" --tls-verify=false "docker://${dest}" >/dev/null \
    && echo "OK ${dest}" || { echo "push verify failed"; exit 1; }
)
