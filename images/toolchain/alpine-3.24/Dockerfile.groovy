# Toolchain image: Groovy (+ Gradle), Alpine/musl.
ARG BASE_IMAGE=toolchain-java:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/apache-groovy-binary-4.0.33.zip /tmp/groovy.zip
RUN unzip -q /tmp/groovy.zip -d /opt && rm /tmp/groovy.zip && ln -s /opt/groovy-4.0.33 /opt/groovy
ENV PATH=/opt/groovy/bin:$PATH
RUN groovy --version
