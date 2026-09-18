#!/usr/bin/env bash
# Build BOTH stages, in order:
#   1. build-toolchain.sh  generic language dev images (no easylab content)
#   2. build-preset.sh     easyworker presets = toolchain + worker + baked CA
#
#   ./build-all.sh             # everything
#   ./build-all.sh node java   # just those languages (plus the two bases)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${HERE}/build-toolchain.sh" "$@"
"${HERE}/build-preset.sh" "$@"
