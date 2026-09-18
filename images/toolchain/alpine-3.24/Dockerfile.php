# Toolchain image: PHP + Composer, Alpine.
#
# static-php-cli publishes a statically linked PHP CLI (no libc dependency), so
# it runs on musl as-is. Both artifacts are pre-downloaded (fetch-artifacts.sh)
# and COPYed.
ARG BASE_IMAGE=toolchain-base:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/php-8.5.8-cli-linux-x86_64.tar.gz /opt/php.tar.gz
COPY cache/composer.phar /opt/composer.phar
RUN mkdir -p /opt/php && tar -xzf /opt/php.tar.gz -C /opt/php && rm /opt/php.tar.gz \
 && mkdir -p /opt/php/bin 2>/dev/null || true
RUN printf '#!/bin/sh\nexec /opt/php/php /opt/composer.phar "$@"\n' > /usr/local/bin/composer \
 && chmod +x /usr/local/bin/composer
ENV PATH=/opt/php:$PATH
