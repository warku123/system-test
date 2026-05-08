#!/usr/bin/env bash
#
# stest-up.sh — Bring up a single-SR private chain for the system-test
# TestNG suite.
#
# Two modes, decided automatically by trond release availability:
#
#   1. trond mode (preferred): downloads trond from a release URL,
#      uses `trond apply` + `trond verify` to deploy a systemd-managed
#      node. State, logs, lifecycle are all tracked by trond.
#
#   2. fallback mode: when the trond release URL is unreachable or the
#      sha256 mismatches, fall back to a bare `nohup java -jar` with
#      the config-system-test.conf bundled in this repo. Same
#      end-state for stest tests, no trond dependency.
#
# Caller contract:
#   - STEST_JAR (required): absolute path to the FullNode.jar to run
#     (typically java-tron/build/libs/FullNode.jar built from the PR's
#     source).
#   - sudo (required): both modes need root (trond mode for systemd;
#     fallback mode to create /opt/tron/...).
#   - Linux: trond mode requires systemd; fallback mode runs anywhere
#     with bash + curl + java.
#
# Optional env (with defaults):
#   TROND_VERSION       v0.1.1
#   TROND_RELEASE_URL   https://github.com/warku123/tron-deployment/releases/
#                       download/${TROND_VERSION}/trond_0.1.1_linux_amd64.tar.gz
#   TROND_SHA256        d704906d3f5667ca945dadc92be781c463c1a22376f6e2de6dd5bbcd07499418
#   TROND_BIN           /usr/local/bin/trond  (where to install the binary)
#   TROND_INTENT        /usr/local/share/trond/examples/system-test-singlenode-intent.yaml
#   STEST_NODE_NAME     stest-singlenode      (trond deployment name)
#   STEST_INSTALL_PATH  /opt/tron/stest-singlenode (jar / config / data root)
#   STEST_FORCE_FALLBACK    set non-empty to force fallback mode (skip trond)
#
# Exit codes:
#   0  node up, HTTP 8090 responsive
#   1  generic failure
#   2  prerequisite missing (env / sudo / curl)
#   4  node failed to become ready (either mode)

set -euo pipefail

TROND_VERSION="${TROND_VERSION:-v0.1.1}"
TROND_RELEASE_URL="${TROND_RELEASE_URL:-https://github.com/warku123/tron-deployment/releases/download/${TROND_VERSION}/trond_0.1.1_linux_amd64.tar.gz}"
TROND_SHA256="${TROND_SHA256:-d704906d3f5667ca945dadc92be781c463c1a22376f6e2de6dd5bbcd07499418}"
TROND_BIN="${TROND_BIN:-/usr/local/bin/trond}"
TROND_INTENT="${TROND_INTENT:-/usr/local/share/trond/examples/system-test-singlenode-intent.yaml}"
STEST_NODE_NAME="${STEST_NODE_NAME:-stest-singlenode}"
STEST_INSTALL_PATH="${STEST_INSTALL_PATH:-/opt/tron/${STEST_NODE_NAME}}"
STEST_FORCE_FALLBACK="${STEST_FORCE_FALLBACK:-}"

# Fallback-mode config: shipped in this repo, same one the legacy
# inline workflow used.
STEST_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FALLBACK_CONFIG="$STEST_REPO_ROOT/testcase/src/test/resources/config-system-test.conf"

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
  fail "sudo not available" 2
fi
if ! command -v curl >/dev/null 2>&1; then
  fail "curl not available" 2
fi
if ! command -v java >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
  fail "java not available (no PATH java, no JAVA_HOME)" 2
fi

# --- port preflight (both modes) ------------------------------------

log "preflight: checking required ports are free"
for port in 8090 50051 8545 18888; do
  if ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    fail "port $port already in use; clean up first (try: bash $(dirname "$0")/stest-down.sh)" 2
  fi
done
log "preflight: ports 8090/50051/8545/18888 free"

# --- repoint /usr/bin/java to JDK 8 (both modes) --------------------

# The GreatVoyage java-tron jar performs an arch+JDK self-check at
# startup and refuses to run on amd64 with anything other than JDK 8.
# On GitHub Actions ubuntu-latest /usr/bin/java is JDK 17. Repoint to
# the JDK-8 binary set up by setup-java@v5 (in $JAVA_HOME).
# Required for both trond mode (systemd ExecStart hard-codes
# /usr/bin/java) and fallback mode (nohup java -jar uses PATH java).
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  CUR_JAVA="$(readlink -f /usr/bin/java 2>/dev/null || true)"
  WANT_JAVA="$JAVA_HOME/bin/java"
  if [ "$CUR_JAVA" != "$WANT_JAVA" ]; then
    log "repointing /usr/bin/java -> $WANT_JAVA (was $CUR_JAVA)"
    sudo ln -sf "$WANT_JAVA" /usr/bin/java
  fi
  log "/usr/bin/java now reports: $(/usr/bin/java -version 2>&1 | head -1)"
fi

# --- try install trond (decide which mode) --------------------------

TROND_OK=true
if [ -n "$STEST_FORCE_FALLBACK" ]; then
  log "STEST_FORCE_FALLBACK set; skipping trond install"
  TROND_OK=false
elif [ -x "$TROND_BIN" ] && [ -r "$TROND_INTENT" ] && "$TROND_BIN" version >/dev/null 2>&1; then
  log "trond + intent already installed ($TROND_BIN, $TROND_INTENT)"
  "$TROND_BIN" version
else
  log "downloading trond $TROND_VERSION from $TROND_RELEASE_URL"
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT

  if ! curl -fsSL --retry 3 --retry-delay 5 -o "$TMPDIR/trond.tar.gz" "$TROND_RELEASE_URL" 2>&1; then
    log "WARNING: failed to download trond from $TROND_RELEASE_URL"
    TROND_OK=false
  fi

  if [ "$TROND_OK" = true ]; then
    ACTUAL_SHA="$(sha256sum "$TMPDIR/trond.tar.gz" | awk '{print $1}')"
    if [ "$ACTUAL_SHA" != "$TROND_SHA256" ]; then
      log "WARNING: trond sha256 mismatch (expected $TROND_SHA256, got $ACTUAL_SHA)"
      TROND_OK=false
    else
      log "sha256 verified: $ACTUAL_SHA"
      tar -xzf "$TMPDIR/trond.tar.gz" -C "$TMPDIR" || TROND_OK=false
      [ "$TROND_OK" = true ] && [ -x "$TMPDIR/trond" ] || { log "WARNING: extracted archive missing trond binary"; TROND_OK=false; }
      [ "$TROND_OK" = true ] && [ -r "$TMPDIR/examples/system-test-singlenode-intent.yaml" ] || { log "WARNING: extracted archive missing intent yaml"; TROND_OK=false; }
    fi
  fi

  if [ "$TROND_OK" = true ]; then
    sudo install -m 0755 "$TMPDIR/trond" "$TROND_BIN"
    sudo install -m 0644 -D "$TMPDIR/examples/system-test-singlenode-intent.yaml" "$TROND_INTENT"
    log "installed: $($TROND_BIN version)"
    log "installed intent: $TROND_INTENT"
  else
    log "trond unavailable; switching to fallback mode (nohup java -jar)"
  fi
fi

# --- branch: trond mode vs fallback mode ----------------------------

if [ "$TROND_OK" = true ]; then
  # ============== TROND MODE ===================================
  log "MODE: trond"

  # Ensure tron system user (trond's systemd unit declares User=tron;
  # GHA runner doesn't have it by default → 217/USER without this).
  if ! getent passwd tron >/dev/null 2>&1; then
    log "creating tron system user"
    sudo useradd --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin tron
  fi

  log "placing jar at $STEST_INSTALL_PATH/FullNode.jar"
  sudo mkdir -p "$STEST_INSTALL_PATH"
  sudo cp "$STEST_JAR" "$STEST_INSTALL_PATH/FullNode.jar"
  sudo chown -R tron:tron "$STEST_INSTALL_PATH"
  sudo ls -lah "$STEST_INSTALL_PATH/FullNode.jar"

  # We deliberately do NOT use `trond recipe run system-test`. The
  # recipe's apply step passes --wait, which calls trond's
  # WaitForReady — that function hard-codes `docker exec` and fails
  # for jar deployments. `trond verify` works correctly for jar.
  log "trond config validate"
  sudo "$TROND_BIN" config validate "$TROND_INTENT"

  log "trond preflight"
  sudo "$TROND_BIN" preflight --intent "$TROND_INTENT"

  log "trond apply (without --wait; verify gates readiness instead)"
  sudo "$TROND_BIN" apply --intent "$TROND_INTENT" --auto-approve

  log "trond verify (polls /wallet/getnowblock until block_height > 0, max 5m)"
  sudo "$TROND_BIN" verify --intent "$TROND_INTENT" --timeout 5m

  log "node ready: $STEST_NODE_NAME (trond mode)"
else
  # ============== FALLBACK MODE ================================
  log "MODE: fallback (nohup java -jar)"

  if [ ! -r "$FALLBACK_CONFIG" ]; then
    fail "fallback config not found at $FALLBACK_CONFIG" 4
  fi

  log "placing jar + config at $STEST_INSTALL_PATH/"
  sudo mkdir -p "$STEST_INSTALL_PATH"
  sudo cp "$STEST_JAR"        "$STEST_INSTALL_PATH/FullNode.jar"
  sudo cp "$FALLBACK_CONFIG"  "$STEST_INSTALL_PATH/config-system-test.conf"
  sudo ls -lah "$STEST_INSTALL_PATH/"

  PID_FILE="$STEST_INSTALL_PATH/node.pid"
  LOG_FILE="$STEST_INSTALL_PATH/node.log"
  log "starting java-tron in background"
  sudo bash -c "cd '$STEST_INSTALL_PATH' && nohup java -Xmx2g -Xms2g -jar FullNode.jar --witness -c config-system-test.conf > '$LOG_FILE' 2>&1 & echo \$! > '$PID_FILE'"
  PID="$(sudo cat "$PID_FILE")"
  log "java-tron pid=$PID, log=$LOG_FILE"

  log "polling http://127.0.0.1:8090/wallet/getblockbynum?num=1 (max 5 minutes)"
  for i in $(seq 1 60); do
    sleep 5
    if ! sudo kill -0 "$PID" 2>/dev/null; then
      log "ERROR: java-tron exited prematurely"
      sudo tail -50 "$LOG_FILE"
      fail "java-tron died during startup" 4
    fi
    if curl -sS --fail --max-time 3 "http://127.0.0.1:8090/wallet/getblockbynum?num=1" >/dev/null 2>&1; then
      log "node ready (attempt $i, after $((i*5))s)"
      log "node ready: $STEST_NODE_NAME (fallback mode, pid $PID)"
      exit 0
    fi
  done

  log "ERROR: HTTP 8090 did not respond within 5 minutes"
  sudo tail -80 "$LOG_FILE"
  fail "java-tron failed to become ready" 4
fi

log "next: cd <stest-root> && ./gradlew :testcase:singleNodeBuild"
log "teardown: bash $(dirname "$0")/stest-down.sh"
