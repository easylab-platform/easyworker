# syntax=docker/dockerfile:1
# easyworker Linux labwc desktop sandbox: a headless wlroots compositor with
# wayvnc + noVNC for a browser view, and the easyworker Worker API on :48080.
#
# Pure Wayland: no Xwayland, no DISPLAY, no X11 client libraries are required
# by the session itself. (GTK/Qt may still pull in some X11 libs transitively,
# but nothing in this image enables or uses them.)
# Build context must contain ./easyworker (the linux/amd64 v0.5.2 binary);
# build.sh stages it before calling buildctl.
ARG REGISTRY=forgejo.develop.10.199.64.20.nip.io/root

FROM ${REGISTRY}/debian:trixie-slim
ARG HTTP_PROXY=http://mihomo.develop.svc.cluster.local:7890
ARG HTTPS_PROXY=http://mihomo.develop.svc.cluster.local:7890
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20 \
    DEBIAN_FRONTEND=noninteractive

# aliyun mirror (matches the other images built in this cluster)
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         tini labwc wayvnc foot \
         novnc websockify \
         fonts-dejavu fonts-noto-cjk \
         libgtk-3-0 libglib2.0-0 \
         libwayland-client0 libxkbcommon0 \
         libegl1 libgles2 libgl1 libgbm1 libgl1-mesa-dri mesa-utils \
         wayland-utils \
         ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Worker binary (linux/amd64).
COPY --chmod=755 ./easyworker /usr/local/bin/easyworker

# Desktop session.
COPY --chmod=755 ./entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=644 ./rc.xml /etc/labwc/rc.xml
# PATH is on the worker's job-env allowlist: putting gui-run here gives
# GUI programs a zero-config way to reach the compositor.
COPY --chmod=755 ./gui-run /opt/session-bin/gui-run
ENV PATH=/opt/session-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN mkdir -p /workspace /data

ENV WORKER_PORT=48080 \
    WORKER_WORKSPACE=/workspace \
    WORKER_DB=/data/jobs.db

EXPOSE 48080 5900 6080
ENTRYPOINT ["/usr/bin/tini", "-s", "/usr/local/bin/entrypoint.sh"]
