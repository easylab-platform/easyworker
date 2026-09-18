# Toolchain image: Lua + LuaRocks, Alpine/musl (source builds).
ARG BASE_IMAGE=toolchain-base:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/lua-5.5.1.tar.gz /tmp/lua.tar.gz
RUN set -eux; \
    tar -xzf /tmp/lua.tar.gz -C /tmp && rm /tmp/lua.tar.gz; \
    cd /tmp/lua-5.5.1; \
    make linux MYCFLAGS=-fPIC; \
    make install INSTALL_TOP=/opt/lua; \
    cd /; rm -rf /tmp/lua-5.5.1
COPY cache/luarocks-3.13.0.tar.gz /tmp/luarocks.tar.gz
RUN set -eux; \
    tar -xzf /tmp/luarocks.tar.gz -C /tmp && rm /tmp/luarocks.tar.gz; \
    cd /tmp/luarocks-3.13.0; \
    ./configure --prefix=/opt/luarocks --with-lua=/opt/lua --lua-version=5.4; \
    make; \
    make install; \
    cd /; rm -rf /tmp/luarocks-3.13.0
ENV PATH=/opt/lua/bin:/opt/luarocks/bin:$PATH
RUN lua -v && luarocks --version
