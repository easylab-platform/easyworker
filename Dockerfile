# syntax=docker/dockerfile:1
# easyworker: single static Go binary, Connect RPC (worker.v1.WorkerService).
# Built via the cluster buildkitd (./build-image.sh), pushed to forgejo.
#
# The runtime image deliberately ships NO shell: easyworker brings its own
# (mvdan.cc/sh interp) — alpine is here only for ca-certificates + curl
# (in-cluster verification). The same binary is injected into arbitrary
# sandbox base images, including scratch/distroless.
ARG REGISTRY=forgejo.develop.10.199.64.20.nip.io/root

FROM ${REGISTRY}/golang:1.26-alpine AS build
ARG HTTP_PROXY=http://mihomo.develop.svc.cluster.local:7890
ARG HTTPS_PROXY=http://mihomo.develop.svc.cluster.local:7890
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20 \
    GOPROXY=https://proxy.golang.org \
    CGO_ENABLED=0 \
    GOWORK=off
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN go build -trimpath -ldflags "-s -w" -o /out/easyworker ./cmd/easyworker

FROM ${REGISTRY}/alpine:3.24
ARG HTTP_PROXY=http://mihomo.develop.svc.cluster.local:7890
ARG HTTPS_PROXY=http://mihomo.develop.svc.cluster.local:7890
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories \
    && apk add --no-cache ca-certificates curl
COPY --from=build /out/easyworker /usr/local/bin/easyworker
RUN mkdir -p /workspace /data
ENV WORKER_PORT=8080 \
    WORKER_WORKSPACE=/workspace \
    WORKER_DB=/data/jobs.db
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/easyworker"]
