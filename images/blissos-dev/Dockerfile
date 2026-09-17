# easyworker BlissOS dev sandbox: a full Android build toolchain AND a
# KVM-accelerated Android 13 (BlissOS) guest in ONE container, with noVNC.
#
# Why one container: the worker runs on the host side (Android is a bionic
# userland and cannot run the linux/amd64 Go worker), and the same host carries
# the toolchain, so a job can build an APK with Gradle and immediately install
# and exercise it in the guest over adb. That closes the loop without an
# external CI.
#
# Layout:
#   :48080  Worker API  (WorkerService + WorkerEnroll)  host side
#   :8006   noVNC       (QEMU VNC -> websocket -> nginx -> noVNC static)
#   :5555   hostfwd to the guest adbd (internal; used by adb/jobs)
#
# Security: privileged: false; KVM is delivered by the squat.ai/kvm device
# plugin exactly like the Windows/macOS VM workers.
ARG REGISTRY=forgejo.develop.10.199.64.20.nip.io/root

FROM ${REGISTRY}/debian:trixie-slim

ARG HTTP_PROXY=http://mihomo.develop.svc.cluster.local:7890
ARG HTTPS_PROXY=http://mihomo.develop.svc.cluster.local:7890
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20 \
    DEBIAN_FRONTEND=noninteractive

ARG GRADLE_VERSION=8.13
ARG CMDLINE_TOOLS=commandlinetools-linux-11076708_latest.zip
ARG ANDROID_PLATFORM=android-35
ARG BUILD_TOOLS=35.0.0

# --- base packages --------------------------------------------------------
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && apt-get --no-install-recommends -y install \
         tini ca-certificates curl unzip xz-utils zip git less procps \
         openjdk-21-jdk-headless \
         qemu-system-x86 qemu-utils \
         novnc nginx-light \
    && rm -rf /var/lib/apt/lists/*

# --- Gradle ---------------------------------------------------------------
RUN curl -sSL -o /tmp/gradle.zip \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
    && mkdir -p /opt/gradle \
    && unzip -q /tmp/gradle.zip -d /opt/gradle \
    && rm -f /tmp/gradle.zip

# --- Android SDK ----------------------------------------------------------
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl -sSL -o /tmp/cmdtools.zip \
         "https://dl.google.com/android/repository/${CMDLINE_TOOLS}" \
    && unzip -q /tmp/cmdtools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && rm -f /tmp/cmdtools.zip \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
RUN "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
      "platform-tools" "platforms;${ANDROID_PLATFORM}" "build-tools;${BUILD_TOOLS}" \
    && rm -rf /tmp/* /var/tmp/*

# PATH is on the worker's job-env allowlist, so jobs inherit the toolchain.
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.0:/opt/gradle/gradle-8.13/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The worker's job env is a strict allowlist (PATH/HOME/TMPDIR/USER/proxies), so
# ANDROID_HOME never reaches a job. AGP also reads sdk.dir from local.properties;
# this global init script writes it on demand so `gradle` and `./gradlew` both
# work inside jobs without extra env.
RUN mkdir -p /root/.gradle/init.d
COPY --chmod=644 ./sdk-init.gradle /root/.gradle/init.d/sdk.gradle

# --- easyworker (host side) ----------------------------------------------
COPY --chmod=755 ./easyworker /usr/local/bin/easyworker

# --- BlissOS golden disk --------------------------------------------------
COPY ./golden.qcow2 /vm/golden.qcow2

# --- noVNC front (QEMU's built-in VNC websocket -> nginx :8006) -----------
COPY --chmod=644 ./novnc.conf /etc/nginx/sites-enabled/novnc
# nginx must run as root to open /run/shm/vnc-ws.sock (dockur/qemus do the same)
RUN sed -i 's/^user .*/user root;/' /etc/nginx/nginx.conf \
    && rm -f /etc/nginx/sites-enabled/default

COPY --chmod=755 ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /workspace /data

ENV WORKER_PORT=48080 \
    WORKER_WORKSPACE=/workspace \
    WORKER_DB=/data/jobs.db \
    ANDROID_MEM=4096 \
    ANDROID_CPUS=4

EXPOSE 48080 8006 5900 5555
ENTRYPOINT ["/usr/bin/tini", "-s", "/usr/local/bin/entrypoint.sh"]
