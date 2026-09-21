# easyworker macOS 15 (Sequoia) sandbox — fat variant images.
#
# The guest disk is fully pre-baked (macOS 15 + optional per-variant toolchain),
# shipped as a qcow2. dockur auto-detects /storage/15/data.qcow2 (VERSION subdir
# + data.qcow2 name + qcow2 suffix => DISK_FMT=qcow2).
#
# The disk should be the *defragged* qcow2 (uncompressed 1 MiB clusters) so the
# OCI layer actually compresses — see repack-disk.sh.
#
# Layout inside the guest (baked into the disk, not here):
#   * docker auto-logs-in, so a real Aqua session (gui/501) exists;
#   * the worker runs from a LaunchAgent in that session (as docker);
#   * /etc/sudoers.d/easyworker gives docker NOPASSWD sudo.
FROM forgejo.develop.10.199.64.20.nip.io/root/dockur-macos:latest

COPY disk/data.qcow2 /storage/15/data.qcow2
COPY disk/support/ /storage/15/

# Worker binaries: linux (host side) + darwin (guest side).
COPY --chmod=755 easyworker-linux  /usr/local/bin/easyworker
COPY --chmod=755 easyworker-darwin /easyworker-darwin

# Token bridge baked in (no sidecar): /run/start.sh is sourced by dockur's
# entry.sh before the VM starts, and nginx already includes conf.d/*.conf.
COPY --chmod=644 00-token.conf /etc/nginx/conf.d/00-token.conf
COPY --chmod=755 start.sh      /run/start.sh

# macOS 15 Sequoia, pre-baked disk => no installer phase.
# NOTE: Sequoia on this Ice Lake host deadlocks with 8 vCPUs; 4 is stable.
ENV VERSION=15 \
    CPU_CORES=4 \
    DISK_SIZE=128G \
    RAM_SIZE=16384M \
    SAMBA=N \
    USER_PORTS=48080

VOLUME /storage
EXPOSE 8006 5900 22 48080 8090
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
