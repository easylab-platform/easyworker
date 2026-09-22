# easyworker Windows 11 sandbox — fat variant image.
#
# The guest disk is fully pre-baked (Windows 11 + whatever toolchain was
# installed) and shipped as a qcow2 under /storage. dockur auto-detects
# /storage/data.qcow2 (data.qcow2 name + qcow2 suffix => DISK_FMT=qcow2), so a
# pre-baked disk means there is no install phase.
#
# The disk should be the *defragged* qcow2 (uncompressed 1 MiB clusters) so the
# OCI layer compresses — see repack-disk.sh.
#
# Guest layout baked into the disk (see guest/):
#   * the `EasyWorker` scheduled task runs C:\Users\Docker\worker-launch.cmd as
#     the `Docker` user, in the interactive session, at logon;
#   * UAC is disabled in these images and Docker is an Administrator, so the
#     worker's jobs already hold a full High-IL admin token;
#   * C:\Users\Docker\ewelevate.cmd runs a command as SYSTEM for the few cases
#     that need SYSTEM itself.
# Pinned by digest (self-owned: a moving :latest tag would silently change the
# runtime under a shipped image). Windows ships no install media at all - the
# installer downloads its ISO at run time - so there is no base.dmg-equivalent
# to drop; the install-only scripts are well under 1 MiB and stay.
FROM forgejo.develop.10.199.64.20.nip.io/root/dockur-windows@sha256:32cc92715a6c5dc1f63142d3be11059279d64d0faa7519618a07290b3076f9f2

# Pre-baked guest disk, then the boot support files (OpenCore/UEFI identity,
# ROM, and the saved vars) alongside it.
COPY disk/data.qcow2 /storage/
COPY disk-support/ /storage/

# Token bridge baked in (no sidecar): /run/start.sh is sourced by dockur's
# entry.sh before the VM starts, and nginx already includes conf.d/*.conf.
COPY --chmod=644 00-token.conf /etc/nginx/conf.d/00-token.conf
COPY --chmod=755 start.sh      /run/start.sh

ENV VERSION=win11 \
    EDITION=pro \
    CPU_CORES=8 \
    DISK_SIZE=128G \
    RAM_SIZE=32768M \
    DISK_FMT=qcow2 \
    MANUAL=N \
    SAMBA=N

VOLUME /storage
EXPOSE 3389 8006 22 48080 8090
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
