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

if [ -x "$TROND_BIN" ]; then
  log "destroying trond deployment $STEST_NODE_NAME"
  sudo "$TROND_BIN" network destroy "$STEST_NODE_NAME" --confirm "$STEST_NODE_NAME" || \
    log "trond network destroy returned non-zero (already torn down?)"
else
  log "trond not installed at $TROND_BIN — skipping graceful teardown"
fi

# Best-effort fallback: even if trond is missing or destroy failed,
# stop and remove the systemd unit so the next CI run starts clean.
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
