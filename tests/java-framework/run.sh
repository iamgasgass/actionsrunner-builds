#!/bin/bash
# Runs Husk's Java framework on a desktop JVM against HostTest: job scheduling (latency, enqueued work, cancel), the service
# lifecycle (bind/rebind/start ids/destroy), DownloadManager over a local HTTP server, MessageQueue idle handlers and a few
# small classes. Needs a JDK (javac 11+). Usage: tests/java-framework/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/../../src/java-framework"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
javac -nowarn --release 8 -encoding UTF-8 -d "$TMP/stubs" $(find "$FW/stubs" -name '*.java')
javac -nowarn --release 8 -encoding UTF-8 -Xmaxerrs 100 -cp "$TMP/stubs" -d "$TMP/fw" $(find "$FW/src" "$FW/gen-src" -name '*.java') 2>&1 | grep -v '^Note:' || true
mkdir -p "$TMP/shadow/husk"
python3 "$HERE/shadow_native.py" "$FW/src/husk/Native.java" "$TMP/shadow/husk/Native.java"
javac -nowarn -encoding UTF-8 -cp "$TMP/fw:$TMP/stubs" -d "$TMP/test" "$TMP/shadow/husk/Native.java" "$HERE/HostTest.java"
java -cp "$TMP/test:$TMP/fw:$TMP/stubs" HostTest
