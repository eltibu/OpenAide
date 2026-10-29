#!/usr/bin/env bash
# Runs integration_test/crawl_test.dart on the Linux desktop build, on a
# virtual display. The repo has no linux/ folder (the app ships for
# Android), so this makes one in a copy and runs there.
#
#   tool/e2e/crawl.sh [flutter test args]
#
# Needs: libgtk-3-dev, xvfb (xvfb-run), cmake, ninja, clang. Reports go to
# build/e2e/ in the repo.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COPY="${E2E_APP_COPY:-${TMPDIR:-/tmp}/openaide-e2e-app}"
mkdir -p "$COPY"
( cd "$REPO" && tar --exclude=./build --exclude=./.dart_tool --exclude=./.git \
    -cf - . ) | ( cd "$COPY" && tar xf - )
cd "$COPY"
if [ ! -d linux ]; then
  flutter create --platforms=linux --project-name nexus_assistant . > /dev/null
fi
if [ -n "${SQLITE3_SOURCE_DIR:-}" ] && ! grep -q SQLITE3 linux/CMakeLists.txt; then
  # For machines that can't download sqlite: a folder with sqlite3.c.
  sed -i "0,/^project(/s##set(FETCHCONTENT_SOURCE_DIR_SQLITE3 \"$SQLITE3_SOURCE_DIR\" CACHE PATH \"\" FORCE)\nproject(#" \
    linux/CMakeLists.txt
fi
export E2E_REPORT_DIR="${E2E_REPORT_DIR:-$REPO/build/e2e}"
run='flutter test integration_test/crawl_test.dart -d linux --reporter expanded "$@"'
# Secure storage on Linux wants a keyring; use one when it's installed.
if command -v gnome-keyring-daemon > /dev/null && command -v dbus-run-session > /dev/null; then
  run="echo -n e2e | gnome-keyring-daemon --unlock --components=secrets > /dev/null 2>&1; $run"
  exec xvfb-run -a -s "-screen 0 1280x1024x24" dbus-run-session -- bash -c "$run" crawl "$@"
fi
exec xvfb-run -a -s "-screen 0 1280x1024x24" bash -c "$run" crawl "$@"
