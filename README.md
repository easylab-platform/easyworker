# easyworker

The sandbox worker, reimplemented as a single static Go binary speaking
**Connect RPC** (`worker.v1.WorkerService`) — no WebSocket, no SSE. Same
contract semantics as the legacy worker-go surface (`execute`/`jobs`/
`job_*`/`file_*`), same stack as the rest of easylab-platform (`connect-go`
+ buf codegen, h1+h2c dual listener).

## The one rule: builtin shell only

Every command executes through the **mvdan.cc/sh/v3 interpreter** — there is
no passthrough to a host shell and no fallback, on any platform:

- identical bash-ish semantics on linux / windows / macos
- works in images that ship **no shell at all** (scratch/distroless), which
  the legacy `sh -c` approach could not run
- Windows batch wrappers (`.cmd`/`.bat` — npm, pnpm, …) are transparently
  dispatched via `cmd /c` inside the interp ExecHandler
- explicit `bash -c "…"` still works: bash is just another external binary
  the interpreter spawns

Job env is allowlisted (proxy/registry knobs + PATH/HOME) — the worker's own
environment (which may hold platform tokens) is never inherited. Callers may
additionally pass per-job env on `Execute` (`ExecuteRequest.env`), which is
layered on top of the allowlisted base.

## Pure executor: no repo/rev knowledge

The worker knows nothing about VCS. Workspace sync and rev coherence are
owned by **easylab**, which keeps the worker<->repo/branch mapping plus
`last_synced_rev` in its own persistent metadata and detects worker restarts
via `Info.boot_id` (re-sync on mismatch). This replaces BOTH the legacy
worker-side `synced_rev` gate and ext-ops' in-memory `synced` map — one
source of truth. Forgejo-runner-style CI needs no gate either: checkout
happens inside the job (like actions/checkout), `Execute` simply has no
token.

## Job history persistence (modernc sqlite)

Job registry + line history persist to sqlite (`WORKER_DB`, default
`/data/jobs.db` in-cluster): the memory ring (10k lines/stream) only feeds
live fanout; the DB is the unbounded authority.

- **emptyDir semantics**: everything is ephemeral to the pod — a container
  restart keeps history (same pod/volume), a pod recreation wipes it
- writes are batched (500 lines / 200ms transactions, WAL); a job's finish
  record commits strictly after its lines (FIFO writer)
- boot recovery: jobs left `running` by a crashed worker are marked
  `failed/137`
- retention: finished jobs older than **24h** are pruned hourly
- `JobOutput` supports `stream: all|stdout|stderr` filtering (legacy parity);
  reads merge the DB with the ≤200ms in-memory tail
- `WatchJob` (server-streaming) replays history, streams live stdout, and
  always sends a terminal `Done{exit_code, stdout, stderr}` event

## Process-tree kill

- unix: `setpgid` + group `SIGKILL`
- windows: per-process **Job Objects** (`KILL_ON_JOB_CLOSE`,
  `TerminateJobObject`) with `taskkill /T /F` fallback — also guarantees
  children never outlive the worker

## Layout

```
proto/worker/v1/worker.proto     contract source of truth
proto/buf.gen.worker.yaml        buf codegen (protocolbuffers/go + connectrpc/go)
gen/worker/v1/                   generated pb + connect code
cmd/easyworker/                  binary: flags, env, listener (h1+h2c)
internal/shellh/                 builtin shell (interp + exec/open handlers,
                                 build-tagged kill: pgroup | Job Object)
internal/jobsvc/                 manager (ring + fanout) + sqlite store
internal/filesvc/                binary-safe file ops, workspace containment
internal/service.go              Connect handlers (unary + WatchJob streaming)
k8s/easyworker.yaml              standalone host-runner Deployment (linux)
k8s/generic-device-plugin.yaml   admit /dev/kvm as squat.ai/kvm (unprivileged VMs)
k8s/easyworker-windows.yaml      non-privileged Windows VM worker (+ Services)
k8s/easyworker-macos.yaml        non-privileged macOS VM worker (+ Services)
k8s/easyworker-macos-xcode.yaml  the same, Xcode image, 4 vCPU / 16 GiB
k8s/easyworker-android.yaml      Android build toolchain + headless emulator + browser screen
images/android/                  Dockerfile + entrypoint + screen bridge for the emulator sandbox
images/macos/                    Dockerfile + build.sh + repack-disk.sh for the macOS VM images
images/windows/                  Dockerfile + build.sh + repack-disk.sh + guest/ for the Windows VM image
```

## Regenerate

```
cd proto && buf lint && buf generate --template buf.gen.worker.yaml
```

## Run (dev)

```
go run ./cmd/easyworker --addr 127.0.0.1:9090 --workspace /tmp/ws
curl -X POST -H 'Content-Type: application/json' -d '{}' \
     http://127.0.0.1:9090/worker.v1.WorkerService/Info
```

Env: `WORKER_PORT` (default 8080; cluster sandboxes pin 48080),
`WORKER_WORKSPACE` (default `~/EasyLab/workspace`, sandboxes use `/workspace`),
`WORKER_DB` (default `easyworker.db`).

## Auth / exclusive enrollment

The worker is **fail-closed**: it executes nothing until it holds a bearer
token. Every `WorkerService` RPC requires `Authorization: Bearer <token>`.

Two ways to obtain a token:

- **Managed sandbox** (`WORKER_TOKEN` set by the launcher, per-sandbox unique):
  the token is pre-authorized at boot; no enrollment.
- **External / host runner** (no `WORKER_TOKEN`): the worker mints a one-time
  code at boot, prints it to stdout, and the **first** caller presenting it
  claims the worker exclusively (`WorkerEnroll.Claim`; a second claim →
  `AlreadyExists`). The owner can `WorkerEnroll.Unrelease` to revoke the token
  and return a fresh code.

**Restart persistence (default on).** The enrollment state — the token once
claimed, or the one-time code while unclaimed — is stored in
`WORKER_STATE_FILE` (default `<dir(WORKER_DB)>/worker.state`, JSON, mode 0600,
atomic writes). An already-claimed worker therefore **resumes with the same
token** after a process/host restart: no re-claim, the controller's stored
token keeps working. Set `WORKER_STATE_FILE=off` to disable persistence
(in-memory only). Corrupt state fails safe (treated as unclaimed).

Reusable client (no easylab dependency): `github.com/easylab-platform/easyworker/client`
(`Enroll` / `Status` / `Release` / `Bearer` / `Dial`), plus the
`easyworker-enroll` CLI.

Other env: `WORKER_REQUIRE_AUTH=0` disables auth (dev only).

## Build & deploy (cluster)

`./build-image.sh` builds via the shared buildkitd and pushes to forgejo;
`kubectl apply -f k8s/easyworker.yaml` deploys to the `temp` namespace
(emptyDir `/data` for the history DB). Local bare-metal deployment is
intentionally NOT supported — container + k8s only.

## Windows / macOS VM sandboxes without `privileged: true`

easyworker also runs inside full **Windows / macOS VMs** (dockur-style golden
images) so a sandbox can build native desktop apps. Those workloads need KVM,
and under **cgroup v2** the device controller is a BPF allow-list: Kubernetes
has no per-device field, so a container normally cannot open `/dev/kvm` unless
it is `privileged: true` (which also grants every other device). Mounting
`/dev/kvm` as a hostPath is not enough — the open still returns `EPERM`.

The fix is a **device plugin**. `k8s/generic-device-plugin.yaml` deploys the
upstream [squat/generic-device-plugin](https://github.com/squat/generic-device-plugin)
mirrored into the internal registry; it advertises `squat.ai/kvm` and, on
`Allocate`, returns a `DeviceSpec` for `/dev/kvm` with permissions `rwm`.
kubelet/runc then create the device node **and** add the device-cgroup allow
rule for that container only. Nothing is installed on the host — the plugin
only reads `/dev/kvm` and writes its socket into kubelet's
`/var/lib/kubelet/device-plugins` directory.

The VM pods then request it as an extended resource and stay unprivileged:

```yaml
securityContext:
  privileged: false
  capabilities:
    add: ["NET_ADMIN","SYS_ADMIN","MKNOD", ...]   # no privileged, no ALL
resources:
  limits:
    squat.ai/kvm: "1"        # <- delivers /dev/kvm
volumeMounts:
  - { name: devtun, mountPath: /dev/net/tun }     # on the default allow-list
```

Apply order:

```sh
kubectl apply -f k8s/generic-device-plugin.yaml
kubectl apply -f k8s/easyworker-windows.yaml
kubectl apply -f k8s/easyworker-macos.yaml
```

Full, ready-to-use examples live in `k8s/easyworker-windows.yaml` and
`k8s/easyworker-macos.yaml` (worker API / SSH / noVNC Services included).

### Token without a sidecar

In-cluster sandboxes get `WORKER_TOKEN` from the launcher. For a VM the token
must cross into the guest, which cannot read the pod's environment. Instead the
VM images bake a tiny bridge:

- `/run/start.sh` (the dockur startup hook) writes `$WORKER_TOKEN` to
  `/run/shm/token`;
- nginx serves it on **`:8090`**, restricted to the guest subnet
  (`allow 172.30.0.0/24`, `deny all`, `no-store`). No Service exposes `:8090`;
- the guest launcher fetches `http://host.lan:8090/token` before starting the
  worker.

Semantics (controlled purely by the pod's `WORKER_TOKEN` env):

| `WORKER_TOKEN` | worker states | enrollment |
| --- | --- | --- |
| non-empty | pre-authorized | none — ready to serve |
| empty | unclaimed | mints a random one-time code to claim |

Because the token file is empty when `WORKER_TOKEN` is unset, the same image
supports both zero-touch pre-authorization and the normal claim flow.

### Writing your own VM image

A minimal image only needs the device-plugin contract from the pod and the
token bridge above. Two files are added to a qemu/dockur base:

`/run/start.sh` (the dockur startup hook, sourced before nginx starts):

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s' "${WORKER_TOKEN:-}" > /run/shm/token
chmod 644 /run/shm/token 2>/dev/null || true
return 0
```

`/etc/nginx/conf.d/00-token.conf` (nginx's base config already includes
`conf.d/*.conf`; dockur's `server.sh` only rewrites `sites-enabled/web.conf`):

```nginx
server {
    listen 8090;
    server_tokens off;
    allow 127.0.0.1;
    allow 172.30.0.0/24;   # guest (QEMU user-net) subnet
    deny all;
    location = /token {
        alias /run/shm/token;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
    }
    location / { return 404; }
}
```

```dockerfile
FROM <qemu base with dockur scripts>
COPY --chmod=755 ./disk /storage/            # pre-baked guest disk (fat)
COPY --chmod=644 ./00-token.conf /etc/nginx/conf.d/00-token.conf
COPY --chmod=755 ./start.sh /run/start.sh    # writes $WORKER_TOKEN to /run/shm/token
```

The guest launcher (installed in the image) starts easyworker with
`WORKER_TOKEN` set from the fetched token, so the pod's `WORKER_TOKEN` env is
the single knob.

### GUI session + passwordless sudo (macOS, v1.4.0+)

A LaunchDaemon runs in the system domain, so the worker it starts has **no Aqua
session**: GUI programs cannot reach WindowServer, and anything that goes
through macOS Authorization Services (an installer, `osascript … with
administrator privileges`) fails because there is no one to answer the prompt.
`sudo` is a separate matter — it needs a password and a TTY, which a job does
not have either.

The v1.4.0 macOS images fix both, baked into the guest disk:

- **auto-login** for `docker` (`/etc/kcpassword` + loginwindow prefs), so a real
  session `gui/501` exists at boot (`/dev/console` is `docker`);
- the worker runs as a **LaunchAgent** in that session, as `docker`, so jobs
  inherit the Aqua session;
- `/etc/sudoers.d/easyworker` grants `docker` **NOPASSWD** sudo (and
  `!requiretty`), so `sudo -n <cmd>` works with no prompt and no terminal.

The LaunchDaemon is kept as a one-shot fallback: if the agent never starts it
waits for `gui/501` and kickstarts the agent, and only runs the worker headless
if no GUI session ever appears.

This does **not** change macOS Authorization Services: `… with administrator
privileges` still has no one to answer it. Use the CLI equivalents
(`installer -pkg … -target /`, `softwareupdate -i …`) for those.

Verify in a job:

```sh
id -un                 # docker
sudo -n id -un         # root        (no password, no TTY)
launchctl print gui/501 | head -2
screencapture -x /tmp/s.png && sips -g pixelWidth /tmp/s.png
open -a TextEdit && pgrep -lf TextEdit   # a real GUI app, on screen
```

### Shrinking the guest disk (macOS v1.5.0, Windows v1.5.0)

The VM images are dominated by one layer: the pre-baked guest qcow2. The
committed golden stores its clusters **internally compressed** (zlib), so its
bytes are already incompressible and the outer layer buys nothing — the shipped
zstd layer sat at 14.85 GB for a 15.27 GB macOS file.

The fix is to defragment the qcow2 to **uncompressed 1 MiB clusters**
(`qemu-img convert -O qcow2 -o cluster_size=1M`, no `-c`), which drops dead
clusters and leaves the payload compressible again. A **27-bit (128 MiB) zstd
window** then finds the large-scale APFS/NTFS repetition an 8 MiB window misses.
Measured on the macOS base disk (20.10 GB defragged):

| recipe | working set |
|---|---|
| shipped (no defrag, buildkit default zstd) | 14.85 GB |
| defrag + buildkit zstd `-19` (8 MiB window) | 13.92 GB |
| defrag + zstd `-19 --long=27` | **12.58 GB** |
| defrag + zstd `--ultra -22 --long=27` | 12.53 GB (not worth it) |

So the win is the defrag plus the long window, **not** the compression level.
Things that do *not* help: guest-side zero-fill/`fstrim` before commit (APFS
already trims — no-op), and converting to a raw image (identical).

Results (both registries, same digest):

| tag | before | after |
|---|---|---|
| `easyworker-macos:v1.5.0-base` | 14.81 GiB | **12.70 GiB** (−14.2%) |
| `easyworker-macos:v1.5.0-xcode` | 19.27 GiB | **16.10 GiB** (−16.4%) |
| `easyworker-windows:v1.5.0` | 18.14 GiB | **14.65 GiB** (−19.2%) |

### Dropping the install media (macOS v1.6.0)

The macOS image also shipped `base.dmg`, the ~845 MiB recovery/install media
dockur uses to *install* macOS. With a pre-baked disk that is dead weight:
dockur's `install()` only runs when the disk has no data, and the QEMU
`InstallMedia` device is only attached when `base.dmg` exists. v1.6.0 ships the
boot support files without it (verified by booting the image with the file
removed: worker as `docker`, `sudo -n` root, `gui/501`, macOS 15.7.9 all fine):

| tag | v1.5.0 | v1.6.0 |
|---|---|---|
| `easyworker-macos:v1.6.0-base` | 12.70 GiB | **11.88 GiB** (−0.82) |
| `easyworker-macos:v1.6.0-xcode` | 16.10 GiB | **15.28 GiB** (−0.82) |

The upstream `dockur-*` runtime is also pinned by digest now instead of
`:latest`, so a shipped image cannot silently change under it. (Guest-side
compaction was investigated and is a no-op on both guests: the macOS and Windows
goldens are already clean, so the install media was the only real bulk left;
Windows ships no install media at all.)

buildkit cannot set a long window, so the disk layer is recompressed by hand and
swapped into the manifest (`images/macos/repack-disk.sh`,
`images/windows/repack-disk.sh`): decompress the old layer → tar the defragged
qcow2 → `zstd -19 --long=27` → patch `layers[i]` and `rootfs.diff_ids[i]`.
containerd accepts such layers (verified by running a pod from one); the guest is
byte-identical, so old and new tags are interchangeable.

Alternatives considered:

- **TCG (software emulation, `KVM=N`)**: needs no plugin at all but is ~10×
  slower — unusable for real builds.
- **Self-built KVM device plugin**: works and is tiny, but the upstream
  generic-device-plugin covers the same case with no code to maintain.
- **Dynamic Resource Allocation (DRA)**: cleaner on paper (a `DeviceClass` +
  `ResourceSlice` with an `extendedResourceName`), and containerd here has CDI
  enabled. It is **not** usable from a namespaced ServiceAccount: publishing
  `ResourceSlice`/`DeviceClass` is cluster-scoped and returns `403`. DRA would
  require cluster-admin RBAC, so the device plugin is the pragmatic choice.

## Android sandbox (toolchain + official emulator + browser screen)

`images/android/` is a self-contained Android **development** sandbox: the
container carries the build toolchain **and** the official Android Emulator with
an Android 35 (Google APIs, x86_64) system image, so a single job can build an
APK and immediately install/run it in the guest.

```
:48080  Worker API  (WorkerService + WorkerEnroll)   host side
:6080   screen      (headless emulator -> scrcpy H.264 -> bridge -> browser)
:5555   emulator adbd (internal; used by adb/jobs)
```

Toolchain baked in: **JDK 21**, **Gradle 8.13**, **Android SDK**
(`platform-tools`, `emulator`, `platforms;android-35`, `build-tools;35.0.0`,
`system-images;android-35;google_apis;x86_64`), plus `nodejs`/`node-ws` for the
screen bridge. `privileged: false`; KVM comes from the device plugin, same as
the other VM workers.

### Screen: headless emulator, no X, no VNC

The emulator runs with `-no-window`. Its screen is captured on-device by
**scrcpy-server** and relayed to the browser by a small Node bridge
(`images/android/bridge/server.js`):

```
emulator -no-window
  -> scrcpy-server 4.1  (adb forward, Annex-B H.264 + frame metadata)
     -> bridge :6080  (WebSocket /h264)
        -> MSE player (jMuxer) in the browser
```

`scrcpy-server` is driven directly over `adb` (push + `app_process` +
`adb forward`), so no scrcpy client is shipped and there is no X server, no
`xvfb`, no `x11vnc` and no noVNC. The bridge is view-only — the player is a
plain `<video>` fed by jMuxer, which is the reason it works over a plain HTTP
origin (WebCodecs would require a secure context).

### Input: adb through the worker API

There is no input path in the bridge by design. Drive the device with adb as a
job, which is also how a test asserts behaviour:

```
adb -s emulator-5554 shell input tap 540 1200
adb -s emulator-5554 shell input text hello
adb -s emulator-5554 shell input keyevent 4
```

### GPU (optional)

Software rendering is the default (`ANDROID_GPU=swiftshader_indirect`). To use a
host GPU, add `runtimeClassName: nvidia` and `nvidia.com/gpu: "1"` to the pod
(the manifest has them commented out) and set `ANDROID_GPU=host`. Verified
working on this cluster's A800 nodes; without the GPU the same image falls back
to software.

The worker runs on the host side (Android cannot run the linux/amd64 Go worker)
and drives the guest over `adb`. Because the worker's job environment is a strict
allowlist (only `PATH`/`HOME`/`TMPDIR`/`USER` and proxies survive), `ANDROID_HOME`
never reaches a job — the image ships a global Gradle init script that writes
`sdk.dir` into `local.properties`, so plain `gradle assembleDebug` works in jobs.

```sh
scripts/build-all.sh                        # dist/ worker binaries
./images/android/build.sh                   # -> <registry>/easyworker-android:v1.1.0
kubectl apply -f k8s/easyworker-android.yaml
```

The AVD is created on first start and its userdata lives on `/data` (an
`emptyDir` in the manifest, so each pod starts clean; swap for a PVC to persist).

One job, full loop (verified end to end):

```
gradle --no-daemon assembleDebug            # builds app-debug.apk in the container
adb -s emulator-5554 install -r app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell wm dismiss-keyguard
adb -s emulator-5554 shell am start -n <pkg>/.MainActivity
adb -s emulator-5554 shell uiautomator dump /sdcard/u.xml    # assert the UI rendered
```

Notes:

- **APKs must be x86_64** — this system image has no ARM translation layer.
- `ANDROID_MEM`/`ANDROID_CPUS` size the guest only; size the pod's requests above
  that so the toolchain has room too.

## Multi-platform (windows / macos host-run)

The same binary runs as a plain host process on Windows and macOS (the
forgejo-runner desktop model). Verified against the dockur VMs:

```
scripts/build-all.sh    # cross-compile worker + ewtest (linux/windows/darwin)
scripts/multi-test.sh   # ewtest on all three platforms, one report
```

`ewtest` exercises the full Connect surface per platform (14 checks: info,
watch streaming, output filters, builtin-pipe, external exec, files,
containment, stdin, tree-kill) with per-OS commands chosen at runtime.

Platform notes:

- **Windows**: `.cmd/.bat` → `cmd /c` in the ExecHandler; kills via per-job
  Job Objects (`TerminateJobObject`, taskkill fallback); detached start via
  `Win32_Process Create` (Start-Process holds the SSH channel); paths compare
  case-insensitively with `\\?\` prefix trimming.
- **macOS**: process-group kill (`setpgid` + `SIGKILL`); universal not needed
  for the dockur x86_64 VM, darwin/arm64 binaries built for real Apple
  Silicon.
- **JobWait hardening lesson**: the original bug was NOT a flaky VM clock —
  it was an untyped-constant trap (`jobWaitMaxMs = 60_000` compared against
  `time.Duration` means 60µs, not 60s), clamping every wait to a hair
  trigger that raced `done` (unix won the race, windows lost it). Fixed with
  a typed `60 * time.Second`; caps and comparisons involving time.Duration
  must always be typed (see `TestJobWaitHonorsLongTimeouts`).
- **GUI apps (verified on the VM)**: Edge launched with an isolated
  `--user-data-dir` spawns a 14-process tree that `JobKill` reaps entirely
  via TerminateJobObject while the user's pre-existing Edge processes stay
  untouched (precise tree-scoped kill). Caveats: bare `msedge`/`explorer`
  hand off to existing instances (un-killable); Win11 store Notepad's stub
  exits after delegating to the real app outside the job; a fresh explorer
  in a non-interactive SSH session dies on its own (exit 123). For a
  killable GUI target always isolate (separate profile) or use classic
  non-delegating exes. Window VISIBILITY is purely a function of the
  worker's own session, verified both ways: SSH-spawned worker runs in
  session 0 (sshd's), so its GUI processes render on session 0's
  non-interactive window station — invisible on the VNC/console desktop
  (session 1); the SAME binary started in session 1 via
  `Register-ScheduledTask -LogonType Interactive` (no password needed)
  produces an Edge tree entirely in session 1 with windows on the desktop.
  Desktop-visible GUI runs therefore just need the worker placed in the
  interactive session.

## Future: easylab-side integration

- easylab metadata table: sandbox service name -> (repo, branch,
  last_synced_rev, boot_id), checked before dispatching to a worker
- ext-ops: `internal/worker` (legacy WS client) switches to the generated
  Connect client; `createWorker`/`ensureSynced`/`synced` map collapse into
  the easylab-owned flow
- desktop/CI: same binary registers forgejo-runner style (labels, dial-out)
