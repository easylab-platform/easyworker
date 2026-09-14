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
k8s/easyworker-linux-desktop.yaml  labwc desktop worker, pure Wayland (+ noVNC Service)
k8s/easyworker-android.yaml      BlissOS Android 13 worker under KVM (+ ws-scrcpy)
images/linux-desktop/            Dockerfile + entrypoint for the desktop sandbox
images/android-blessos/          Dockerfile + golden-construct + entrypoint for Android
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

## Linux desktop sandbox (labwc, pure Wayland, no KVM)

For **GUI program testing** on Linux there is no VM involved: the container is
the sandbox. `images/linux-desktop/` builds a Debian trixie image running a
headless wlroots compositor (**labwc**) with **wayvnc** + **noVNC** for a
browser view and the easyworker binary serving the Worker API. No KVM, no
device plugin, no `privileged`, no sidecar — the token is a plain
`WORKER_TOKEN` env var.

It is **pure Wayland**: no Xwayland, no `DISPLAY`, no X11 client workarounds.
Wayland-native clients (GTK3/GTK4, Qt5/Qt6 with the Wayland plugin, foot,
Electron with `--ozone-platform=wayland`, Flutter/GTK desktop) run directly;
X11-only programs are out of scope for this image.

```
:48080  Worker API (WorkerService + WorkerEnroll)
:5900   VNC      (wayvnc)
:6080   noVNC    (websockify, open — no auth by design)
```

Build (stages the linux/amd64 worker binary and pushes to forgejo):

```sh
scripts/build-all.sh                                   # builds dist/
WORKER_BIN=dist/easyworker-linux-amd64 \
  ./images/linux-desktop/build.sh                      # -> <registry>/root/easyworker-linux-desktop:v1.0.0
kubectl apply -f k8s/easyworker-linux-desktop.yaml
```

The image is deliberately minimal: compositor + terminal + fonts + the
Wayland/EGL/GTK runtime libraries a GUI binary links against. Extra tooling
(Chromium, build chains, browsers) is installed by the caller — either baked
into a derived image or fetched into the workspace at runtime.

### The display-environment catch

easyworker runs every job through its builtin shell with a **strict job-env
allowlist** (`cmd/easyworker/main.go`, `jobEnv()`): only proxy/registry knobs
plus `PATH`/`HOME`/`TMPDIR`/`USER` are passed through. `WAYLAND_DISPLAY` and
`XDG_RUNTIME_DIR` are **not** on that allowlist, so a bare `myapp` launched via
`Execute` cannot see the compositor. Two ways to fix it without touching worker
code:

- **Per-job env** — pass the variables on `ExecuteRequest.env`:

  ```
  {"command":"./myapp",
   "env":{"XDG_RUNTIME_DIR":"/tmp/xdg","WAYLAND_DISPLAY":"wayland-0"}}
  ```

- **`gui-run` wrapper** — the image prepends `/opt/session-bin` to `PATH`
  (`PATH` *is* allowlisted), and ships `gui-run <program> [args]`, which
  restores the session variables and execs the program:

  ```
  {"command":"gui-run ./myapp --flag"}
  ```

Software rendering (`LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`,
`WLR_RENDERER=pixman`) covers GPU-less clients.

## Android sandbox (BlissOS under KVM, ws-scrcpy)

`images/android-blessos/` packages a **BlissOS 16** (Android 13, x86_64) golden
disk that boots under QEMU/KVM, with **ws-scrcpy** as the browser screen
instead of noVNC. Two things differ from the Windows/macOS VM workers:

1. **The worker runs on the host side.** Android is a bionic userland, so the
   static linux/amd64 Go worker cannot run *inside* the guest; instead the
   container hosts the worker and drives the guest over **adb**
   (`adb install`, `adb shell am start`, `adb shell input`, …). A job installs
   and exercises an x86_64 APK exactly as if it were a CI step.
2. **KVM is still required** (`squat.ai/kvm:1`, `privileged: false`), same as
   the VM workers. The golden also bakes in adbd-over-TCP (5555) and a static
   dropbear sshd (22).

```
:48080  Worker API  (WorkerService + WorkerEnroll)
:8000   ws-scrcpy   (open, no auth — ClusterIP only)
        QEMU -> guest adbd :5555  (adb; used by jobs)
```

Build the golden + image (the golden is derived offline from the official
BlissOS 16 FOSS ISO, mirroring anyvm-org/blissos-builder's offline-construct:
unsquash/extract `system.img`, bake dropbear + init rc + adbd props into it,
GRUB-install, convert to qcow2):

```sh
scripts/build-all.sh                                   # dist/ worker binaries
# golden construction needs a privileged pod with loop/kpartx (nbd module is
# absent on this node); see images/android-blessos/ for the exact steps.
WORKER_BIN=dist/easyworker-linux-amd64 \
  ./images/android-blessos/build.sh                    # -> <registry>/easyworker-android-blessos:v1.0.0
kubectl apply -f k8s/easyworker-android.yaml
```

Job examples:

```
adb install -r /workspace/app-x86_64.apk
adb shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1
adb shell pm list packages -3
```

Notes:

- **APKs must be x86_64** — BlissOS FOSS ships no ARM translation layer.
- The guest is Android 13 (BlissOS 16). BlissOS 18 (Android 15, `voyager-x86`)
  exists in source but has no published ISO yet, so it would require a full
  AOSP build to adopt.
- ws-scrcpy is unencrypted and unauthenticated (upstream's own warning); it is
  ClusterIP-only.

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
