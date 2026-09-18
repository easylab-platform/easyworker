# Toolchain image: JDK + Gradle.
#
# Both artifacts are pre-downloaded (fetch-artifacts.sh) and COPYed. Gradle is a
# pure-java distribution, so the distro-specific part is only the JDK.
ARG BASE_IMAGE=toolchain-base:debian-trixie
FROM ${BASE_IMAGE}
COPY cache/OpenJDK25U-jdk_x64_linux_hotspot_25.0.4.1_1.tar.gz /tmp/jdk.tar.gz
COPY cache/gradle-9.7.1-bin.zip /tmp/gradle.zip
RUN mkdir -p /opt/jdk && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk --strip-components=1 && rm /tmp/jdk.tar.gz \
 && unzip -q /tmp/gradle.zip -d /opt && rm /tmp/gradle.zip \
 && ln -s /opt/gradle-9.7.1 /opt/gradle
ENV JAVA_HOME=/opt/jdk PATH=/opt/jdk/bin:/opt/gradle/bin:$PATH
