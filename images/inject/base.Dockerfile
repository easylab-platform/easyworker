# syntax=docker/dockerfile:1
# Stage 2: easylab capability injection, applied on top of a stage-1
# toolchain image. This turns any generic dev image into a self-contained
# easyworker preset by baking in:
#
#   * the easyworker binary (PID 1, its own shell)
#   * this deployment's egress MITM CA, merged into the system trust store
#   * the trust env for runtimes that ignore the system bundle
#
# The language Dockerfiles under lang/ are one-line derivatives of this file
# that only add runtime-specific bits (Java's keytool import, pip.conf, ...).
#
#   build-preset.sh base    # FROM toolchain-base
#   build-preset.sh node    # FROM toolchain-node
ARG BASE_IMAGE=forgejo.develop.10.199.64.20.nip.io/easylab/toolchain-base:latest
FROM ${BASE_IMAGE}

# Bake the deployment's egress CA into the system trust store. The context
# supplies ca.crt (extracted by extract-ca.sh from the live easylab egress-ca
# secret). This is what makes the preset zero-injection: every client that
# reads the system bundle (Go, Ruby, PHP, .NET, cargo's libcurl, Erlang, Nix,
# ...) trusts the sidecar's leaf certificates with no env and no mount.
COPY ca.crt /usr/local/share/ca-certificates/easylab-egress-ca.crt
# Keep a standalone copy for runtimes that take an explicit file path
# (Node NODE_EXTRA_CA_CERTS, Dart --root-certs-file, Hex HEX_CACERTS_PATH...).
# It deliberately lives OUTSIDE /etc/easyproxy: a pod using the preset may
# still mount the sidecar's rules as a ConfigMap at /etc/easyproxy, which
# would shadow anything baked there.
RUN install -Dm644 /usr/local/share/ca-certificates/easylab-egress-ca.crt /usr/local/share/easylab/egress-ca.crt \
    && update-ca-certificates

# Worker trust knobs for the runtimes that do NOT read the system bundle or
# need an explicit path. easyworker's job-env allowlist forwards these.
#
# They all point at the FULL system bundle (public roots + our CA), not at the
# bare egress CA: hosts that the rule set leaves `direct` still need the real
# roots, and update-ca-certificates has already merged ours into the bundle.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt \
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    COMPOSER_CAFILE=/etc/ssl/certs/ca-certificates.crt \
    DART_VM_OPTIONS=--root-certs-file=/etc/ssl/certs/ca-certificates.crt \
    UV_SYSTEM_CERTS=1
# Node ships its own bundled Mozilla root store and ignores SSL_CERT_FILE
# (--use-bundled-ca is the default); NODE_EXTRA_CA_CERTS appends ours to it.
# Point at the standalone copy (not the update-ca-certificates symlink, whose
# name is distro-generated).
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/easylab/egress-ca.crt

# easyworker as PID 1: it brings its own shell (mvdan/sh), so no shell is
# needed at runtime.
COPY easyworker /usr/local/bin/easyworker
RUN mkdir -p /workspace /data
ENV WORKER_PORT=48080 \
    WORKER_WORKSPACE=/workspace \
    WORKER_DB=/data/jobs.db
EXPOSE 48080
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/easyworker"]
