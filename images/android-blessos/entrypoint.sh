#!/usr/bin/env bash
set -Eeuo pipefail

# EasyWorker Android (BlissOS) sandbox.
#
# A KVM-accelerated BlissOS 16 (Android 13, x86_64) golden image runs under
# QEMU. The easyworker binary runs on the HOST side of the container (Android
# cannot run the linux/amd64 Go worker) and drives the guest through `adb`.
# ws-scrcpy serves the live screen to a browser on :8000 (instead of noVNC).
#
#   QEMU (accel=kvm) --hostfwd tcp:5555--> guest adbd
#     -> adb (used by easyworker jobs)
#     -> ws-scrcpy :8000  (Node + adb)
#   easyworker :48080   (token from $WORKER_TOKEN)

export ANDROID_ADB_SERVER_PORT=5037
ADB="adb -s 127.0.0.1:5555"
GOLDEN=/vm/golden.qcow2
WORKDISK=/data/android.qcow2
MEM="${ANDROID_MEM:-4096}"
CPUS="${ANDROID_CPUS:-4}"

mkdir -p /data
# Overlay the golden read-only base into a writable per-pod disk.
if [ ! -e "$WORKDISK" ]; then
  echo "android: creating per-pod disk from golden"
  qemu-img create -f qcow2 -F qcow2 -b "$GOLDEN" "$WORKDISK" >/dev/null
fi

start_adb() {
  adb start-server >/dev/null 2>&1 || true
}

start_qemu() {
  echo "android: starting QEMU (kvm, ${CPUS} vCPU, ${MEM} MB)"
  qemu-system-x86_64 \
    -machine pc,accel=kvm,hpet=off,smm=off,graphics=on,vmport=off,usb=on \
    -cpu host \
    -m "$MEM" -smp "$CPUS" \
    -drive file="$WORKDISK",format=qcow2,if=virtio,discard=unmap,detect-zeroes=unmap \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555 \
    -device virtio-net-pci,netdev=net0 \
    -vga std -display none -device usb-tablet \
    -serial file:/tmp/serial.log -pidfile /tmp/qemu.pid \
    >/tmp/qemu.err 2>&1 &
  QEMU_PID=$!
}

wait_boot() {
  echo "android: waiting for adbd + boot_completed"
  for _ in $(seq 1 120); do
    adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
    bc="$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [ "$bc" = "1" ] && return 0
    sleep 5
  done
  echo "android: guest did not reach boot_completed" >&2
  tail -40 /tmp/serial.log >&2 || true
  return 1
}

cleanup() {
  kill "${WS_PID:-}" "${WORKER_PID:-}" "${QEMU_PID:-}" 2>/dev/null || true
}
trap cleanup TERM INT

start_adb
start_qemu
wait_boot || exit 1

# Keep the guest awake (the golden already sets this, belt and braces).
$ADB shell "svc power stayon true" >/dev/null 2>&1 || true

echo "android: starting ws-scrcpy on :8000"
cd /opt/ws-scrcpy
PORT=8000 node index.js >/tmp/ws-scrcpy.log 2>&1 &
WS_PID=$!

echo "android: starting easyworker on :48080"
easyworker &
WORKER_PID=$!

wait "$WORKER_PID"
