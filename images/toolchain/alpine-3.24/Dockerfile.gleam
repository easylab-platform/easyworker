# Toolchain image: Gleam, Alpine/musl.
#
# Gleam is a statically linked musl binary. Its package manager talks the hex
# protocol, but there is no alpine elixir/OTP image to extend, so it sits on the
# base; `gleam build` still needs an Erlang runtime at run time, which projects
# install through the hex protocol or bring themselves.
ARG BASE_IMAGE=toolchain-base:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/gleam-v1.18.1-x86_64-unknown-linux-musl.tar.gz /tmp/gleam.tar.gz
RUN tar -xzf /tmp/gleam.tar.gz -C /tmp && install -m755 /tmp/gleam /usr/local/bin/gleam && rm -rf /tmp/gleam /tmp/gleam.tar.gz
RUN gleam --version
