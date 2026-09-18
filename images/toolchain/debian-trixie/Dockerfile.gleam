# Toolchain image: Gleam.
#
# Gleam is a statically linked musl binary (runs on glibc and musl alike); its
# package manager talks the hex protocol, so it extends the elixir toolchain to
# reuse OTP + Hex rather than downloading Erlang again.
ARG BASE_IMAGE=toolchain-elixir:debian-trixie
FROM ${BASE_IMAGE}
COPY cache/gleam-v1.18.1-x86_64-unknown-linux-musl.tar.gz /tmp/gleam.tar.gz
RUN tar -xzf /tmp/gleam.tar.gz -C /tmp && install -m755 /tmp/gleam /usr/local/bin/gleam && rm -rf /tmp/gleam /tmp/gleam.tar.gz
RUN gleam --version
