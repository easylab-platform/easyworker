#!/usr/bin/env bash
set -Eeuo pipefail

# easyworker Android sandbox entrypoint.
#
#   emulator -no-window  ->  scrcpy-server  ->  bridge (WebSocket)  -> browser
#   adb -> emulator-5554 (used by easyworker jobs)
#   easyworker :48080
#
# The AVD is created on first start from the packaged system image; its
# userdata lives on /data so it survives a container restart.

STORAGE=/data
AVD="${ANDROID_AVD:-sandbox}"
MEM="${ANDROID_MEM:-4096}"
CPUS="${ANDROID_CPUS:-4}"
GPU="${ANDROID_GPU:-swiftshader_indirect}"
SCREEN_PORT="${SCREEN_PORT:-6080}"

export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export ANDROID_AVD_HOME=/data/avd
export PATH="/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:${PATH}"

mkdir -p "$STORAGE" "$ANDROID_AVD_HOME" /workspace

# --- disposable AVD -------------------------------------------------------
if [ ! -d "$ANDROID_AVD_HOME/${AVD}.avd" ]; then
  echo "android: creating AVD '${AVD}'"
  echo no | avdmanager create avd -n "$AVD" -k "system-images;android-35;google_apis;x86_64" \
    -d pixel_6 --force
  sed -i 's/^showDeviceFrame = yes/showDeviceFrame = no/' \
    "$ANDROID_AVD_HOME/${AVD}.avd/config.ini" || true
fi

# --- emulator (headless) --------------------------------------------------
echo "android: starting emulator (kvm, ${CPUS} vCPU, ${MEM} MB, gpu=${GPU})"
emulator -avd "$AVD" \
  -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu "$GPU" -accel on \
  -memory "$MEM" -cores "$CPUS" \
  -port 5554 \
  >/tmp/emulator.log 2>&1 &
EMU_PID=$!

# --- wait for the guest, then start the screen bridge + worker -------------
echo "android: waiting for adbd + boot_completed"
adb start-server >/dev/null 2>&1 || true
booted=""
for _ in $(seq 1 180); do
  bc="$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  if [ "$bc" = "1" ]; then booted="1"; break; fi
  sleep 5
done

if [ -z "$booted" ]; then
  echo "android: guest did not reach boot_completed" >&2
  tail -40 /tmp/emulator.log >&2 || true
  exit 1
fi
echo "android: guest is up"

# Keep the display awake and dismiss the keyguard so the view is the UI, not
# the lock screen.
adb -s emulator-5554 shell "svc power stayon true" >/dev/null 2>&1 || true
adb -s emulator-5554 shell "wm dismiss-keyguard" >/dev/null 2>&1 || true

# --- screen bridge (view-only; input is done via adb) ---------------------
export ANDROID_SERIAL="emulator-5554"
export PORT="$SCREEN_PORT"
export ADB="adb"
export SCRCPY_SERVER=/opt/scrcpy-server.jar
echo "android: starting screen bridge on :${SCREEN_PORT}"
node /opt/bridge/server.js >/tmp/bridge.log 2>&1 &
BRIDGE_PID=$!

cleanup() {
  kill "${WORKER_PID:-}" "$BRIDGE_PID" "$EMU_PID" 2>/dev/null || true
}
trap cleanup TERM INT

echo "android: starting easyworker on :${WORKER_PORT:-48080}"
easyworker &
WORKER_PID=$!

wait "$WORKER_PID"
