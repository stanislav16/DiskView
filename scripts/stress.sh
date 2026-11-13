#!/bin/zsh
# Runs the in-app stress test against <path> and profiles the main thread meanwhile.
# Usage: scripts/stress.sh <app> <path> <outdir>
set -u
APP="$1"; TARGET="$2"; OUT="$3"
mkdir -p "$OUT"
DISKVIEW_STRESS="$TARGET" "$APP/Contents/MacOS/DiskView" > "$OUT/stress.log" 2>&1 &
PID=$!
for _ in {1..300}; do grep -q STRESS-START "$OUT/stress.log" 2>/dev/null && break; sleep 0.2; done
sample $PID 6 -file "$OUT/sample.txt" >/dev/null 2>&1
wait $PID
grep -A6 STRESS-RESULT "$OUT/stress.log"
