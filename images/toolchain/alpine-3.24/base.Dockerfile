# syntax=docker/dockerfile:1
# Stage 1: the GENERIC alpine toolchain base.
#
# Alpine 3.24 (musl, no glibc compatibility layer) plus the utilities a dev
# workflow expects. Nothing here knows about easylab: no worker binary, no
# egress CA, no trust env.
#
# Musl means glibc-only toolchains are unavailable (Swift has no musl build,
# so there is no Dockerfile.swift here); everything else uses a musl or
# static artifact. gcompat is deliberately NOT installed.
#
#   DISTRO=alpine-3.24 ./build-toolchain.sh base
ARG BASE_IMAGE=alpine:3.24
FROM ${BASE_IMAGE}

# Fast in-region mirror for the BUILD; the image is left pointing at the
# official dl-cdn.alpinelinux.org repositories.
ARG APK_MIRROR=mirrors.aliyun.com

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Base utilities every dev workflow expects. These are OS dependencies, not
# toolchains: language runtimes are installed from upstream artifacts below.
RUN set -eux; \
    printf 'https://%s/alpine/v3.24/main\nhttps://%s/alpine/v3.24/community\n' \
        "$APK_MIRROR" "$APK_MIRROR" > /etc/apk/repositories; \
    apk add --no-cache \
        ca-certificates curl wget git openssh-client xz unzip zip bzip2 zstd \
        build-base pkgconf file procps jq less gnupg bash; \
    rm -rf /var/cache/apk/*; \
    printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.24/community\n' \
        > /etc/apk/repositories
