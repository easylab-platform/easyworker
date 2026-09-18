# Toolchain image: Perl (core perl + cpanminus).
#
# Perl itself is the distro perl (base image); cpanminus plus App::cpanminus is
# added from source so CPAN installs work. CPAN is a plain HTTP tree
# (02packages + tarballs), with no artifact protocol.
ARG BASE_IMAGE=toolchain-base:debian-trixie
FROM ${BASE_IMAGE}
COPY cache/App-cpanminus-1.7049.tar.gz /tmp/cpanm.tar.gz
RUN set -eux; \
    tar -xzf /tmp/cpanm.tar.gz -C /tmp && rm /tmp/cpanm.tar.gz; \
    cd /tmp/App-cpanminus-1.7049; \
    perl Makefile.PL; \
    make; \
    make install; \
    cd /; rm -rf /tmp/App-cpanminus-1.7049
# OpenSSL-backed CPAN clients read the system bundle; ensure the tools see it.
ENV PERL_MM_USE_DEFAULT=1
RUN cpanm --version
