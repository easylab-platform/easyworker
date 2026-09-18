# Toolchain versions & download URLs

Canonical reference for every pinned toolchain artifact. `urls.env` holds the
**resolved** URL for the pinned version; the tables below hold the URL
**pattern** (so the next bump is a one-line edit) and where the latest version
is discovered.

`./check-versions.sh` queries each upstream and prints pinned vs latest.

Legend: `{V}` = full version, `{VM}` = major.minor, `{MAJ}` = major,
`{DATE}` = release date (`YYYYMMDD`), `{OTP}` = OTP major.

## Runtime & compilers

| tool | pinned | latest (checked 2026-09-18) | URL pattern | latest lookup |
|---|---|---|---|---|
| node | 26.8.2 | **26.9.0** (LTS 24.21.0) | `https://nodejs.org/dist/v{V}/node-v{V}-linux-x64.tar.xz` | `https://nodejs.org/dist/index.json` |
| node (musl) | 26.8.2 | **26.9.0** | `https://unofficial-builds.nodejs.org/download/release/v{V}/node-v{V}-linux-x64-musl.tar.xz` | same |
| go | 1.27.1 | 1.27.1 | `https://go.dev/dl/go{V}.linux-amd64.tar.gz` | `https://go.dev/dl/?mode=json` |
| python | 3.14.7 / 20260901 | 20260901 | `https://github.com/astral-sh/python-build-standalone/releases/download/{DATE}/cpython-{V}+{DATE}-x86_64-unknown-linux-gnu-install_only.tar.gz` | `gh api repos/astral-sh/python-build-standalone/releases/latest` |
| python (musl) | 3.14.7 / 20260901 | 20260901 | same, `...-linux-musl-install_only.tar.gz` | same |
| uv | 0.12.14 | **0.12.16** | `https://github.com/astral-sh/uv/releases/download/{V}/uv-x86_64-unknown-linux-gnu.tar.gz` | `gh api repos/astral-sh/uv/releases/latest` |
| rust | 1.98.1 | 1.98.1 | `https://static.rust-lang.org/dist/{DATE}/rust-{V}-x86_64-unknown-linux-gnu.tar.gz` | `https://static.rust-lang.org/dist/channel-rust-stable.toml` |
| jdk | 25.0.4.1+1 | 25.0.4.1+1 (LTS) | `https://github.com/adoptium/temurin{MAJ}-binaries/releases/download/jdk-{V}/OpenJDK{MAJ}U-jdk_x64_linux_hotspot_{V2}.tar.gz` | `gh api repos/adoptium/temurin25-binaries/releases/latest` |
| dotnet | 10.0.401 | 10.0.401 | `https://builds.dotnet.microsoft.com/dotnet/Sdk/{V}/dotnet-sdk-{V}-linux-x64.tar.gz` | `https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json` |
| ruby | 4.0.7 | 4.0.7 | `https://github.com/ruby/ruby-builder/releases/download/ruby-{V}/ruby-{V}-ubuntu-22.04-x64.tar.gz` | `gh api repos/ruby/ruby-builder/releases` |
| ruby (musl) | 4.0.7 | 4.0.7 | `https://cache.ruby-lang.org/pub/ruby/{VM}/ruby-{V}.tar.gz` | `https://cache.ruby-lang.org/pub/ruby/` |
| php | 8.5.8 | **8.5.10** | `https://dl.static-php.dev/static-php-cli/bulk/php-{V}-cli-linux-x86_64.tar.gz` | `https://www.php.net/releases/index.php?json&version=8` |
| dart | 3.13.4 | 3.13.4 | `https://storage.googleapis.com/dart-archive/channels/stable/release/{V}/sdk/dartsdk-linux-x64-release.zip` | `.../release/latest/VERSION` |
| swift | 6.4.0 | 6.4.0 | `https://download.swift.org/swift-{V}-release/debian13/swift-{V}-RELEASE/swift-{V}-RELEASE-debian13.tar.gz` | `https://www.swift.org/api/v1/install/releases.json` |
| zig | 0.15.2 | **0.16.0** | `https://ziglang.org/download/{V}/zig-x86_64-linux-{V}.tar.xz` | `https://ziglang.org/download/index.json` |
| julia | 1.13.0 | 1.13.0 | `https://julialang-s3.julialang.org/bin/linux/x64/{VM}/julia-{V}-linux-x86_64.tar.xz` | `https://julialang-s3.julialang.org/bin/versions.json` |
| crystal | 1.21.0 | 1.21.0 | `https://github.com/crystal-lang/crystal/releases/download/{V}/crystal-{V}-1-linux-x86_64.tar.gz` | `gh api repos/crystal-lang/crystal/releases/latest` |
| lua | 5.4.7 | **5.5.1** | `https://www.lua.org/ftp/lua-{V}.tar.gz` | `https://www.lua.org/ftp/` |

> **JDK note:** Adoptium's latest LTS is 25 and the latest feature release is 26
> (`temurin26`); JDK 27 is GA on `jdk.java.net` but not yet published to
> Adoptium. We stay on **25** deliberately so Kotlin/Scala (and the wider JVM
> toolchain) run on a supported LTS.

## Package managers & build tools

| tool | pinned | latest (checked 2026-09-18) | URL pattern | latest lookup |
|---|---|---|---|---|
| gradle | 9.7.1 | 9.7.1 | `https://services.gradle.org/distributions/gradle-{V}-bin.zip` | `https://services.gradle.org/versions/current` |
| composer | 2.10.3 | 2.10.3 | `https://getcomposer.org/download/{V}/composer.phar` | `https://getcomposer.org/versions` |
| conda | latest | latest | `https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh` | n/a (rolling) |
| pixi | latest | v0.81.0 | `https://github.com/prefix-dev/pixi/releases/latest/download/pixi-x86_64-unknown-linux-musl` | `gh api repos/prefix-dev/pixi/releases/latest` |
| bun | 1.4.2 | 1.4.2 | `https://github.com/oven-sh/bun/releases/download/bun-v{V}/bun-linux-x64.zip` | `gh api repos/oven-sh/bun/releases/latest` |
| deno | 2.9.7 | 2.9.7 | `https://github.com/denoland/deno/releases/download/v{V}/deno-x86_64-unknown-linux-gnu.zip` | `gh api repos/denoland/deno/releases/latest` |
| gleam | 1.18.1 | 1.18.1 | `https://github.com/gleam-lang/gleam/releases/download/v{V}/gleam-v{V}-x86_64-unknown-linux-musl.tar.gz` | `gh api repos/gleam-lang/gleam/releases/latest` |
| cmake | 4.4.3 | 4.4.3 | `https://github.com/Kitware/CMake/releases/download/v{V}/cmake-{V}-linux-x86_64.tar.gz` | `gh api repos/Kitware/CMake/releases/latest` |
| ninja | 1.13.2 | 1.13.2 | `https://github.com/ninja-build/ninja/releases/download/v{V}/ninja-linux.zip` | `gh api repos/ninja-build/ninja/releases/latest` |
| luarocks | 3.13.0 | 3.13.0 | `https://luarocks.github.io/luarocks/releases/luarocks-{V}.tar.gz` | `gh api repos/luarocks/luarocks/releases/latest` |
| cpanm | 1.7047 | **1.7049** | `https://cpan.metacpan.org/authors/id/M/MI/MIYAGAWA/App-cpanminus-{V}.tar.gz` | `https://fastapi.metacpan.org/v1/release/App-cpanminus` |
| R | 4.5.1 | **4.6.1** | `https://cran.r-project.org/src/base/R-{MAJ}/R-{V}.tar.gz` | `https://cran.r-project.org/src/base/R-{MAJ}/` |
| ghcup | 0.2.6.2 | 0.2.6.2 | `https://downloads.haskell.org/~ghcup/{V}/x86_64-linux-ghcup-{V}` | `https://downloads.haskell.org/~ghcup/` |
| opam | 2.5.2 | **2.6.0** | `https://github.com/ocaml/opam/releases/download/{V}/opam-{V}-x86_64-linux` | `gh api repos/ocaml/opam/releases/latest` |

## JVM languages

| tool | pinned | latest (checked 2026-09-18) | URL pattern | latest lookup |
|---|---|---|---|---|
| kotlin | 2.4.20 | 2.4.20 | `https://github.com/JetBrains/kotlin/releases/download/v{V}/kotlin-compiler-{V}.zip` | `gh api repos/JetBrains/kotlin/releases/latest` |
| groovy | 4.0.33 | 4.0.33 (4.0 line) | `https://groovy.jfrog.io/artifactory/dist-release-local/groovy-zips/apache-groovy-binary-{V}.zip` | `https://groovy.jfrog.io/artifactory/dist-release-local/groovy-zips/` |
| clojure | 1.12.0.1530 | **1.12.6.1673** | `https://download.clojure.org/install/clojure-tools-{V}.tar.gz` | `gh api repos/clojure/brew-install/releases/latest` |
| scala-cli | 1.17.0 | **1.17.1** | `https://github.com/VirtusLab/scala-cli/releases/download/v{V}/scala-cli-x86_64-pc-linux.gz` | `gh api repos/VirtusLab/scala-cli/releases/latest` |
| sbt | 1.11.6 | **1.13.0** | `https://github.com/sbt/sbt/releases/download/v{V}/sbt-{V}.tgz` | `gh api repos/sbt/sbt/releases` (filter `v1.`) |

## BEAM (Erlang/Elixir/Hex)

| tool | pinned | latest (checked 2026-09-18) | URL pattern | latest lookup |
|---|---|---|---|---|
| otp | 29.0.6 | **29.1** | `https://builds.hex.pm/builds/otp/ubuntu-22.04/OTP-{V}.tar.gz` | `https://builds.hex.pm/builds/otp/ubuntu-22.04/builds.txt` |
| elixir | 1.20.4 | 1.20.4 | `https://builds.hex.pm/builds/elixir/v{V}-otp-{OTP}.zip` | `https://builds.hex.pm/builds/elixir/builds.txt` |
| hex | 2.5.1 | 2.5.1 | `https://repo.hex.pm/installs/{ELIXIR}/hex-{V}-otp-{OTP}.ez` → 301 `builds.hex.pm`; **mirrored locally** (`urls.local.env`) because the public path is not stable | `gh api repos/hexpm/hex/releases/latest` |
| hex key | — | — | `https://repo.hex.pm/installs/hex-registry-public-key.pem` → **mirrored locally** | n/a |

## Known issues

- **swift**: the pinned URL was missing the patch component
  (`swift-6.4-release/...`), which 404s. The correct pattern is
  `swift-6.4.0-release/.../swift-6.4.0-RELEASE-debian13.tar.gz`. Fixed in
  `urls.env`.
- **hex / hex key**: `repo.hex.pm/installs/...` 301-redirects to
  `builds.hex.pm` where the file 404s; the `.ez` and key are served from the
  local generic store instead (`toolchain/urls.local.env`).

## Bumping

```sh
./check-versions.sh                 # pinned vs latest for every tool
# edit toolchain/<distro>/urls.env (and manifest.txt for the e2e clients)
./fetch-artifacts.sh <lang>         # re-download into cache/<distro>/
./build-toolchain.sh <lang> && ./build-preset.sh <lang>
```
