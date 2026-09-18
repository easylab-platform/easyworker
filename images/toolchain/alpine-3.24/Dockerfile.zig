# Toolchain image: Zig, Alpine/musl.
#
# Zig ships a fully static binary, so the same tarball works on musl.
ARG BASE_IMAGE=toolchain-base:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/zig-x86_64-linux-0.16.0.tar.xz /tmp/zig.tar.xz
RUN mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
RUN zig version
