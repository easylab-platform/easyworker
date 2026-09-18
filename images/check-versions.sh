#!/usr/bin/env bash
# Print pinned vs latest for every toolchain artifact in toolchain/<distro>/urls.env.
#
# "latest" is queried from the upstream's own release API (see
# toolchain/VERSIONS.md for the pattern/lookup table). Requires `gh` for the
# GitHub-hosted tools and network access through BUILD_PROXY.
#
# Usage: ./check-versions.sh [distro]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="${1:-debian-trixie}"
ENV_FILE="${HERE}/toolchain/${DISTRO}/urls.env"
[ -f "$ENV_FILE" ] || { echo "no such urls.env: $ENV_FILE" >&2; exit 1; }

export HTTPS_PROXY="${BUILD_PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
export HTTP_PROXY="$HTTPS_PROXY"

p() { printf "%-12s pinned=%-26s latest=%s\n" "$1" "$2" "$3"; }
ghl() { gh api "repos/$1/releases/latest" --jq '.tag_name' 2>/dev/null || echo "(?)"; }
json() { python3 -c "import sys,json;d=json.load(sys.stdin);$1" 2>/dev/null; }

echo "# pinned from ${ENV_FILE}"
echo "# latest queried $(date -u +%Y-%m-%dT%H:%MZ)"
echo

p NODE "26.9.0" "$(curl -s https://nodejs.org/dist/index.json | json 'print("current",d[0]["version"],"| LTS",[x["version"] for x in d if x.get("lts")][0])')"
p GO "1.27.1" "$(curl -s 'https://go.dev/dl/?mode=json' | json 'print([x["version"] for x in d if x["stable"]][0])')"
p UV "0.12.16" "$(ghl astral-sh/uv)"
p PYTHON "3.14.7/20260901" "$(ghl astral-sh/python-build-standalone)"
p RUST "1.98.1" "$(curl -s https://static.rust-lang.org/dist/channel-rust-stable.toml | awk -F'"' '/^\[pkg.rust\]/{f=1} f&&/^version/{print $2; exit}')"
p JDK "26.0.2.1 (java) / 25.0.4.1 (java25)" "$(ghl adoptium/temurin26-binaries) [java uses 26, JVM langs pin LTS via temurin25: $(ghl adoptium/temurin25-binaries)]"
p GRADLE "9.7.1" "$(curl -s https://services.gradle.org/versions/current | json 'print(d["version"])')"
p DOTNET "10.0.401" "$(curl -s https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json | json 'print([r["latest-sdk"] for r in d["releases-index"] if "-" not in r["latest-sdk"]][0])')"
p RUBY "4.0.7" "$(gh api 'repos/ruby/ruby-builder/releases?per_page=100' --jq '[.[]|select(.tag_name|test("^ruby-4\\.[0-9]+\\.[0-9]+$"))][0].tag_name' 2>/dev/null || echo '(?)')"
p PHP "8.5.8" "$(curl -s 'https://www.php.net/releases/index.php?json&version=8&max=5' | json 'print(sorted([k for k in d if k and k[0].isdigit()],key=lambda s:list(map(int,s.split("."))),reverse=True)[0])')"
p COMPOSER "2.10.3" "$(curl -s https://getcomposer.org/versions | json 'print(d["stable"][0]["version"])')"
p OTP "29.1" "$(curl -s https://builds.hex.pm/builds/otp/ubuntu-22.04/builds.txt | awk '{print $1}' | grep -E '^OTP-[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1)"
p ELIXIR "1.20.4" "$(curl -s https://builds.hex.pm/builds/elixir/builds.txt | awk '{print $1}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
p DART "3.13.4" "$(curl -s https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION | json 'print(d["version"])')"
p SWIFT "6.4.0" "$(curl -s https://www.swift.org/api/v1/install/releases.json | json 'print(d[-1]["name"], d[-1]["tag"])')"
p PIXI "latest" "$(ghl prefix-dev/pixi)"
p BUN "1.4.2" "$(ghl oven-sh/bun)"
p DENO "2.9.7" "$(ghl denoland/deno)"
p GLEAM "1.18.1" "$(ghl gleam-lang/gleam)"
p KOTLIN "2.4.20" "$(ghl JetBrains/kotlin)"
p GROOVY "4.0.33" "$(curl -s https://groovy.jfrog.io/artifactory/dist-release-local/groovy-zips/ | grep -oE 'apache-groovy-binary-4\.0\.[0-9]+\.zip' | sort -V | tail -1)"
p CLOJURE "1.12.6.1673" "$(ghl clojure/brew-install)"
p SCALA_CLI "1.17.1" "$(ghl VirtusLab/scala-cli)"
p SBT "1.13.0" "$(gh api 'repos/sbt/sbt/releases?per_page=50' --jq '[.[]|select(.tag_name|startswith("v1."))][0].tag_name' 2>/dev/null || echo '(?)')"
p JULIA "1.13.0" "$(curl -s https://julialang-s3.julialang.org/bin/versions.json | json 'print(sorted([k for k,v in d.items() if v.get("stable")],key=lambda s:list(map(int,s.split("."))))[-1])')"
p CRYSTAL "1.21.0" "$(ghl crystal-lang/crystal)"
p OPAM "2.6.0" "$(ghl ocaml/opam)"
p GHCUP "0.2.6.2" "$(curl -s https://downloads.haskell.org/~ghcup/ | grep -oE '0\.2\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
p ZIG "0.16.0" "$(curl -s https://ziglang.org/download/index.json | json 'print([k for k in d if k!="master"][0])')"
p CPANM "1.7049" "$(curl -s https://fastapi.metacpan.org/v1/release/App-cpanminus | json 'print(d.get("version"))')"
p LUA "5.5.1" "$(curl -s https://www.lua.org/ftp/ | grep -oE 'lua-5\.[0-9]+\.[0-9]+\.tar\.gz' | sort -V | tail -1)"
p LUAROCKS "3.13.0" "$(ghl luarocks/luarocks)"
p R "4.6.1" "$(curl -s https://cran.r-project.org/src/base/R-4/ | grep -oE 'R-4\.[0-9]+\.[0-9]+\.tar\.gz' | sort -V | tail -1)"
p CMAKE "4.4.3" "$(ghl Kitware/CMake)"
p NINJA "1.13.2" "$(ghl ninja-build/ninja)"
# clang/libc++ come from the apt.llvm.org suite for LLVM_MAJOR (see
# Dockerfile.cpp). Query the suite's Packages index for the exact apt version
# (the llvm-project GitHub tag is the source release, not the apt revision).
LLVM_APT_LATEST="$(curl -s "https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/trixie/dists/llvm-toolchain-trixie-23/main/binary-amd64/Packages.gz" | gunzip 2>/dev/null | awk '/^Package: clang-23$/{f=1} f&&/^Version:/{print $2; exit}')"
p CLANG "23 (llvm-toolchain-trixie-23)" "${LLVM_APT_LATEST:-?} [apt.llvm.org trixie-23; 24 = development suite]"
