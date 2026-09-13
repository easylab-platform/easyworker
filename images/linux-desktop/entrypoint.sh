#!/usr/bin/env bash
set -Eeuo pipefail

# EasyWorker Linux labwc desktop sandbox.
#
# A headless wlroots (labwc) compositor with wayvnc + noVNC for a browser
# view, and the easyworker binary serving the Worker API on :48080. No KVM,
# no privileged mode, no sidecar: the guest *is* the container.
#
# Layout:
#   labwc (WLR_BACKENDS=headless, pixman software render)
#     -> wayvnc :5900
#        -> websockify/noVNC :6080
#   easyworker :48080   (token from $WORKER_TOKEN)
#
# The worker's job env is a strict allowlist (see cmd/easyworker/main.go
# jobEnv): WAYLAND_DISPLAY / XDG_RUNTIME_DIR / DISPLAY are NOT passed through.
# GUI programs therefore need either per-job env via ExecuteRequest.env, or
# the `gui-run` wrapper on PATH (this image ships it).

export XDG_RUNTIME_DIR="/tmp/xdg"
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_LIBINPUT_NO_DEVICES=1
# Software rendering for GTK/Qt/GL clients (no GPU in the sandbox).
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# --- compositor -----------------------------------------------------------
labwc >/tmp/labwc.log 2>&1 &
LABWC_PID=$!

# Wait for the wayland socket (wayland-0/wayland-1 depending on the version).
i=0
until ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland'; do
  i=$((i + 1))
  if [ "$i" -gt 150 ]; then
    echo "labwc: compositor failed to start" >&2
    cat /tmp/labwc.log >&2 || true
    exit 1
  fi
  sleep 0.2
done

WAYLAND_SOCKET="$(ls "$XDG_RUNTIME_DIR" | grep '^wayland' | head -n1)"
export WAYLAND_DISPLAY="$WAYLAND_SOCKET"

# X11-only GUI programs: labwc starts its own XWayland on demand; only start
# one explicitly if no display 0 is already present (avoids a stale lock).
if [ ! -e /tmp/.X11-unix/X0 ] && [ ! -e /tmp/.X0-lock ]; then
  Xwayland :0 -rootless -noreset >/tmp/xwayland.log 2>&1 &
  XWAYLAND_PID=$!
fi
export DISPLAY=:0

# --- remote view ----------------------------------------------------------
wayvnc 0.0.0.0 5900 >/tmp/wayvnc.log 2>&1 &
WAYVNC_PID=$!

websockify --web /usr/share/novnc 6080 localhost:5900 >/tmp/websockify.log 2>&1 &
WS_PID=$!

cleanup() {
  kill "$WS_PID" "$WAYVNC_PID" "$XWAYLAND_PID" "$LABWC_PID" "${WORKER_PID:-}" 2>/dev/null || true
}
trap cleanup TERM INT

# --- worker ---------------------------------------------------------------
# The compositor session env is exported above, so both the worker process
# and the GUI programs it spawns share one desktop.
easyworker &
WORKER_PID=$!

wait "$WORKER_PID"
