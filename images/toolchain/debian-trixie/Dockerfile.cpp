# Toolchain image: modern C/C++ on Clang + libc++ (C++26).
#
# Extends the `cc` image (gcc + CMake + Ninja + Meson + python3) with the
# upstream LLVM toolchain: Clang, libc++/libc++abi/libunwind, compiler-rt,
# OpenMP, lld and the clang tools (clangd/clang-tidy/clang-format).
#
# Why apt.llvm.org: Debian trixie ships clang-22 at most and does not package
# libc++ at all (it is a first-class part of the LLVM APT repo). The `-23`
# suite is the stable 23.1.x release line (`llvm-toolchain-trixie` without a
# number is the development trunk). All packages land under /usr/lib/llvm-23
# with /usr/bin/<tool>-23 entry points; the unversioned names are wired up with
# update-alternatives so `clang`/`clang++` are the default compilers.
#
# libc++ is the default C++ standard library (CXXFLAGS/LDFLAGS, which CMake
# seeds CMAKE_CXX_FLAGS / CMAKE_EXE_LINKER_FLAGS from): it is what tracks
# C++26 library features, and the image exists to build modern C++. libstdc++
# stays installed (base image) for projects that need it — build with
# `-stdlib=libstdc++` or unset CXXFLAGS.
ARG BASE_IMAGE=toolchain-cc:debian-trixie
FROM ${BASE_IMAGE}

# Pinned LLVM release line; bump LLVM_MAJOR to move to a newer stable.
ARG LLVM_MAJOR=23
# In-region mirrors used during the build, restored to the official sources
# afterwards (same policy as the base image): apt.llvm.org is slow from the
# build host, the Debian packages come from the Debian mirror.
ARG LLVM_MIRROR=mirrors.tuna.tsinghua.edu.cn/llvm-apt

RUN set -eux; \
    . /etc/os-release; \
    printf 'Types: deb\nURIs: http://mirrors.aliyun.com/debian\nSuites: %s %s-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://mirrors.aliyun.com/debian-security\nSuites: %s-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
        "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list.d/debian.sources; \
    install -d -m0755 /etc/apt/keyrings; \
    # The signing key only exists on apt.llvm.org (mirrors don't carry it), but
    # it is ~3 KB, so even the slow direct route costs nothing.
    curl -fSL --retry 5 https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/llvm.gpg; \
    printf 'Types: deb\nURIs: https://%s/%s\nSuites: llvm-toolchain-%s-%s\nComponents: main\nSigned-By: /etc/apt/keyrings/llvm.gpg\n' \
        "$LLVM_MIRROR" "$VERSION_CODENAME" "$VERSION_CODENAME" "$LLVM_MAJOR" > /etc/apt/sources.list.d/llvm.sources; \
    LLVM_PKGS=""; \
    for p in clang lld clang-tools clangd clang-format; do \
      LLVM_PKGS="$LLVM_PKGS $p-$LLVM_MAJOR"; \
    done; \
    for p in libc++ libc++abi libunwind libclang-rt libomp; do \
      LLVM_PKGS="$LLVM_PKGS $p-$LLVM_MAJOR-dev"; \
    done; \
    apt-get -o Acquire::Retries=10 update; \
    apt-get -o Acquire::Retries=10 install -y --no-install-recommends $LLVM_PKGS; \
    rm -rf /var/lib/apt/lists/*; \
    printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: %s %s-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: http://deb.debian.org/debian-security\nSuites: %s-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
        "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list.d/debian.sources; \
    printf 'Types: deb\nURIs: https://apt.llvm.org/%s\nSuites: llvm-toolchain-%s-%s\nComponents: main\nSigned-By: /etc/apt/keyrings/llvm.gpg\n' \
        "$VERSION_CODENAME" "$VERSION_CODENAME" "$LLVM_MAJOR" > /etc/apt/sources.list.d/llvm.sources

# Unversioned entry points for every LLVM tool that ships one, so `clang`,
# `clangd`, `clang-format`, `lld`, ... just work.
RUN set -eux; \
    for t in clang clang++ clang-cpp clang-cl clang-tidy clang-apply-replacements \
             clangd clang-format clang-format-diff clang-rename clang-check \
             lld ld.lld lld-link wasm-ld; do \
      [ -x "/usr/bin/$t-$LLVM_MAJOR" ] || [ -e "/usr/lib/llvm-$LLVM_MAJOR/bin/$t" ] || continue; \
      if [ -e "/usr/lib/llvm-$LLVM_MAJOR/bin/$t" ] && [ ! -e "/usr/bin/$t-$LLVM_MAJOR" ]; then \
        ln -s "/usr/lib/llvm-$LLVM_MAJOR/bin/$t" "/usr/bin/$t-$LLVM_MAJOR"; \
      fi; \
      update-alternatives --install "/usr/bin/$t" "$t" "/usr/bin/$t-$LLVM_MAJOR" 100; \
    done

# clang + libc++ + lld are the defaults; CMake picks CXX up for its compilers
# and CXXFLAGS/LDFLAGS for its flags, so a bare `cmake` build is libc++/lld.
ENV CC=clang \
    CXX=clang++ \
    CXXFLAGS="-stdlib=libc++" \
    LDFLAGS="-stdlib=libc++ -fuse-ld=lld"

# C++26 smoke test: pack indexing (P2662, C++26) + std::println (<print>),
# compiled and run with the default (libc++/lld) configuration.
RUN set -eux; \
    mkdir -p /tmp/cpp26; \
    printf '%s\n' \
        '#include <print>' \
        '#include <type_traits>' \
        'template <class... Ts> struct first { using type = Ts...[0]; };' \
        'int main() {' \
        '  static_assert(__cplusplus >= 202400L, "C++26 not enabled");' \
        '  static_assert(std::is_same_v<first<int, char>::type, int>, "pack indexing");' \
        '  std::println("cpp{} clang{} libc++ ok", __cplusplus / 100, __clang_major__);' \
        '}' > /tmp/cpp26/main.cpp; \
    clang++ -std=c++26 /tmp/cpp26/main.cpp -o /tmp/cpp26/app; \
    /tmp/cpp26/app; \
    printf '%s\n' \
        'cmake_minimum_required(VERSION 3.30)' \
        'project(cpp26check CXX)' \
        'set(CMAKE_CXX_STANDARD 26)' \
        'set(CMAKE_CXX_STANDARD_REQUIRED ON)' \
        'set(CMAKE_CXX_EXTENSIONS OFF)' \
        'add_executable(cpp26check main.cpp)' > /tmp/cpp26/CMakeLists.txt; \
    cmake -S /tmp/cpp26 -B /tmp/cpp26/build -G Ninja > /dev/null; \
    cmake --build /tmp/cpp26/build; \
    /tmp/cpp26/build/cpp26check; \
    rm -rf /tmp/cpp26
RUN clang++ --version | head -1 && cmake --version | head -1 && ninja --version
