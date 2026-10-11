#!/bin/bash
# Run `swift test` under a watchdog. If it has not finished after WATCHDOG_SECONDS (default 300),
# sample every process under it into the log (`sample <pid> 10`), then kill it and fail.
# Usage: swift-test-watchdog.sh [swift test arguments...]   (run from the package directory)
# macOS ships bash 3.2: keep this script free of newer bash features.
set -u

limit=${WATCHDOG_SECONDS:-300}
samples=${RUNNER_TEMP:-/tmp}/swift-test-samples
mkdir -p "$samples"

echo "watchdog: hw.ncpu=$(sysctl -n hw.ncpu 2>/dev/null) hw.activecpu=$(sysctl -n hw.activecpu 2>/dev/null)"

swift test "$@" &
test_pid=$!

descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        echo "$child"
        descendants "$child"
    done
}

elapsed=0
while kill -0 "$test_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ]; then
        echo "::error::swift test did not finish within ${limit}s; sampling every process under it"
        for pid in "$test_pid" $(descendants "$test_pid"); do
            command=$(ps -o command= -p "$pid" 2>/dev/null) || continue
            echo "::group::sample $pid: $command"
            sample "$pid" 10 -mayDie -file "$samples/sample-$pid.txt" >/dev/null 2>&1
            cat "$samples/sample-$pid.txt" 2>/dev/null || echo "(sample of $pid produced nothing)"
            echo "::endgroup::"
        done
        for pid in $(descendants "$test_pid") "$test_pid"; do
            kill -9 "$pid" 2>/dev/null
        done
        wait "$test_pid" 2>/dev/null
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

wait "$test_pid"
