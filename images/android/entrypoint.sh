#!/usr/bin/env bash
set -Eeuo pipefail

# easyworker Android sandbox entrypoint.
#
#   Xvfb :99  ->  emulator Qt window (xcb)  ->  x11vnc :5900
#     ->  websockify :6081 -> nginx :6080 (noVNC) -> browser
#   adb -> emulator-5554 (used by easyworker jobs)
#   easyworker :48080
#
# The AVD is created on first start from the packaged system image; the guest's
# userdata lives on /data so it survives a container restart.

STORAGE=/data
AVD="${ANDROID_AVD:-sandbox}"
MEM="${ANDROID_MEM:-4096}"
CPUS="${ANDROID_CPUS:-4}"
DISPLAY_NUM=99
export DISPLAY=":${DISPLAY_NUM}"

export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export ANDROID_AVD_HOME=/data/avd
export PATH="/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:${PATH}"

mkdir -p "$STORAGE" "$ANDROID_AVD_HOME" /workspace

# --- virtual X server (the emulator needs an X display for its window) -----
Xvfb "$DISPLAY" -screen 0 1080x2400x24 -ac -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
  sleep 0.2
done

# --- disposable AVD -------------------------------------------------------
if [ ! -d "$ANDROID_AVD_HOME/${AVD}.avd" ]; then
  echo "android: creating AVD '${AVD}'"
  echo no | avdmanager create avd -n "$AVD" -k "system-images;android-35;google_apis;x86_64" \
    -d pixel_6 --force
  # The emulator window is the device screen; the decorative frame only wastes
  # space in the browser view.
  sed -i 's/^showDeviceFrame = yes/showDeviceFrame = no/' \
    "$ANDROID_AVD_HOME/${AVD}.avd/config.ini" || true
fi

# --- emulator -------------------------------------------------------------
echo "android: starting emulator (kvm, ${CPUS} vCPU, ${MEM} MB)"
emulator -avd "$AVD" \
  -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect -accel on \
  -memory "$MEM" -cores "$CPUS" \
  -port 5554 -fixed-scale \
  >/tmp/emulator.log 2>&1 &
EMU_PID=$!

# The window is created at +100+100 and trails a toolbar/sidebar; pin the main
# window to the top-left and hide the chrome so the VNC view is exactly the
# device screen.
( for _ in $(seq 1 120); do
    main="$(xdotool search --name 'Android Emulator' 2>/dev/null | head -n1 || true)"
    if [ -n "$main" ]; then
      xdotool windowmove "$main" 0 0 || true
      for w in $(xdotool search --name '^Emulator$' 2>/dev/null || true); do
        xdotool windowunmap "$w" 2>/dev/null || true
      done
      break
    fi
    sleep 1
  done ) &

# --- screen sharing -------------------------------------------------------
x11vnc -display "$DISPLAY" -rfbport 5900 -forever -shared -nopw -quiet \
  >/tmp/x11vnc.log 2>&1 &
VNC_PID=$!
websockify --web /usr/share/novnc 6081 localhost:5900 >/tmp/websockify.log 2>&1 &
WS_PID=$!
nginx -e stderr >/tmp/nginx.log 2>&1 &
NGINX_PID=$!

cleanup() {
  kill "${WORKER_PID:-}" "$NGINX_PID" "$WS_PID" "$VNC_PID" \
       "$EMU_PID" "$XVFB_PID" 2>/dev/null || true
}
trap cleanup TERM INT

# --- wait for the guest, then start the worker ----------------------------
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

# Keep the display awake and dismiss the keyguard so the browser always shows
# the UI, not the lock screen.
adb -s emulator-5554 shell "svc power stayon true" >/dev/null 2>&1 || true
adb -s emulator-5554 shell "wm dismiss-keyguard" >/dev/null 2>&1 || true

export ANDROID_SERIAL="emulator-5554"

echo "android: starting easyworker on :${WORKER_PORT:-48080}"
easyworker &
WORKER_PID=$!

wait "$WORKER_PID"
