#!/usr/bin/env bash
# Smoke-test a preset image end-to-end: run it as a pod with the egress
# sidecar and NOTHING else injected (no worker hostPath, no CA env/volumes
# from the control plane), then drive the worker API with trust-sensitive
# client commands for that language.
#
#   NS=temp RULES_CM=ewpreset-rules ./test-preset.sh node
#   NS=temp RULES_CM=ewpreset-rules ./test-preset.sh java "only=java cacerts"
#
# The image must already have the CA baked in (see extract-ca.sh / base
# Dockerfile): if the pod only works because the control plane injected trust,
# this script would still pass, so it deliberately injects none.
#
# Requires the deployment CA (ca.crt, from extract-ca.sh) and a sidecar
# ConfigMap (RULES_CM) whose rules point the language's upstreams at the
# artifact service.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANG="${1:?usage: test-preset.sh <lang> [tag] [extra trustprobe args]}"
TAG="${2:-latest}"
shift $(( $# > 1 ? 2 : 1 ))
NS="${NS:-temp}"
IMAGE="${IMAGE:-forgejo.develop.10.199.64.20.nip.io/easylab/easyworker-${LANG}:${TAG}}"
NAME="${NAME:-ewtest-${LANG}}"
CA_SECRET="${CA_SECRET:-ewtest-ca}"
RULES_CM="${RULES_CM:?set RULES_CM to a ConfigMap holding rules.yaml for the sidecar}"
EASYSIDECAR_IMAGE="${EASYSIDECAR_IMAGE:-forgejo.develop.10.199.64.20.nip.io/easylab/easysidecar:v0.6.0}"
UPSTREAM_DNS="${UPSTREAM_DNS:-172.18.0.10}"
UPSTREAM_PROXY="${UPSTREAM_PROXY:-http://mihomo.develop.svc.cluster.local:7890}"

# The CA secret must hold the SAME CA the sidecar signs with; extract-ca.sh
# writes it to ca.crt, and the base image baked it in.
[ -f "${HERE}/ca.crt" ] || { echo "missing ${HERE}/ca.crt (run ./extract-ca.sh)"; exit 1; }
[ -f "${HERE}/ca.key" ] || { echo "missing ${HERE}/ca.key (run ./extract-ca.sh)"; exit 1; }
kubectl -n "$NS" create secret generic "$CA_SECRET" \
  --from-file=ca.crt="${HERE}/ca.crt" --from-file=ca.key="${HERE}/ca.key" \
  --dry-run=client -o yaml | kubectl apply -n "$NS" -f - >/dev/null

kubectl -n "$NS" delete pod "$NAME" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1
cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${NAME}, labels: { app: ${NAME} } }
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers: ["127.0.0.1"]
    searches: ["${NS}.svc.cluster.local", "svc.cluster.local", "cluster.local"]
    options: [{ name: ndots, value: "5" }]
  containers:
  - name: worker
    image: ${IMAGE}
    imagePullPolicy: Always
    env:
    - { name: WORKER_REQUIRE_AUTH, value: "0" }
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits: { cpu: "2", memory: 4Gi }
  - name: easysidecar
    image: ${EASYSIDECAR_IMAGE}
    args: ["--mode=proxy","--rules=/etc/easysidecar/rules.yaml","--spoof","--spoof-dns-addr=0.0.0.0:53","--spoof-tls-addr=0.0.0.0:443","--spoof-http-addr=0.0.0.0:80","--upstream-dns=${UPSTREAM_DNS}","--upstream-proxy=${UPSTREAM_PROXY}","--ca-cert=/etc/easysidecar/ca/ca.crt","--ca-key=/etc/easysidecar/ca/ca.key"]
    env: [{ name: POD_IP, valueFrom: { fieldRef: { fieldPath: status.podIP } } }]
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits: { cpu: 500m, memory: 256Mi }
    volumeMounts:
    - { name: rules, mountPath: /etc/easysidecar, readOnly: true }
    - { name: ca, mountPath: /etc/easysidecar/ca, readOnly: true }
  volumes:
  - { name: rules, configMap: { name: ${RULES_CM} } }
  - { name: ca, secret: { secretName: ${CA_SECRET} } }
YAML
kubectl -n "$NS" wait --for=condition=Ready "pod/${NAME}" --timeout=180s >/dev/null
IP="$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.status.podIP}')"
echo "pod ${NAME} -> ${IP}:48080"
"${HERE}/../dist/trustprobe-linux-amd64" -addr "http://${IP}:48080" "$@"
echo "kept pod ${NAME} (delete with: kubectl -n ${NS} delete pod ${NAME})"
