# syntax=docker/dockerfile:1
# Stage 1: the GENERIC toolchain base.
#
# Plain Debian trixie slim plus the utilities a dev workflow expects. Nothing
# here knows about easylab: no worker binary, no egress CA, no trust env. Use
# it (or a language image built on it) directly as `docker run` dev shells, or
# let stage 2 (../inject/base.Dockerfile) turn it into an easyworker preset.
#
#   build-toolchain.sh base   # ./Dockerfile -> ${TOOLCHAIN_REPO}-base
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}


ARG APT_MIRROR=mirrors.aliyun.com

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

# Base utilities every dev workflow expects. Restore the OFFICIAL Debian
# sources afterwards: at runtime the spoofed sidecar intercepts
# deb.debian.org, and the fast in-region mirror is only needed for the build.
RUN set -eux; \
    . /etc/os-release; \
    case "${VERSION_CODENAME:-trixie}" in \
      trixie) SUITES="trixie trixie-updates"; SEC="trixie-security" ;; \
      *)      SUITES="bookworm bookworm-updates"; SEC="bookworm-security" ;; \
    esac; \
    printf 'Types: deb\nURIs: http://%s/debian\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://%s/debian-security\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
        "$APT_MIRROR" "$SUITES" "$APT_MIRROR" "$SEC" > /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Retries=10 update; \
    for i in 1 2 3 4 5 6; do \
      apt-get -o Acquire::Retries=10 install -y --no-install-recommends \
        ca-certificates curl wget git openssh-client xz-utils unzip zip bzip2 zstd \
        build-essential pkg-config file procps jq less gnupg \
      && break || { echo "apt retry $i"; sleep 3; }; \
    done; \
    rm -rf /var/lib/apt/lists/*; \
    printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://deb.debian.org/debian-security\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
        "$SUITES" "$SEC" > /etc/apt/sources.list.d/debian.sources
