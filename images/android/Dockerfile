# easyworker Android sandbox: the official Android Emulator (AOSP) with an
# Android build toolchain in the same container, viewable in a browser.
#
# One container = build toolchain (JDK 21, Gradle, Android SDK) + a
# KVM-accelerated Android x86_64 emulator driven by adb. A job can therefore
# `gradle assembleDebug`, `adb install` and `am start` in one place.
#
# Screen:
#   Xvfb :99  ->  emulator Qt window  ->  x11vnc :5900
#     ->  websockify :6081  ->  nginx :6080 (noVNC)   -> browser
#
# The emulator only ships an X11 (xcb) Qt plugin, so a virtual X server is the
# supported path; no Wayland compositor is involved.
#
# Layout:
#   :48080  Worker API
#   :6080   noVNC (browser screen)
#   :5555   emulator adbd (internal; jobs use it over adb)
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
ARG SYSTEM_IMAGE=system-images;android-35;google_apis;x86_64

# --- packages -------------------------------------------------------------
# java: build toolchain.  xvfb/x11vnc: virtual X + VNC for the emulator
# window.  lib*: the emulator's shared-library dependencies.  novnc/websockify/
# nginx: the browser client.  Use the aliyun mirror (fast from this cluster).
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         tini ca-certificates curl unzip xz-utils zip git less procps \
         openjdk-21-jdk-headless \
         xvfb x11vnc x11-utils xdotool \
         novnc websockify nginx-light \
         fonts-dejavu fonts-noto-cjk \
         libasound2 libpulse0 libnss3 \
         libx11-6 libx11-xcb1 libxcb1 libxcb-dri3-0 libxcb-glx0 \
         libxcb-present0 libxcb-randr0 libxcb-render0 libxcb-shape0 \
         libxcb-shm0 libxcb-sync1 libxcb-xfixes0 \
         libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 \
         libxi6 libxkbcommon0 libxkbfile1 libxrandr2 libxrender1 libxtst6 \
         libegl1 libgl1 libglu1-mesa libglx0 libgl1-mesa-dri libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# --- Gradle ---------------------------------------------------------------
RUN curl -sSL -o /tmp/gradle.zip \
      "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
    && mkdir -p /opt/gradle \
    && unzip -q /tmp/gradle.zip -d /opt/gradle \
    && rm -f /tmp/gradle.zip

# --- Android SDK + emulator ----------------------------------------------
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
      "platform-tools" "emulator" \
      "platforms;${ANDROID_PLATFORM}" "build-tools;${BUILD_TOOLS}" \
      "${SYSTEM_IMAGE}" \
    && rm -rf /tmp/* /var/tmp/*

# PATH is on the worker's job-env allowlist, so jobs inherit the toolchain.
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:/opt/gradle/gradle-8.13/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The worker's job env is a strict allowlist, so ANDROID_HOME never reaches a
# job. AGP reads sdk.dir from local.properties; write it on demand.
RUN mkdir -p /root/.gradle/init.d
COPY --chmod=644 ./sdk-init.gradle /root/.gradle/init.d/sdk.gradle

# --- easyworker (host side) ----------------------------------------------
COPY --chmod=755 ./easyworker /usr/local/bin/easyworker

# --- browser screen -------------------------------------------------------
# nginx-light's main config already includes /etc/nginx/sites-enabled/*.
COPY --chmod=644 ./nginx.conf /etc/nginx/sites-enabled/android
RUN rm -f /etc/nginx/sites-enabled/default

COPY --chmod=755 ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /workspace /data

ENV WORKER_PORT=48080 \
    WORKER_WORKSPACE=/workspace \
    WORKER_DB=/data/jobs.db \
    ANDROID_MEM=4096 \
    ANDROID_CPUS=4 \
    ANDROID_AVD=sandbox

EXPOSE 48080 6080 5900 5555
ENTRYPOINT ["/usr/bin/tini", "-s", "/usr/local/bin/entrypoint.sh"]
