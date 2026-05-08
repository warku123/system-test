#!/usr/bin/env bash
#
# stest-up.sh — Bring up a single-SR private chain for the system-test
# TestNG suite using the trond CLI from tronprotocol/tron-deployment.
#
# Replaces the legacy CI step that did:
#   nohup java -jar build/libs/FullNode.jar --witness -c <conf> &
#   poll http://localhost:8090 ...
#
# Caller contract:
#   - STEST_JAR (required): absolute path to the FullNode.jar to run
#     (typically java-tron/build/libs/FullNode.jar built from the PR's
#     source).
#   - sudo (required): trond's jar runtime writes a systemd unit to
#     /etc/systemd/system/tron-stest-singlenode.service and runs
#     systemctl enable --now.
#   - Linux + systemd: this script does NOT work on macOS or in
#     containers without systemd.
#
# Optional env (with defaults):
#   TROND_VERSION       v0.1.0
#   TROND_RELEASE_URL   https://github.com/warku123/tron-deployment/releases/
#                       download/${TROND_VERSION}/trond_0.1.0_linux_amd64.tar.gz
#   TROND_SHA256        4daf69f4a438000d60cd58b750580d89c246114de1a44e8c93a2aa0d843bd3a9
#   TROND_BIN           /usr/local/bin/trond  (where to install the binary)
#   STEST_NODE_NAME     stest-singlenode      (trond deployment name)
#   STEST_INSTALL_PATH  /opt/tron/stest-singlenode (jar / config / data root)
#
# To migrate from fork to upstream after merge:
#   export TROND_RELEASE_URL=https://github.com/tronprotocol/tron-deployment/...
# (This whole script defaults will be flipped to upstream in the
#  Phase B switchover commit before opening upstream PRs.)
#
# Exit codes:
#   0  node up, HTTP 8090 responsive
#   1  generic failure
#   2  prerequisite missing (env / sudo / curl)
#   3  trond download / install failed
#   4  trond apply / verify failed

set -euo pipefail

TROND_VERSION="${TROND_VERSION:-v0.1.0}"
TROND_RELEASE_URL="${TROND_RELEASE_URL:-https://github.com/warku123/tron-deployment/releases/download/${TROND_VERSION}/trond_0.1.0_linux_amd64.tar.gz}"
TROND_SHA256="${TROND_SHA256:-4daf69f4a438000d60cd58b750580d89c246114de1a44e8c93a2aa0d843bd3a9}"
TROND_BIN="${TROND_BIN:-/usr/local/bin/trond}"
# The intent file lives inside the release archive's examples/ dir;
# we install it to a known absolute path so the embedded `system-test`
# recipe can be invoked from any CWD without its relative-path default
# tripping up. Override TROND_INTENT to point at a customized intent.
TROND_INTENT="${TROND_INTENT:-/usr/local/share/trond/examples/system-test-singlenode-intent.yaml}"
STEST_NODE_NAME="${STEST_NODE_NAME:-stest-singlenode}"
STEST_INSTALL_PATH="${STEST_INSTALL_PATH:-/opt/tron/${STEST_NODE_NAME}}"

log() { printf '[stest-up] %s\n' "$*"; }
fail() { printf '[stest-up] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# --- prerequisites -------------------------------------------------

if [ -z "${STEST_JAR:-}" ]; then
  fail "STEST_JAR is required. Set it to the absolute path of FullNode.jar (typically java-tron/build/libs/FullNode.jar)." 2
fi
if [ ! -f "$STEST_JAR" ]; then
  fail "STEST_JAR file not found: $STEST_JAR" 2
fi
if ! command -v sudo >/dev/null 2>&1; then
  fail "sudo not available — trond's jar runtime needs systemd write access" 2
fi
if ! command -v curl >/dev/null 2>&1; then
  fail "curl not available — needed to download trond release" 2
fi

# --- install trond + intent yaml -----------------------------------

if [ -x "$TROND_BIN" ] && [ -r "$TROND_INTENT" ] && "$TROND_BIN" version >/dev/null 2>&1; then
  log "trond + intent already installed ($TROND_BIN, $TROND_INTENT)"
  "$TROND_BIN" version
else
  log "downloading trond $TROND_VERSION from $TROND_RELEASE_URL"
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT

  if ! curl -fsSL --retry 3 --retry-delay 5 -o "$TMPDIR/trond.tar.gz" "$TROND_RELEASE_URL"; then
    fail "failed to download trond from $TROND_RELEASE_URL" 3
  fi

  ACTUAL_SHA="$(sha256sum "$TMPDIR/trond.tar.gz" | awk '{print $1}')"
  if [ "$ACTUAL_SHA" != "$TROND_SHA256" ]; then
    fail "sha256 mismatch: expected $TROND_SHA256, got $ACTUAL_SHA" 3
  fi
  log "sha256 verified: $ACTUAL_SHA"

  tar -xzf "$TMPDIR/trond.tar.gz" -C "$TMPDIR"
  if [ ! -x "$TMPDIR/trond" ]; then
    fail "extracted archive missing trond binary" 3
  fi
  if [ ! -r "$TMPDIR/examples/system-test-singlenode-intent.yaml" ]; then
    fail "extracted archive missing examples/system-test-singlenode-intent.yaml" 3
  fi

  sudo install -m 0755 "$TMPDIR/trond" "$TROND_BIN"
  sudo install -m 0644 -D "$TMPDIR/examples/system-test-singlenode-intent.yaml" "$TROND_INTENT"
  log "installed: $($TROND_BIN version)"
  log "installed intent: $TROND_INTENT"
fi

# --- preflight ---------------------------------------------------

log "preflight: checking required ports are free"
for port in 8090 50051 8545 18888; do
  if ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    fail "port $port already in use; clean up first (try: sudo $TROND_BIN network destroy $STEST_NODE_NAME --confirm $STEST_NODE_NAME)" 2
  fi
done
log "preflight: ports 8090/50051/8545/18888 free"

# --- pre-place jar --------------------------------------------------

log "placing jar at $STEST_INSTALL_PATH/FullNode.jar"
sudo mkdir -p "$STEST_INSTALL_PATH"
sudo cp "$STEST_JAR" "$STEST_INSTALL_PATH/FullNode.jar"
sudo ls -lah "$STEST_INSTALL_PATH/FullNode.jar"

# --- diagnostic preflight (text mode) -------------------------------

# Run preflight standalone with the default text output FIRST so the
# CI log shows which specific check passed/failed. The recipe runs
# every step with `--output json`, which collapses a failure to a
# bare error envelope — useful for machine consumers, opaque for
# debugging.
log "running 'trond preflight' (text mode, diagnostic)"
if ! sudo "$TROND_BIN" preflight --intent "$TROND_INTENT"; then
  fail "trond preflight reported a failure (see ✗ rows above)" 4
fi

# --- run trond recipe ------------------------------------------------

# Recipe internals already include `apply --wait --wait-timeout 5m`; the
# `--wait` flag does NOT exist on `recipe run` itself. We pass intent_path
# as an absolute file so the recipe's relative-path default
# (examples/system-test-singlenode-intent.yaml, resolved against CWD)
# does not bite when invoked from $GITHUB_WORKSPACE in CI.
log "running 'trond recipe run system-test --param intent_path=$TROND_INTENT'"
sudo "$TROND_BIN" recipe run system-test --param "intent_path=$TROND_INTENT"

# --- verify HTTP endpoint responding ---------------------------------

log "waiting for HTTP 8090 (max 5 minutes)"
sudo "$TROND_BIN" wait "$STEST_NODE_NAME" \
  --http "http://127.0.0.1:8090/wallet/getnowblock" \
  --timeout 5m

log "node ready: $STEST_NODE_NAME"
log "next: cd <stest-root> && ./gradlew :testcase:singleNodeBuild"
log "teardown: bash $(dirname "$0")/stest-down.sh"
