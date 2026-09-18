# easyworker preset images

Self-contained **dev-workflow** worker images, built in two stages:

1. **toolchain** — generic language dev images. Nothing deployment-specific:
   no worker binary, no CA, no trust env. Usable as plain `docker run` dev
   shells. Pinned upstream artifacts are pre-downloaded and `COPY`ed in.
2. **preset** — `easyworker` + this deployment's egress MITM CA baked in, so
   the image runs as a worker with **zero injection** (no worker hostPath, no
   CA env/volumes).

```sh
./extract-ca.sh                     # pull the deployment CA (ca.crt + ca.key)
./build-worker.sh                   # cross-compile easyworker
./fetch-artifacts.sh node           # pre-download node's tarballs (host-side)
./build-toolchain.sh node           # stage 1: toolchain-node
./build-preset.sh node              # stage 2: easyworker-node
./test-preset.sh node debian-trixie # run it as a pod, drive the worker API
```

Build **one image at a time** (a single language argument). Without arguments
the scripts walk the whole language list for the selected distro.

## Distros

`DISTRO` (default `debian-trixie`) selects the libc base; each distro has its
own directory under `toolchain/` and its own tag, so both sets coexist:

| DISTRO | base | tag | notes |
|---|---|---|---|
| `debian-trixie` | `debian:trixie-slim` | `debian-trixie` | everything |
| `alpine-3.24` | `alpine:3.24` | `alpine-3.24` | musl; no swift/dart/elixir/conda, and `gcompat` is deliberately never installed |

Toolchain images live at `…/toolchain-<lang>:<tag>`, presets at
`…/easyworker-<lang>:<tag>`. The two prefixes differ on purpose: a preset build
must not overwrite its own stage-1 base.

## Layout

- `config.sh` — registry/tags/distro knobs + `build_image` (buildkit → skopeo →
  forgejo). Sourced by the build scripts.
- `toolchain/<distro>/` — `base.Dockerfile`, `Dockerfile.<lang>`, `urls.env`.
- `inject/base.Dockerfile` (+ `inject/lang/<lang>.extra`) — stage 2.
- `cache/<distro>/` — pre-downloaded artifacts (gitignored).
- `extract-ca.sh`, `build-worker.sh`, `fetch-artifacts.sh`, the build scripts,
  `test-preset.sh`.

## Artifacts: no downloads during a build

A stage-1 build does not touch the network for toolchains. `fetch-artifacts.sh`
downloads each pinned artifact to `cache/<distro>/` on the host through
`BUILD_PROXY`, and `build_image` adds only the files a Dockerfile references to
the build context. URLs come from `toolchain/<distro>/urls.env`, overridden by
`toolchain/urls.local.env` (gitignored) for artifacts that have no public URL
(e.g. the offline conan wheel set) or a faster internal mirror.

OS packages are the exception: `base.Dockerfile` installs them from
`mirrors.aliyun.com` at build time (the image is restored to the official
distro sources afterwards). Language runtimes are never installed with
`apt`/`apk`; only base OS libraries are (e.g. `libicu` for .NET, `openssl`).

## CA trust: what is baked and why

`update-ca-certificates` merges the egress CA into the system bundle, which
covers Go, Ruby, PHP, .NET, cargo (libcurl), Erlang, Nix and the system package
managers. The rest need an explicit path or are wired to their own store:

| runtime | mechanism |
|---|---|
| Node | `NODE_EXTRA_CA_CERTS` (ignores the system bundle by default) |
| Python pip | `PIP_CERT` + `/etc/pip.conf` (vendored certifi) |
| uv | `UV_SYSTEM_CERTS=1` (rustls/webpki-roots by default) |
| Dart | `DART_VM_OPTIONS=--root-certs-file=…` (builtin roots) |
| Java | CA imported into the JDK's `cacerts` at image build |
| Hex | `HEX_CACERTS_PATH` |

All of these live in the **image** environment; `easyworker` forwards them to
job processes through its job-env allowlist, so a CI step sees them without the
pod spec carrying anything.

`ca.crt` and `ca.key` are **not** committed (they differ per deployment);
`ca.key` is the sidecar's signing key and is only needed by `test-preset.sh`.

## Relationship to `artifact/e2e/toolchain`

That harness (in the artifact repo) builds **client** images to *test* the
protocol adapters — same toolchain versions, different purpose. This tree is
the **runtime** image set consumed by easylab for CI/sandbox presets, kept in
its own repo so a test-only change cannot alter what developers run.

## Versions

Pinned in `toolchain/<distro>/urls.env`; keep them in sync with
`artifact/e2e/toolchain/manifest.txt` when both are refreshed.
