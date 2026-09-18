# Toolchain image: Groovy (+ Gradle, the standard Groovy build tool).
#
# Extends the java toolchain (JDK + Gradle + cacerts trust).
ARG BASE_IMAGE=toolchain-java:debian-trixie
FROM ${BASE_IMAGE}
COPY cache/apache-groovy-binary-4.0.33.zip /tmp/groovy.zip
RUN unzip -q /tmp/groovy.zip -d /opt && rm /tmp/groovy.zip && ln -s /opt/groovy-4.0.33 /opt/groovy
ENV PATH=/opt/groovy/bin:$PATH
RUN groovy --version
