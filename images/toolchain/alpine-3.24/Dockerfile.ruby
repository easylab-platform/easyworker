# Toolchain image: Ruby, Alpine.
#
# ruby-builder only ships glibc builds, so Ruby is compiled from source
# (musl). The source tarball is pre-downloaded (fetch-artifacts.sh) and COPYed;
# build deps come from apk (OS packages, not toolchains).
ARG BASE_IMAGE=toolchain-base:alpine-3.24
FROM ${BASE_IMAGE}
RUN apk add --no-cache \
      gmp-dev yaml-dev zlib-dev openssl-dev libffi-dev readline-dev \
      ncurses-dev gdbm-dev linux-headers
COPY cache/ruby-4.0.7.tar.gz /tmp/ruby.tar.gz
RUN set -eux; \
    tar -xzf /tmp/ruby.tar.gz -C /tmp && rm /tmp/ruby.tar.gz; \
    cd /tmp/ruby-4.0.7; \
    ./configure --prefix=/opt/ruby --disable-install-doc --with-openssl-dir=/usr; \
    make -j"$(nproc)"; \
    make install; \
    cd /; rm -rf /tmp/ruby-4.0.7
ENV PATH=/opt/ruby/bin:$PATH \
    LD_LIBRARY_PATH=/opt/ruby/lib
