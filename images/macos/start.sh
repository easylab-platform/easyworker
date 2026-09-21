#!/usr/bin/env bash
set -Eeuo pipefail

# EasyWorker: publish the pod-provided WORKER_TOKEN so the guest can fetch it
# over nginx at http://host.lan:8090/token. When WORKER_TOKEN is unset the file
# is empty and the guest's launcher falls back to a random one-time code.
printf '%s' "${WORKER_TOKEN:-}" > /run/shm/token
chmod 644 /run/shm/token 2>/dev/null || true

return 0
