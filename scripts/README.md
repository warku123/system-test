# scripts/

Bridge scripts that bring up / tear down a single-SR private chain
suitable for running the TestNG suite in `testcase/`. Replaces the
inline `nohup java -jar` step previously embedded in
java-tron's `.github/workflows/system-test.yml`.

## stest-up.sh

Brings up a single-SR private chain via the
[trond](https://github.com/tronprotocol/tron-deployment) CLI:

1. Downloads + verifies + installs the trond binary (skipped if
   `/usr/local/bin/trond` already responds to `trond version`).
2. Pre-places the FullNode.jar passed via `STEST_JAR` at
   `/opt/tron/stest-singlenode/FullNode.jar`.
3. Runs `trond recipe run system-test`, which validates the intent,
   pre-flights the host, applies a systemd-managed deployment, and
   waits for the HTTP endpoint to come up.

After this script exits 0 the node is reachable on the ports
hardcoded in `testcase/src/test/resources/testng.conf`:

| Endpoint                          | Port  |
|----------------------------------|-------|
| FullNode HTTP (testng.conf:27)   | 8090  |
| FullNode gRPC (testng.conf:8)    | 50051 |
| FullNode JSON-RPC HTTP           | 8545  |
| P2P listen                       | 18888 |

### Usage (CI)

```yaml
- name: Bring up stest single-SR
  run: bash system-test/scripts/stest-up.sh
  env:
    STEST_JAR: ${{ github.workspace }}/java-tron/build/libs/FullNode.jar

- name: Run system tests
  working-directory: system-test
  run: ./gradlew --info stest --no-daemon

- name: Tear down
  if: always()
  run: bash system-test/scripts/stest-down.sh
```

### Usage (local dev, Linux only)

```bash
# Build java-tron from your branch first:
cd java-tron && ./gradlew clean build -x test

# Bring up the node:
STEST_JAR="$PWD/build/libs/FullNode.jar" bash ../system-test/scripts/stest-up.sh

# Run a subset of testcases:
cd ../system-test && ./gradlew :testcase:singleNodeBuild

# Clean up:
bash scripts/stest-down.sh
```

### Configuration env vars

See the script header (`stest-up.sh`) for the full list. The most
common to override:

- `TROND_RELEASE_URL` — point at a different fork's release; defaults
  to the warku123 fork while this integration is under review.
- `TROND_VERSION` — pin a specific trond release.
- `STEST_NODE_NAME` — change the trond deployment name (default:
  `stest-singlenode`).

## stest-down.sh

Best-effort teardown:

1. `trond network destroy <name>`.
2. Falls back to direct `systemctl stop / disable / rm` of the unit
   if trond is unavailable or its destroy returned non-zero.
3. Wipes `/opt/tron/stest-singlenode/` (chain DB + logs) unless
   `STEST_KEEP_DATA=1` is set.

Always exits 0, so it is safe to chain via `if: always()` even after
a failing test step.

## Requirements

- Linux with systemd (Ubuntu, Debian, RHEL, etc.) — does **not**
  work on macOS or in containers without systemd as PID 1.
- `sudo` (passwordless or interactive) — trond's jar runtime writes
  to `/etc/systemd/system/`.
- JDK 8 on PATH — the FullNode.jar from a JDK 8 build is what
  java-tron CI produces.
- Network access to the configured `TROND_RELEASE_URL` (default:
  GitHub Releases).

## Coexistence with the existing manual flow

These scripts are additive. The original launch path
(`run-singlenode.sh`, manual `java -jar`) still works for anyone
who has not switched. Once java-tron's `system-test.yml` has been
updated to call `stest-up.sh`, the inline `nohup java -jar` block
is gone, but nothing in `testcase/` changes.
