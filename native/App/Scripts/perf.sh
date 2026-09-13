#!/bin/zsh
# make perf: the profile build in isolated, invisible runs (`DebugPerf`), one after another so they never
# compete: the tab and size checks, then the measurements with working cats in the meadow. Prints each
# run's table; fails when a check fails or a measurement passes its limit (`--perf-limits`).
#
#   Scripts/perf.sh <Whiskr.app> <folder for the runs>
set -u
app=$1
runs=$2
mkdir -p "$runs"
failed=0

run() {
    local name=$1; shift
    local dir="$runs/$name"
    rm -rf "$dir"; mkdir -p "$dir"
    "$app/Contents/MacOS/Whiskr" --isolated "$dir/isolated" --background --perf "$dir/table.txt" --perf-limits "$@" > "$dir/log.txt" 2>&1 &
    local pid=$!
    # Ten minutes at most; then that run, and only it, is stopped.
    local waited=0
    while kill -0 $pid 2>/dev/null && (( waited < 600 )); do sleep 1; (( waited++ )); done
    if kill -0 $pid 2>/dev/null; then
        echo "$name: still running after ten minutes; stopping it"
        kill $pid; sleep 2; kill -9 $pid 2>/dev/null
        failed=1
    fi
    wait $pid
    local code=$?
    cat "$dir/table.txt" 2>/dev/null || tail -20 "$dir/log.txt"
    if (( code != 0 )); then
        echo "$name: failed (exit $code; 70 is a crash, 1 a check or a limit). Log: $dir/log.txt"
        failed=1
    fi
    echo
}

run checks --window 1440x900 --perf-flows closing,sizes
run measure --window 1440x900 --perf-cats
exit $failed
