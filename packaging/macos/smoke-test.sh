#!/usr/bin/env bash
# Smoke test for a built SuperSurfer.app. Needs a Mac with a logged-in
# session (a GitHub-hosted macOS runner qualifies).
#
#   1. --self-test: the Swift binary and the Rust core linked into it agree
#      on the JSON they exchange.
#   2. The app starts, stays loaded, receives a link the way macOS delivers
#      it to the default browser, routes it and hands it to Safari.
#
# Everything runs against a scratch HOME; the real configuration, rules and
# logs are not touched.
set -euo pipefail

APP="$(cd "${1:-dist/SuperSurfer.app}" && pwd)"
BIN="$APP/Contents/MacOS/SuperSurfer"
LINK="https://example.com/supersurfer-smoke-test"

SCRATCH="$(mktemp -d)"
SUPPORT="$SCRATCH/Library/Application Support/SuperSurfer"
LOG="$SUPPORT/logs/decisions.log"
PID=""

cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
  fi
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
  # Output is captured first: with pipefail, a reader that stops early would
  # make the listing look like a failure.
  local listing
  listing="$(lsappinfo list)"
  case "$listing" in
    *"bundleID=\"$1\""*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "== self-test"
"$BIN" --self-test

echo "== command line still answers from the app binary"
HELP="$("$BIN" --help)"
case "$HELP" in
  *"browser router"*) ;;
  *)
    echo "FAIL: --help did not print the command line help" >&2
    exit 1
    ;;
esac

echo "== resident app"
mkdir -p "$SUPPORT"
cat > "$SUPPORT/config.js" <<'CONFIG'
export default {
  defaultBrowser: "safari",
  handlers: [],
};
CONFIG

# Finishes first-run setup for the scratch HOME. Otherwise the app would open
# the manual in the system's browser on start, and "Safari is running" below
# would prove nothing about the routed link.
HOME="$SCRATCH" "$BIN" doctor

SAFARI_WAS_RUNNING=no
if app_is_running com.apple.Safari; then
  SAFARI_WAS_RUNNING=yes
fi

HOME="$SCRATCH" "$BIN" --resident &
PID=$!
if ! wait_for 30 app_is_running dev.supersurfer.app; then
  echo "FAIL: the app did not come up" >&2
  exit 1
fi
STARTED_RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"

# The same thing macOS does on a link click: a URL event for the app.
open -a "$APP" "$LINK"

if ! wait_for 30 grep -qF "$LINK" "$LOG"; then
  echo "FAIL: the link never reached the decision log" >&2
  ls -la "$SUPPORT" "$SUPPORT/logs" 2>&1 || true
  exit 1
fi
echo "routed:  $(grep -F "$LINK" "$LOG" | tail -n 1)"

if ! kill -0 "$PID" 2>/dev/null; then
  echo "FAIL: the app exited after routing; it is meant to stay loaded" >&2
  exit 1
fi

if ! wait_for 30 app_is_running com.apple.Safari; then
  echo "FAIL: Safari was not started for the routed link" >&2
  exit 1
fi
echo "opened:  Safari is running"

# A second link must be answered by the same process.
open -a "$APP" "$LINK?second=1"
if ! wait_for 30 grep -qF "$LINK?second=1" "$LOG"; then
  echo "FAIL: the second link was not routed by the running app" >&2
  exit 1
fi
kill -0 "$PID"

RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"
echo "memory:  resident set $(( STARTED_RSS_KB / 1024 )) MB after start, $(( RSS_KB / 1024 )) MB after two links"
if command -v footprint >/dev/null 2>&1; then
  # What Activity Monitor shows in its Memory column.
  FOOTPRINT="$(footprint "$PID" 2>/dev/null || true)"
  printf '%s\n' "$FOOTPRINT" | grep -i "footprint:" | head -n 1 || true
fi

if [ "$SAFARI_WAS_RUNNING" = no ]; then
  pkill -x Safari 2>/dev/null || true
fi
echo "smoke test passed"
