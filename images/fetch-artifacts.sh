#!/usr/bin/env bash
# Pre-download every stage-1 toolchain artifact into a local cache, so image
# builds COPY them from the build context instead of curling upstream from
# inside the (slow, proxied) build container.
#
#   ./fetch-artifacts.sh              # all artifacts of $DISTRO
#   ./fetch-artifacts.sh node         # only the ones Dockerfile.node needs
#
# Cache layout: cache/<distro>/<filename>. Filenames come from the URL
# basename (%2B decoded) and must match the `COPY cache/<file>` lines in the
# Dockerfiles; `fetch-artifacts.sh` verifies that for the requested language.
# Downloads go through BUILD_PROXY on the host (fast); the cache is gitignored.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "${HERE}/config.sh"

LANGS="${*:-}"
DIR="${HERE}/toolchain/${DISTRO}"
CACHE="${HERE}/cache/${DISTRO}"

# Load URL knobs (canonical, then local overrides) into the environment.
set -a
# shellcheck source=/dev/null
. "${DIR}/urls.env"
[ -f "${HERE}/toolchain/urls.local.env" ] && . "${HERE}/toolchain/urls.local.env"
set +a

URL_VARS="NODE_URL GO_URL PYTHON_URL UV_URL RUST_URL JDK_URL GRADLE_URL \
DOTNET_URL RUBY_URL PHP_URL COMPOSER_URL OTP_URL ELIXIR_URL HEX_URL HEXKEY_URL \
DART_URL SWIFT_URL CONDA_URL CONAN_URL"

# The conan wheel set is libc-specific; urls.local.env may supply both and we
# pick the one matching DISTRO.
case "$DISTRO" in
  alpine-*) CONAN_URL="${CONAN_URL_MUSL:-$CONAN_URL}" ;;
  *)        CONAN_URL="${CONAN_URL_GLIBC:-$CONAN_URL}" ;;
esac

# local_name <url> -> filename used in the cache and in COPY lines.
local_name() {
  local u="${1%%\?*}"
  u="${u##*/}"
  echo "${u//%2B/+}"
}

# wanted <file>: with explicit languages, only files referenced by those
# Dockerfiles are downloaded.
wanted() {
  [ -z "$LANGS" ] && return 0
  local l dfproto f
  for l in $LANGS; do
    dfproto="$l"; [ "$l" = "go" ] && dfproto="golang"
    [ "$l" = "base" ] && continue
    [ -f "${DIR}/Dockerfile.${dfproto}" ] || continue
    if grep -q "COPY cache/$1\b" "${DIR}/Dockerfile.${dfproto}" 2>/dev/null; then return 0; fi
  done
  return 1
}

mkdir -p "${CACHE}"
ok=0; skip=0; fail=0
for var in ${URL_VARS}; do
  url="${!var-}"
  [ -n "$url" ] || continue
  file="$(local_name "$url")"
  dest="${CACHE}/${file}"
  wanted "$file" || continue
  if [ -s "$dest" ]; then
    echo "skip  ${file} ($(wc -c <"$dest") bytes)"
    skip=$((skip+1)); continue
  fi
  echo "fetch ${file}"
  if HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
     curl -fSL --retry 3 --retry-delay 2 -o "${dest}.part" "$url"; then
    mv "${dest}.part" "$dest"
    echo "  -> $(wc -c <"$dest") bytes"
    ok=$((ok+1))
  else
    rm -f "${dest}.part"; echo "  -> FAILED"; fail=$((fail+1))
  fi
done

# Verify every COPY cache/<file> referenced by the requested Dockerfiles exists.
missing=0
for l in ${LANGS:-$PRESET_LANGS}; do
  dfproto="$l"; [ "$l" = "go" ] && dfproto="golang"
  df="${DIR}/Dockerfile.${dfproto}"; [ -f "$df" ] || continue
  while read -r f; do
    [ -n "$f" ] || continue
    if [ ! -s "${CACHE}/${f}" ]; then
      echo "MISSING ${dfproto}: ${f}"; missing=1
    fi
  done < <(sed -n 's#^COPY cache/\([^ ]*\).*#\1#p' "$df")
done

echo "fetch-artifacts(${DISTRO}): $ok downloaded, $skip cached, $fail failed"
[ "$fail" -eq 0 ] && [ "$missing" -eq 0 ]
