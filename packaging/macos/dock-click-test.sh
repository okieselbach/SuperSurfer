#!/usr/bin/env bash
# End-to-end test for Dock Click against a built SuperSurfer.app.
#
# It opens Calculator, TextEdit, Safari and a Finder window, clicks their Dock
# icons with mouse events and checks that the app in front is hidden or
# minimized, that the next click brings it back, and that an app which only
# comes to the front with the click is left alone. The pointer moves and
# windows come and go while it runs, so keep your hands off the Mac for the
# two minutes it takes.
#
# Needs a Mac with a logged-in session in which this shell may use
# Accessibility. A GitHub-hosted macOS runner qualifies; on your own Mac it is
# the terminal app that needs the permission. Without it the test says so and
# is skipped.
#
# The Dock Click choice reaches the app through the environment and is not
# stored, except in the last part, which makes the choice in the app's menu
# and puts back what was stored before. Everything else runs against a
# scratch HOME, as in smoke-test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "${1:-dist/SuperSurfer.app}" && pwd)"
BIN="$APP/Contents/MacOS/SuperSurfer"

SCRATCH="$(mktemp -d)"
SUPPORT="$SCRATCH/Library/Application Support/SuperSurfer"
DRIVER="$SCRATCH/dock-click-test"
PID=""
# Each part below says for itself what the choice is.
unset SUPERSURFER_DOCK_CLICK

stop_app() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}

STORED_CHOICE=""
RESTORE_CHOICE=no

restore_choice() {
  if [ "$RESTORE_CHOICE" = yes ]; then
    if [ -n "$STORED_CHOICE" ]; then
      defaults write dev.supersurfer.app dockClick "$STORED_CHOICE"
    else
      defaults delete dev.supersurfer.app dockClick 2>/dev/null || true
    fi
    RESTORE_CHOICE=no
  fi
}

cleanup() {
  stop_app
  restore_choice
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

wait_for() {
  # wait_for <seconds> <command...>: poll until the command succeeds.
  local deadline=$(( $(date +%s) + $1 ))
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.5
  done
}

app_is_running() {
  # app_is_running <bundle id>: whether Launch Services lists the app.
  local listing
  listing="$(lsappinfo list)"
  case "$listing" in
    *"bundleID=\"$1\""*) return 0 ;;
    *) return 1 ;;
  esac
}

if app_is_running dev.supersurfer.app; then
  # Two copies would both act on the same click.
  echo "FAIL: SuperSurfer is running. Quit it first (menu → Quit SuperSurfer)." >&2
  exit 1
fi

echo "== driver, on macOS $(sw_vers -productVersion)"
swiftc "$HERE/dock-click-test.swift" -o "$DRIVER"
STATUS=0
"$DRIVER" preflight || STATUS=$?
if [ "$STATUS" -eq 77 ]; then
  echo "skipped: Dock Click cannot be tested in this session"
  exit 0
elif [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

echo "== without SuperSurfer"
"$DRIVER" control

# TEMPORARY
echo "== probe: Show Desktop"
"$DRIVER" probe-desktop || true
echo "== probe: Edge profiles"
"$DRIVER" probe-edge || true

# Finishes first-run setup for the scratch HOME, so the app does not open the
# manual in a browser when it starts.
mkdir -p "$SUPPORT"
cat > "$SUPPORT/config.js" <<'CONFIG'
export default {
  defaultBrowser: "safari",
  handlers: [],
};
CONFIG
HOME="$SCRATCH" "$BIN" doctor >/dev/null

for MODE in hide minimize; do
  echo "== dock click: $MODE"
  # --resident prints one line on stderr per Dock click it looked at.
  TRACE="$SCRATCH/trace-$MODE.log"
  SUPERSURFER_DOCK_CLICK="$MODE" HOME="$SCRATCH" "$BIN" --resident 2>"$TRACE" &
  PID=$!
  if ! wait_for 30 app_is_running dev.supersurfer.app; then
    echo "FAIL: the app did not come up" >&2
    exit 1
  fi
  sleep 1

  STATUS=0
  "$DRIVER" "$MODE" || STATUS=$?
  if command -v footprint >/dev/null 2>&1; then
    # What Activity Monitor shows in its Memory column, with Dock Click used.
    FOOTPRINT="$(footprint "$PID" 2>/dev/null || true)"
    printf '%s\n' "$FOOTPRINT" | grep -i "footprint:" | head -n 1 || true
  fi
  stop_app
  sed 's/^/trace: /' "$TRACE"
  if [ "$STATUS" -ne 0 ]; then
    exit "$STATUS"
  fi
done

echo "== dock click: chosen in the menu"
# The way it is really switched on, which goes through the stored choice.
STORED_CHOICE="$(defaults read dev.supersurfer.app dockClick 2>/dev/null || true)"
RESTORE_CHOICE=yes
defaults delete dev.supersurfer.app dockClick 2>/dev/null || true
TRACE="$SCRATCH/trace-menu.log"
HOME="$SCRATCH" "$BIN" --resident 2>"$TRACE" &
PID=$!
if ! wait_for 30 app_is_running dev.supersurfer.app; then
  echo "FAIL: the app did not come up" >&2
  exit 1
fi
sleep 1
STATUS=0
"$DRIVER" menu || STATUS=$?
echo "stored: $(defaults read dev.supersurfer.app dockClick 2>/dev/null || echo nothing)"
stop_app
restore_choice
sed 's/^/trace: /' "$TRACE"
if [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

echo "dock click test passed"
