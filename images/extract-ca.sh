#!/usr/bin/env bash
# Extract this deployment's egress MITM CA into images/ so the preset images
# can bake the certificate into their system trust store (zero-injection
# runtime).
#
# Two files are produced:
#   ca.crt   the certificate, baked into the base image (stage 2) and mounted
#            into the sidecar/trust-probe pods
#   ca.key   the matching private key, needed only by the easysidecar sidecar in
#            test-preset.sh (never baked into an image; gitignored)
#
# Source of truth: easylab generates and persists it under $EASYVCS_HOME/egress-ca
# (default /data/egress-ca) on first start.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-temp}"
DEPLOY="${DEPLOY:-easylab}"
REMOTE_DIR="${EGRESS_CA_REMOTE_DIR:-/data/egress-ca}"

if [ -n "${EGRESS_CA_DIR:-}" ]; then
  cp "$EGRESS_CA_DIR/ca.crt" "$HERE/ca.crt"
  cp "$EGRESS_CA_DIR/ca.key" "$HERE/ca.key"
else
  kubectl -n "$NS" exec "deploy/$DEPLOY" -- cat "$REMOTE_DIR/ca.crt" > "$HERE/ca.crt"
  kubectl -n "$NS" exec "deploy/$DEPLOY" -- cat "$REMOTE_DIR/ca.key" > "$HERE/ca.key"
fi
chmod 600 "$HERE/ca.key"

head -1 "$HERE/ca.crt" | grep -q "BEGIN CERTIFICATE" || {
  echo "extract-ca: $HERE/ca.crt does not look like a PEM certificate" >&2
  exit 1
}
grep -q "PRIVATE KEY" "$HERE/ca.key" || {
  echo "extract-ca: $HERE/ca.key does not look like a PEM private key" >&2
  exit 1
}
echo "wrote $HERE/ca.crt ($(grep -c 'BEGIN CERTIFICATE' "$HERE/ca.crt") cert(s)) and ca.key"
