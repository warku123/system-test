#!/usr/bin/env bash
# replay-poc.sh — local mainnet replay PoC
#
# Usage:
#   ./scripts/replay-poc.sh [BLOCK_COUNT]
#
# BLOCK_COUNT: how many blocks to sync past the snapshot head (default 1000)
#
# Required env (or edit defaults below):
#   JAVA_TRON_DIR   path to java-tron repo (default: ../../java-tron relative to this script)
#   SNAPSHOT_URL    URL of the LiteFullNode snapshot tarball
#   WORK_DIR        working directory for DB + config (default: /tmp/tron-replay-$$)
#   SKIP_BUILD      set to 1 to reuse existing FullNode.jar
#   SKIP_DOWNLOAD   set to 1 to reuse cached snapshot tarball

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- configurable defaults ----------
BLOCK_COUNT="${1:-1000}"
JAVA_TRON_DIR="${JAVA_TRON_DIR:-$(cd "$REPO_ROOT/../java-tron" && pwd)}"
SNAPSHOT_URL="${SNAPSHOT_URL:-http://34.143.247.77/backup20260504/LiteFullNode_output-directory.tgz}"
SNAPSHOT_CACHE="${SNAPSHOT_CACHE:-/tmp/tron-snapshot-cache.tgz}"
CHECKSUM_URL="${CHECKSUM_URL:-${SNAPSHOT_URL}.md5}"
WORK_DIR="${WORK_DIR:-/tmp/tron-replay-$$}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
CONFIG_TEMPLATE="$REPO_ROOT/testcase/src/test/resources/config-replay.conf"
LOG_FILE="$WORK_DIR/fullnode.log"
RPC_PORT=50051
HTTP_PORT=8090
NODE_SHUTDOWN_TIMEOUT=3600   # seconds to wait for node to auto-exit
# -------------------------------------------

info()  { echo "[replay] $*"; }
die()   { echo "[replay] ERROR: $*" >&2; exit 1; }

md5_of() {
  # returns lowercase hex MD5 of a file; works on both Linux (md5sum) and macOS (md5)
  if command -v md5sum &>/dev/null; then
    md5sum "$1" | cut -d' ' -f1
  elif command -v md5 &>/dev/null; then
    md5 -q "$1"
  else
    die "no md5/md5sum tool found"
  fi
}

cleanup() {
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    info "killing node pid=$NODE_PID"
    kill "$NODE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── 1 & 2. build jar + fetch snapshot (parallel) ────────────────────────────
mkdir -p "$WORK_DIR"
JAR="$JAVA_TRON_DIR/build/libs/FullNode.jar"

build_jar() {
  info "building java-tron from $JAVA_TRON_DIR (develop branch)"
  cd "$JAVA_TRON_DIR"
  git fetch origin develop
  git checkout develop
  git pull origin develop
  ./gradlew clean build -x test -q
  info "build done"
}

download_snapshot() {
  info "downloading snapshot from $SNAPSHOT_URL (~58 GB)..."
  curl -L --retry 5 --retry-delay 10 -o "$SNAPSHOT_CACHE" "$SNAPSHOT_URL"
  info "download complete: $(du -sh "$SNAPSHOT_CACHE" | cut -f1)"
}

ensure_snapshot() {
  if [[ "$SKIP_DOWNLOAD" == "1" && -f "$SNAPSHOT_CACHE" ]]; then
    info "SKIP_DOWNLOAD=1, skipping snapshot check"
    return
  fi
  info "fetching remote checksum from $CHECKSUM_URL"
  REMOTE_MD5="$(curl -sfL --retry 3 "$CHECKSUM_URL" 2>/dev/null | awk '{print tolower($1)}' || true)"
  if [[ -z "$REMOTE_MD5" ]]; then
    info "WARNING: could not fetch remote checksum, will download unconditionally"
  fi
  NEED_DOWNLOAD=1
  if [[ -f "$SNAPSHOT_CACHE" && -n "$REMOTE_MD5" ]]; then
    info "verifying local cache $(du -sh "$SNAPSHOT_CACHE" | cut -f1) against remote MD5 $REMOTE_MD5 ..."
    LOCAL_MD5="$(md5_of "$SNAPSHOT_CACHE")"
    if [[ "$LOCAL_MD5" == "$REMOTE_MD5" ]]; then
      info "checksum match — reusing cached snapshot"
      NEED_DOWNLOAD=0
    else
      info "checksum mismatch (local=$LOCAL_MD5) — re-downloading"
      rm -f "$SNAPSHOT_CACHE"
    fi
  fi
  if [[ "$NEED_DOWNLOAD" == "1" ]]; then
    download_snapshot
    if [[ -n "$REMOTE_MD5" ]]; then
      LOCAL_MD5="$(md5_of "$SNAPSHOT_CACHE")"
      [[ "$LOCAL_MD5" == "$REMOTE_MD5" ]] || die "post-download checksum mismatch (got $LOCAL_MD5, expected $REMOTE_MD5)"
      info "post-download checksum OK"
    fi
  fi
}

BUILD_LOG="$WORK_DIR/build.log"
SNAPSHOT_LOG="$WORK_DIR/snapshot.log"
BUILD_PID=""

if [[ "$SKIP_BUILD" == "1" ]]; then
  info "SKIP_BUILD=1, skipping build"
  [[ -f "$JAR" ]] || die "FullNode.jar not found at $JAR"
else
  info "starting build in background (log: $BUILD_LOG)"
  build_jar > "$BUILD_LOG" 2>&1 &
  BUILD_PID=$!
fi

info "starting snapshot check in background (log: $SNAPSHOT_LOG)"
ensure_snapshot > "$SNAPSHOT_LOG" 2>&1 &
SNAPSHOT_PID=$!

if [[ -n "$BUILD_PID" ]]; then
  info "waiting for build..."
  wait "$BUILD_PID" || { tail -30 "$BUILD_LOG" >&2; die "build failed"; }
  info "build complete"
fi

info "waiting for snapshot..."
wait "$SNAPSHOT_PID" || { tail -30 "$SNAPSHOT_LOG" >&2; die "snapshot failed"; }
info "snapshot ready"

# ── 3. working directory ─────────────────────────────────────────────────────
info "extracting snapshot into $WORK_DIR (this may take a while)"
tar -xzf "$SNAPSHOT_CACHE" -C "$WORK_DIR"
DB_ROOT="$WORK_DIR"
info "snapshot extracted to $WORK_DIR"

# ── 4. config ────────────────────────────────────────────────────────────────
WORK_CONFIG="$WORK_DIR/config.conf"
sed "s/REPLAY_BLOCK_COUNT/$BLOCK_COUNT/" "$CONFIG_TEMPLATE" > "$WORK_CONFIG"
info "config written to $WORK_CONFIG (BlockCount=$BLOCK_COUNT)"

# ── 5. start node ────────────────────────────────────────────────────────────
info "starting FullNode (will auto-exit after syncing $BLOCK_COUNT blocks past snapshot head)"
java -Xmx8g \
     -jar "$JAR" \
     -c "$WORK_CONFIG" \
     -d "$DB_ROOT/output-directory" \
     > "$LOG_FILE" 2>&1 &
NODE_PID=$!
info "node pid=$NODE_PID, log=$LOG_FILE"

# ── 6. wait for auto-exit ────────────────────────────────────────────────────
info "waiting for node to auto-exit (timeout ${NODE_SHUTDOWN_TIMEOUT}s)..."
elapsed=0
while kill -0 "$NODE_PID" 2>/dev/null; do
  sleep 10
  elapsed=$((elapsed + 10))
  if (( elapsed % 60 == 0 )); then
    # show last sync progress line from log
    tail_line="$(grep -o 'Sync block.*' "$LOG_FILE" 2>/dev/null | tail -1 || true)"
    info "  ${elapsed}s ... ${tail_line}"
  fi
  if (( elapsed >= NODE_SHUTDOWN_TIMEOUT )); then
    die "node did not auto-exit within ${NODE_SHUTDOWN_TIMEOUT}s — check $LOG_FILE"
  fi
done
wait "$NODE_PID" || true
NODE_PID=""
info "node exited after ${elapsed}s"

# ── 7. check for crash ───────────────────────────────────────────────────────
# A clean shutdown (System.exit(0)) logs "******shutdown******"
if ! grep -q "shutdown" "$LOG_FILE" 2>/dev/null; then
  echo "=== last 50 log lines ===" >&2
  tail -50 "$LOG_FILE" >&2
  die "node log does not contain expected shutdown marker — possible crash, see above"
fi

# ── 8. restart read-only to query RPC ────────────────────────────────────────
info "restarting node with p2p disabled to query head block via HTTP"
VERIFY_CONFIG="$WORK_DIR/config-verify.conf"
# copy sync config, disable discovery & seed nodes so it doesn't re-sync
sed -e 's/enable = true/enable = false/' \
    -e '/REPLAY_BLOCK_COUNT/d' \
    -e '/BlockCount/d' \
    "$WORK_CONFIG" > "$VERIFY_CONFIG"

java -Xmx4g \
     -jar "$JAR" \
     -c "$VERIFY_CONFIG" \
     -d "$DB_ROOT/output-directory" \
     >> "$LOG_FILE" 2>&1 &
NODE_PID=$!

# wait for HTTP to come up
info "waiting for HTTP on port $HTTP_PORT..."
for i in $(seq 1 60); do
  if curl -sf "http://localhost:$HTTP_PORT/wallet/getnowblock" -o /dev/null 2>/dev/null; then
    break
  fi
  sleep 2
  (( i == 60 )) && die "HTTP did not come up on port $HTTP_PORT after 120s"
done

# ── 9. verify head block ──────────────────────────────────────────────────────
HEAD_JSON="$(curl -sf "http://localhost:$HTTP_PORT/wallet/getnowblock")"
HEAD_NUM="$(echo "$HEAD_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['block_header']['raw_data']['number'])" 2>/dev/null || echo "UNKNOWN")"
info "head block number = $HEAD_NUM"

kill "$NODE_PID" 2>/dev/null || true
NODE_PID=""

# ── 10. compare with mainnet truth ───────────────────────────────────────────
info "querying mainnet for block $HEAD_NUM hash..."
MAINNET_BLOCK="$(curl -sf "https://api.trongrid.io/wallet/getblockbynum" \
  -H "Content-Type: application/json" \
  -d "{\"num\": $HEAD_NUM}" 2>/dev/null || echo '{}')"
MAINNET_HASH="$(echo "$MAINNET_BLOCK" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('blockID','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")"

# restart node briefly for local query
java -Xmx4g -jar "$JAR" -c "$VERIFY_CONFIG" -d "$DB_ROOT/output-directory" >> "$LOG_FILE" 2>&1 &
NODE_PID=$!
sleep 30
LOCAL_BLOCK="$(curl -sf "http://localhost:$HTTP_PORT/wallet/getblockbynum" \
  -H "Content-Type: application/json" \
  -d "{\"num\": $HEAD_NUM}" 2>/dev/null || echo '{}')"
LOCAL_HASH="$(echo "$LOCAL_BLOCK" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('blockID','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")"
kill "$NODE_PID" 2>/dev/null || true
NODE_PID=""

echo ""
echo "========== REPLAY RESULT =========="
echo "head block : $HEAD_NUM"
echo "local  ID  : $LOCAL_HASH"
echo "mainnet ID : $MAINNET_HASH"
if [[ "$LOCAL_HASH" == "$MAINNET_HASH" && "$LOCAL_HASH" != "UNKNOWN" ]]; then
  echo "STATUS     : PASS ✓"
  echo "==================================="
  exit 0
else
  echo "STATUS     : FAIL ✗  (hash mismatch or query error)"
  echo "==================================="
  echo "Check $LOG_FILE for details" >&2
  exit 1
fi
