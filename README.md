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
environment (which may hold platform tokens) is never inherited.

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
