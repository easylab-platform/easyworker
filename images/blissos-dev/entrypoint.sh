#!/usr/bin/env bash
set -Eeuo pipefail

# easyworker BlissOS dev sandbox entrypoint.
#
# One container holds BOTH the Android build toolchain and a KVM-accelerated
# BlissOS (Android 13, x86_64) guest. The easyworker binary runs on the host
# side (Android cannot run the linux/amd64 Go worker) and drives the guest over
# adb, so a job can `gradle assembleDebug` and then `adb install` the result.
#
#   QEMU (accel=kvm) --hostfwd tcp:5555--> guest adbd
#     -> adb                (used by easyworker jobs)
#     -> VNC websocket -> nginx :8006 -> noVNC
#   easyworker :48080         (token from $WORKER_TOKEN)

STORAGE=/data
GOLDEN=/vm/golden.qcow2
DISK="$STORAGE/data.qcow2"
QDIR=/run/shm
ADB="adb -s 127.0.0.1:5555"

MEM="${ANDROID_MEM:-4096}"
CPUS="${ANDROID_CPUS:-4}"

export ANDROID_ADB_SERVER_PORT=5037

mkdir -p "$STORAGE" "$QDIR" /workspace

# --- writable overlay on the read-only golden -----------------------------
if [ ! -s "$DISK" ]; then
  echo "android: creating per-container disk from golden"
  qemu-img create -f qcow2 -F qcow2 -b "$GOLDEN" "$DISK"
fi

# --- noVNC front ----------------------------------------------------------
nginx -e stderr || { echo "android: nginx failed to start" >&2; exit 1; }

# --- QEMU with VNC + websocket (same shape as the qemus/dockur images) ----
echo "android: starting QEMU (kvm, ${CPUS} vCPU, ${MEM} MB)"
qemu-system-x86_64 \
  -machine pc,accel=kvm,hpet=off,smm=off,graphics=on,vmport=off,usb=on \
  -cpu host \
  -m "$MEM" -smp "$CPUS" \
  -drive file="$DISK",format=qcow2,if=virtio,discard=unmap,detect-zeroes=unmap \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555 \
  -device virtio-net-pci,netdev=net0 \
  -vga std -device usb-tablet \
  -display vnc=:0,websocket=unix:$QDIR/vnc-ws.sock \
  -monitor unix:$QDIR/monitor.sock,server=on,wait=off,nodelay=on \
  -serial file:/tmp/serial.log -pidfile $QDIR/qemu.pid \
  >/tmp/qemu.err 2>&1 &
QEMU_PID=$!

adb start-server >/dev/null 2>&1 || true

cleanup() {
  kill "${WORKER_PID:-}" "${QEMU_PID:-}" 2>/dev/null || true
}
trap cleanup TERM INT

# --- wait for the guest, then start the worker ----------------------------
echo "android: waiting for adbd + boot_completed"
booted=""
for _ in $(seq 1 180); do
  if adb connect 127.0.0.1:5555 >/dev/null 2>&1; then
    bc="$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [ "$bc" = "1" ]; then booted="1"; break; fi
  fi
  sleep 5
done

if [ -z "$booted" ]; then
  echo "android: guest did not reach boot_completed" >&2
  tail -40 /tmp/serial.log >&2 || true
  exit 1
fi

echo "android: guest is up"

# Keep the display awake and dismiss the keyguard so VNC always shows the UI.
$ADB shell "svc power stayon true" >/dev/null 2>&1 || true
$ADB shell "settings put system screen_off_timeout 2147483647" >/dev/null 2>&1 || true
$ADB shell "wm dismiss-keyguard" >/dev/null 2>&1 || true

# Hand the resolved adb target to jobs (jobEnv is an allowlist, so this is the
# process environment the worker is started with).
export ANDROID_SERIAL="127.0.0.1:5555"

echo "android: starting easyworker on :${WORKER_PORT:-48080}"
easyworker &
WORKER_PID=$!

wait "$WORKER_PID"
