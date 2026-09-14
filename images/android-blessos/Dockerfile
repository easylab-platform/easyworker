# syntax=docker/dockerfile:1
# easyworker Android (BlissOS) sandbox: KVM-accelerated BlissOS 16 (Android 13,
# x86_64) golden under QEMU, with the easyworker binary on the host side driving
# the guest over adb, and ws-scrcpy (:8000) as the browser screen instead of
# noVNC.
#
# No privileged mode: KVM comes from the squat.ai/kvm device plugin, exactly
# like the Windows/macOS VM workers. The golden qcow2 + ws-scrcpy dist are
# staged into the build context by build.sh.
ARG REGISTRY=forgejo.develop.10.199.64.20.nip.io/root

FROM ${REGISTRY}/debian:trixie-slim
ARG HTTP_PROXY=http://mihomo.develop.svc.cluster.local:7890
ARG HTTPS_PROXY=http://mihomo.develop.svc.cluster.local:7890
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20 \
    DEBIAN_FRONTEND=noninteractive

RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         tini qemu-system-x86 qemu-utils \
         android-tools-adb \
         nodejs \
         ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# easyworker (host side).
COPY --chmod=755 ./easyworker /usr/local/bin/easyworker

# ws-scrcpy dist (built in build.sh with its node_modules).
COPY ./ws-scrcpy /opt/ws-scrcpy

# BlissOS golden disk (base image).
COPY ./golden.qcow2 /vm/golden.qcow2

COPY --chmod=755 ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /data

ENV WORKER_PORT=48080 \
    WORKER_WORKSPACE=/workspace \
    WORKER_DB=/data/jobs.db \
    ANDROID_MEM=4096 \
    ANDROID_CPUS=4

EXPOSE 48080 8000
ENTRYPOINT ["/usr/bin/tini", "-s", "/usr/local/bin/entrypoint.sh"]
