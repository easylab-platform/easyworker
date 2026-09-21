# easyworker Windows image

The easyworker Windows 11 sandbox: `dockur-windows` runtime + a pre-baked guest
disk that already contains the worker, its launcher and the scheduled task.

## Layout

- `Dockerfile` — thin wrapper: copies the guest disk + boot support files and
  the token bridge onto `dockur-windows`.
- `build.sh` — build + push (buildkitd → skopeo → forgejo).
- `repack-disk.sh` — shrink the disk layer (defrag + long-window zstd).
- `guest/` — the files baked *into the guest disk* (not part of the image build):
  - `worker-launch.cmd` — fetches `WORKER_TOKEN` from `host.lan:8090`, starts
    `easyworker.exe` as the current user.
  - `ewelevate.cmd` — run a command as `NT AUTHORITY\SYSTEM` (escape hatch).
  - `easyworker-task.xml` — the `EasyWorker` task definition (Docker user,
    HIGHEST, interactive, at logon). The hostname/user inside must match the
    guest; `install-worker.cmd` registers an equivalent task without XML.
  - `install-worker.cmd` — (re)install the worker in a running guest.

## Guest worker model (v1.5.0)

The worker runs as the **`Docker`** user in the interactive session, not as
SYSTEM. UAC is disabled in these images and `Docker` is an Administrator, so the
worker and every job it spawns already hold a full **High-IL** admin token.
`ewelevate.cmd` is there for the rare case that needs SYSTEM itself.

## Building

```sh
# stage (git-ignored): images/windows/disk/data.qcow2 + images/windows/disk-support/
scripts/build-all.sh          # produces dist/easyworker-{linux,windows}-amd64
./images/windows/build.sh     # -> <registry>/root/easyworker-windows:v1.5.0

# optional: shrink the disk layer
qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M,lazy_refcounts=on \
  disk/data.qcow2 disk/defrag.qcow2
./images/windows/repack-disk.sh disk/defrag.qcow2 v1.2.2 v1.5.0
```

The guest disk is rebuilt by booting the previous image's disk (hostPath-backed
so changes persist), running `guest/install-worker.cmd` inside it, then
committing and defragmenting it.
