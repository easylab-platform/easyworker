# Toolchain image: C/C++ build tooling (CMake + Ninja + Meson).
#
# Not a language runtime: the compilers and make come from the base image's
# build-essential. This adds the cross-platform generators that modern C/C++
# projects expect, plus Python for Meson.
ARG BASE_IMAGE=toolchain-base:debian-trixie
FROM ${BASE_IMAGE}
COPY cache/cmake-4.4.3-linux-x86_64.tar.gz /tmp/cmake.tar.gz
RUN mkdir -p /opt/cmake && tar -xzf /tmp/cmake.tar.gz -C /opt/cmake --strip-components=1 && rm /tmp/cmake.tar.gz
COPY cache/ninja-linux.zip /tmp/ninja.zip
RUN unzip -q /tmp/ninja.zip -d /usr/local/bin && chmod +x /usr/local/bin/ninja && rm /tmp/ninja.zip
ENV PATH=/opt/cmake/bin:$PATH
# Meson is a pure-Python generator; python3 + meson are OS packages, not a
# language toolchain, so they come from apt. The in-region mirror is used for
# the build and the official sources are restored afterwards.
RUN set -eux; \
    . /etc/os-release; \
    printf 'Types: deb\nURIs: http://mirrors.aliyun.com/debian\nSuites: %s %s-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://mirrors.aliyun.com/debian-security\nSuites: %s-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
        "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Retries=10 update; \
    apt-get -o Acquire::Retries=10 install -y --no-install-recommends python3 meson; \
    rm -rf /var/lib/apt/lists/*; \
    printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: %s %s-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://deb.debian.org/debian-security\nSuites: %s-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
        "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list.d/debian.sources
RUN cmake --version | head -1 && ninja --version && meson --version
