#!/usr/bin/env bash
#
# stest-down.sh — Tear down the stest-singlenode deployment created by
# stest-up.sh.
#
# Removes the systemd unit, stops the node, and (optionally) wipes the
# install path including the chain database. Always exits 0 so it is
# safe to chain after a failed CI step (`if: always()`).
#
# Optional env (with defaults):
#   TROND_BIN           /usr/local/bin/trond
#   STEST_NODE_NAME     stest-singlenode
#   STEST_INSTALL_PATH  /opt/tron/${STEST_NODE_NAME}
#   STEST_KEEP_DATA     "" (any non-empty value preserves install_path
#                       so logs / database can be inspected after CI)

set -uo pipefail

TROND_BIN="${TROND_BIN:-/usr/local/bin/trond}"
STEST_NODE_NAME="${STEST_NODE_NAME:-stest-singlenode}"
STEST_INSTALL_PATH="${STEST_INSTALL_PATH:-/opt/tron/${STEST_NODE_NAME}}"

log() { printf '[stest-down] %s\n' "$*"; }

# Three teardown paths, all best-effort, layered for resilience:
#   (a) PID-based — fallback mode in stest-up.sh writes node.pid
#   (b) trond — trond mode uses systemd; trond network destroy is the
#               graceful path (currently buggy for jar mode in trond
#               v0.1.1, but harmless if it returns non-zero)
#   (c) systemctl direct — last-resort cleanup of any leftover unit

# (a) PID-file-based stop (fallback mode)
PID_FILE="$STEST_INSTALL_PATH/node.pid"
if [ -f "$PID_FILE" ]; then
  PID="$(sudo cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && sudo kill -0 "$PID" 2>/dev/null; then
    log "stopping fallback-mode java-tron (pid $PID)"
    sudo kill "$PID" 2>/dev/null || true
    # Give it a moment to exit gracefully, then SIGKILL if still alive.
    for _ in 1 2 3 4 5; do
      sudo kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    sudo kill -9 "$PID" 2>/dev/null || true
  fi
fi

# (b) trond network destroy (trond mode)
if [ -x "$TROND_BIN" ]; then
  log "destroying trond deployment $STEST_NODE_NAME"
  sudo "$TROND_BIN" network destroy "$STEST_NODE_NAME" --confirm "$STEST_NODE_NAME" 2>/dev/null || \
    log "trond network destroy returned non-zero (jar-mode bug, fallback below)"
else
  log "trond not installed at $TROND_BIN — skipping trond teardown"
fi

# (c) systemctl direct cleanup — covers any unit left behind by (b)'s
# jar-mode bug, and is a no-op if no unit was ever installed.
UNIT="tron-${STEST_NODE_NAME}.service"
sudo systemctl stop "$UNIT" 2>/dev/null || true
sudo systemctl disable "$UNIT" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/$UNIT"
sudo rm -rf "/etc/systemd/system/${UNIT}.d"
sudo systemctl daemon-reload 2>/dev/null || true

if [ -z "${STEST_KEEP_DATA:-}" ] && [ -d "$STEST_INSTALL_PATH" ]; then
  log "wiping install path $STEST_INSTALL_PATH (set STEST_KEEP_DATA=1 to preserve)"
  sudo rm -rf "$STEST_INSTALL_PATH"
fi

log "teardown complete"
exit 0
