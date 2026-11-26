#!/usr/bin/env bash
# End-to-end test for the Dock shortcuts of browser profiles against a built
# SuperSurfer.app, with Microsoft Edge and Google Chrome as they are
# installed on this Mac. A browser that is not installed is skipped.
#
# It starts each browser with three profiles of its own, kept below a scratch
# HOME, makes shortcuts for two of them in SuperSurfer's menu, uses them and
# checks that the window of the right profile is in front: from behind
# another app, out of the Dock, with the browser hidden, and for a profile
# that has no window. One shortcut gets another name in the menu and one in
# the way the Finder renames, and both have to work on under it. The picker
# and the lists in the menu then have to call the two profiles by those
# names. The pointer moves and windows come and go while it runs, so keep
# your hands off the Mac for the five minutes it takes.
#
# Needs what dock-click-test.sh needs: a logged-in session in which this
# shell may use Accessibility. Edge, Chrome and SuperSurfer must not be
# running, because the test could not tell their windows from its own.
#
# Two things are only done where CI is set, as on a GitHub runner, because
# they change the Mac they run on: one shortcut is put into the Dock and
# clicked there, which restarts the Dock, and a browser that is not running
# is started, which uses its real profiles: through a shortcut, a second
# time by choosing a profile in the picker under the name of its shortcut,
# and a third time by a link that config.js sends to the profile by that
# name.
#
# The last step is about what SuperSurfer does when macOS does not answer a
# start. It has SuperSurfer start an app that only sleeps, and then sends a
# link that goes to Safari, which has to open it all the same. It needs
# neither Edge nor Chrome, and it opens one page in Safari. SuperSurfer is
# started anew for it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "${1:-dist/SuperSurfer.app}" && pwd)"
BIN="$APP/Contents/MacOS/SuperSurfer"

SCRATCH="$(mktemp -d)"
SUPPORT="$SCRATCH/Library/Application Support/SuperSurfer"
DRIVER="$SCRATCH/dock-click-test"
TRACE="$SCRATCH/trace.log"
# What the SuperSurfer of the last step writes.
TRACE_LAST="$SCRATCH/trace-last.log"
PID=""

cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
  # Browsers the test started and did not get to quit, which is how it is
  # after a check failed. They write below the scratch HOME until they are
  # gone, so it is removed after them.
  if pkill -f -- "--user-data-dir=$SCRATCH" 2>/dev/null; then
    local tries=0
    while pgrep -f -- "--user-data-dir=$SCRATCH" >/dev/null 2>&1 && [ "$tries" -lt 24 ]; do
      # Ten seconds to quit when asked, then they are not asked any more.
      if [ "$tries" -eq 20 ]; then
        pkill -9 -f -- "--user-data-dir=$SCRATCH" 2>/dev/null || true
      fi
      sleep 0.5
      tries=$((tries + 1))
    done
  fi
  # The app that only sleeps, if the test did not get to end it.
  pkill -f '^/bin/sleep 317$' 2>/dev/null || true
  # How the test went is decided by now, and not by whether this works.
  rm -rf "$SCRATCH" || true
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

app_is_gone() {
  ! app_is_running "$1"
}

start_supersurfer() {
  # start_supersurfer <trace file>: --resident prints one line on stderr per
  # shortcut it wrote or was asked by, and per link it handed on.
  HOME="$SCRATCH" "$BIN" --resident 2>"$1" &
  PID=$!
  if ! wait_for 30 app_is_running dev.supersurfer.app; then
    echo "FAIL: the app did not come up" >&2
    return 1
  fi
  sleep 1
}

stop_supersurfer() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
  # Launch Services lists it for a moment longer, and SuperSurfer does not
  # start beside one that is listed.
  wait_for 10 app_is_gone dev.supersurfer.app || true
}

for RUNNING in dev.supersurfer.app:SuperSurfer com.microsoft.edgemac:"Microsoft Edge" com.google.Chrome:"Google Chrome"; do
  if app_is_running "${RUNNING%%:*}"; then
    echo "FAIL: ${RUNNING#*:} is running. Quit it first." >&2
    exit 1
  fi
done

echo "== driver, on macOS $(sw_vers -productVersion)"
swiftc "$HERE/dock-click-test.swift" -o "$DRIVER"
STATUS=0
"$DRIVER" preflight || STATUS=$?
if [ "$STATUS" -eq 77 ]; then
  echo "skipped: Dock shortcuts cannot be tested in this session"
  exit 0
elif [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

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

# What changes this Mac is left to CI.
EXTRAS=()
if [ "${CI:-}" = true ]; then
  EXTRAS=(dock start)
fi

start_supersurfer "$TRACE" || exit 1

STATUS=0
for BROWSER in edge chrome; do
  echo "== dock shortcuts: $BROWSER"
  "$DRIVER" shortcuts "$BROWSER" "$SCRATCH" "$APP" "$TRACE" ${EXTRAS[@]+"${EXTRAS[@]}"} || STATUS=$?
  if [ "$STATUS" -ne 0 ]; then
    break
  fi
done

# Last, because SuperSurfer is left with a start that macOS never answers.
# And with a SuperSurfer of its own, which has asked macOS for nothing yet.
# The one above may still be waiting for an answer: macOS answers the start
# of a browser that was quit while it started about five seconds after the
# start (run 83 of the CI), and one that was quit a little later perhaps
# never. A SuperSurfer that waits sends what it is asked for next the other
# way round, which is what this step is to bring about by itself.
if [ "$STATUS" -eq 0 ]; then
  stop_supersurfer
  if start_supersurfer "$TRACE_LAST"; then
    echo "== a start that macOS does not answer"
    "$DRIVER" unanswered "$SCRATCH" "$APP" "$TRACE_LAST" || STATUS=$?
  else
    STATUS=1
  fi
fi

stop_supersurfer
sed 's/^/trace: /' "$TRACE"
if [ -f "$TRACE_LAST" ]; then
  sed 's/^/trace, last step: /' "$TRACE_LAST"
fi
if [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

# A shortcut that cannot reach SuperSurfer says so in the system log and
# opens a window by itself. SuperSurfer was running whenever a shortcut was
# used, so none should have had to. Reading the log needs an administrator;
# where that fails, nothing is concluded. Only what "logger" wrote counts:
# "log" itself puts this very question into the log, with the words it asks
# for.
NOTE="could not reach SuperSurfer"
ALONE="$(log show --last 15m --style compact \
  --predicate "process == \"logger\" AND eventMessage CONTAINS \"$NOTE\"" 2>/dev/null | grep "$NOTE" || true)"
if [ -n "$ALONE" ]; then
  echo "FAIL: a shortcut could not reach SuperSurfer and opened a window by itself:" >&2
  printf '%s\n' "$ALONE" >&2
  exit 1
fi

echo "dock shortcut test passed"
