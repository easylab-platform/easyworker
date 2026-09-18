# Toolchain image: Scala (scala-cli + sbt), Alpine/musl.
ARG BASE_IMAGE=toolchain-java:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/scala-cli-x86_64-pc-linux-static.gz /tmp/scala-cli.gz
RUN gunzip -c /tmp/scala-cli.gz > /usr/local/bin/scala-cli && chmod +x /usr/local/bin/scala-cli && rm /tmp/scala-cli.gz
COPY cache/sbt-1.13.0.tgz /tmp/sbt.tgz
RUN tar -xzf /tmp/sbt.tgz -C /opt && rm /tmp/sbt.tgz
ENV PATH=/opt/sbt/bin:$PATH
RUN scala-cli version && sbt --script-version
