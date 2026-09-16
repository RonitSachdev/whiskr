#!/bin/zsh
# make perf: the profile build in isolated, invisible runs (`DebugPerf`), one after another so they never
# compete: the checks (closing tabs, sizes, interactions; resizing; the bars' controls; alerts; the meadow
# following what you choose; split tabs, tabs dragged, New Workspace from every place; the real sky and
# weather and their switches; editing the meadow, and the meadow edited found again after a relaunch), then
# the measurements with working cats in the meadow (the last of them the
# interface's transitions, frame by frame: `DebugAnimations`), then the editor on big files. Prints each
# run's table; fails when a check fails or a measurement passes its limit (`--perf-limits`, `--measure-limits`).
# Timings are only comparable on a quiet Mac: each run
# waits (up to ten minutes) until other programs keep at most one core busy, says how busy the Mac was, and
# a limit passed while it was busy (`MachineLoad`, measured by the run itself) makes the run "not
# comparable" (exit 3) rather than failed or passed. The meadow is shown by day (the idle flow measures day
# and night itself): nothing here depends on the time it is run.
#
#   Scripts/perf.sh <Whiskr.app> <folder for the runs>
set -u
app=$1
runs=$2
mkdir -p "$runs"
failed=0
undecided=0

# Others' load now, in cores: the Mac's busy share over two seconds, as `top` counts it, times its cores.
# Nothing of ours is running between runs, so all of it is someone else's.
busy_cores=1.0
others_load() {
    local idle=$(top -l 2 -s 2 -n 0 | awk '/^CPU usage/ { value = $7 } END { sub("%", "", value); print value }')
    print -- $(( (100.0 - idle) * $(sysctl -n hw.activecpu) / 100.0 ))
}
wait_until_quiet() {
    local name=$1 waited=0 load=$(others_load) note=""
    while (( load > busy_cores && waited < 600 )); do
        sleep 20; (( waited += 20 )); load=$(others_load)
    done
    (( waited > 0 )) && note=" (after waiting $waited s)"
    (( load > busy_cores )) && note=" (still busy after waiting $waited s: a limit it passes is not comparable)"
    printf "%s: others' load before it %.1f cores%s\n" $name $load "$note"
}

# A run's exit status: 0 held, 3 not comparable (a limit passed while the Mac was busy), anything else failed.
judge() {
    local name=$1 code=$2 log=$3
    if (( code == 3 )); then
        echo "$name: not comparable: a limit was passed while the Mac was busy. Log: $log"
        undecided=1
    elif (( code != 0 )); then
        echo "$name: failed (exit $code; 70 is a crash, 1 a check or a limit). Log: $log"
        failed=1
    fi
}

# The session host of one run, found only by the lock it holds in that run's own isolated folder
# (`<dir>/isolated/host/host.lock`), never by name: a run stopped at its timeout, or one that crashed, leaves
# it running (a host outlives its app on purpose), and it must not overlap the next run.
stop_host() {
    local lock="$1/isolated/host/host.lock"
    [[ -e $lock ]] || return
    local pid
    for pid in $(lsof -t "$lock" 2>/dev/null); do
        [[ $(ps -o comm= -p $pid 2>/dev/null) == */whiskr-host ]] || continue
        echo "stopping the run's own session host ($pid)"
        kill $pid; sleep 1; kill -9 $pid 2>/dev/null
    done
}

run() {
    local name=$1; shift
    local dir="$runs/$name"
    rm -rf "$dir"; mkdir -p "$dir"
    wait_until_quiet $name
    "$app/Contents/MacOS/Whiskr" --isolated "$dir/isolated" --background --time day --perf "$dir/table.txt" --perf-limits "$@" > "$dir/log.txt" 2>&1 &
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
    (( code != 0 )) && stop_host "$dir"
    cat "$dir/table.txt" 2>/dev/null || tail -20 "$dir/log.txt"
    judge $name $code "$dir/log.txt"
    echo
}

# The journey (`DebugFlowJourney.swift`) across quitting: three runs on one isolated folder. The first leaves
# its terminals running (as ⌘Q does); the second, a relaunch, finds them as they were and ends with ⌥⌘Q; the
# third checks nothing of it still runs.
journey() {
    local dir="$runs/journey" phase code
    rm -rf "$dir"; mkdir -p "$dir"
    wait_until_quiet journey
    for phase in first relaunch stopped; do
        local args=(--isolated "$dir/isolated" --background --time day --window 1440x900 --perf "$dir/table-$phase.txt" --perf-limits --perf-flows journey)
        case $phase in
            first) args+=(--leave-host) ;;
            *) args+=(--journey-phase $phase --keep-settings) ;;
        esac
        "$app/Contents/MacOS/Whiskr" $args > "$dir/log-$phase.txt" 2>&1 &
        local pid=$! waited=0
        while kill -0 $pid 2>/dev/null && (( waited < 600 )); do sleep 1; (( waited++ )); done
        if kill -0 $pid 2>/dev/null; then
            echo "journey ($phase): still running after ten minutes; stopping it"
            kill $pid; sleep 2; kill -9 $pid 2>/dev/null
            failed=1
        fi
        wait $pid
        code=$?
        cat "$dir/table-$phase.txt" 2>/dev/null || tail -20 "$dir/log-$phase.txt"
        judge "journey ($phase)" $code "$dir/log-$phase.txt"
        (( code != 0 )) && break
    done
    stop_host "$dir"
    echo
}

# Editing the meadow (`DebugFlowEditor.swift`): two runs on one isolated folder. The first edits and quits
# (a move made just before ⌘Q must be saved at quit); the second, a relaunch, finds that meadow shown as saved.
meadow_editor() {
    local dir="$runs/meadow-editor" phase code
    rm -rf "$dir"; mkdir -p "$dir"
    wait_until_quiet meadow-editor
    for phase in first relaunch; do
        local args=(--isolated "$dir/isolated" --background --time day --window 1440x900 --perf "$dir/table-$phase.txt" --perf-limits --perf-flows editor
                    --editor-pictures "$dir/pictures")
        [[ $phase == relaunch ]] && args+=(--editor-phase relaunch --keep-settings)
        "$app/Contents/MacOS/Whiskr" $args > "$dir/log-$phase.txt" 2>&1 &
        local pid=$! waited=0
        while kill -0 $pid 2>/dev/null && (( waited < 600 )); do sleep 1; (( waited++ )); done
        if kill -0 $pid 2>/dev/null; then
            echo "meadow-editor ($phase): still running after ten minutes; stopping it"
            kill $pid; sleep 2; kill -9 $pid 2>/dev/null
            failed=1
        fi
        wait $pid
        code=$?
        cat "$dir/table-$phase.txt" 2>/dev/null || tail -20 "$dir/log-$phase.txt"
        judge "meadow-editor ($phase)" $code "$dir/log-$phase.txt"
        (( code != 0 )) && break
    done
    stop_host "$dir"
    echo
}

# The editor on big files (`DebugFiles --measure-files`): opening, colouring off the main thread, scrolling,
# jumping, typing, opening a comment that recolours the rest, reverting. Each run fails when a timing passes
# its limit (`EditorLimits`). The files are made here: 50,000 lines of this repository's Swift, 50,000 lines
# of TypeScript, a minified script of one 2 MB line, and a file mixing short lines with lines of 22,800
# characters, too long to tokenize.
# This script's folder (inside a function, $0 is the function's name).
scripts=${0:A:h}
make_editor_files() {
    local files=$1 here=$scripts/..
    mkdir -p "$files"
    local swift=$(find "$here/Whiskr" "$here/WhiskrKit/Sources" -name '*.swift' -print0 | sort -z | xargs -0 cat)
    { print -r -- "$swift"; print -r -- "$swift" } | head -50000 > "$files/big50k.swift"
    local i
    for (( i = 0; i < 2000; i++ )); do
        print -r -- "/** A service, number $i, with \`docs\` and {@link Other$i}. */
export class Service$i<T extends object = {}> implements Disposable {
    private readonly cache = new Map<string, T[]>();
    static readonly pattern = /^(?:[a-z]+|\\d{2,})\$/gi;

    constructor(private readonly name: string, protected count = 0x1F) {
        super();
    }

    async load(path: string, options?: { retry: boolean }): Promise<T | undefined> {
        const key = \`\${this.name}:\${path}\`;
        if (this.cache.has(key) && options?.retry !== true) {
            return this.cache.get(key)?.[0];
        }
        // Not cached yet: read it.
        const value = await fetch(path).then(r => r.json() as Promise<T>);
        this.cache.set(key, [value]);
        return value;
    }

    dispose(): void {
        this.cache.clear();
    }
}
"
    done > "$files/big50k.ts"
    local snippet='var a=function(b,c){return b+c*2},d={e:"f",g:[1,2,3],h:/x+/g};if(a(1,2)>3){d.e="i"}else{d.g.push(4)};'
    { repeat 20000 print -nr -- "$snippet"; print } > "$files/minified.js"
    local long=$(repeat 600 print -nr -- 'const value = "a string", other = 42; ')
    for (( i = 0; i < 150; i++ )); do
        print -r -- "function step$i(x: number): number { return x * $i; } // line $i"
        print -r -- "$long"
    done > "$files/longlines.ts"
}

editor() {
    local name=$1 file=$2; shift 2
    local dir="$runs/$name"
    rm -rf "$dir"; mkdir -p "$dir"
    wait_until_quiet $name
    "$app/Contents/MacOS/Whiskr" --isolated "$dir/isolated" --background --time day --window 1440x900 --folder "${file:h}" \
        --measure-files "$dir/report.txt" --measure-file "$file" --measure-limits "$@" > "$dir/log.txt" 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 $pid 2>/dev/null && (( waited < 600 )); do sleep 1; (( waited++ )); done
    if kill -0 $pid 2>/dev/null; then
        echo "$name: still running after ten minutes; stopping it"
        kill $pid; sleep 2; kill -9 $pid 2>/dev/null
        failed=1
    fi
    wait $pid
    local code=$?
    stop_host "$dir"
    echo "$name"
    cat "$dir/report.txt" 2>/dev/null || tail -20 "$dir/log.txt"
    judge $name $code "$dir/log.txt"
    echo
}

run checks --window 1440x900 --perf-flows closing,sizes,interactions
journey
run files --window 1440x900 --perf-flows files
run layout --window 1440x900 --perf-flows layout
run chrome --window 1440x900 --perf-flows chrome
run robust --window 1440x900 --perf-flows robust
run alerts --window 1440x900 --perf-flows alerts
run meadow --window 1440x900 --perf-flows meadow
run resize --window 1440x900 --perf-flows resize
run split --window 1440x900 --perf-flows split
run drag --window 1440x900 --perf-flows drag
run home --window 1440x900 --perf-flows home
run sky --window 1440x900 --perf-flows sky
meadow_editor
run measure --window 1440x900 --perf-cats
make_editor_files "$runs/editor-files"
editor editor-swift "$runs/editor-files/big50k.swift"
editor editor-typescript "$runs/editor-files/big50k.ts"
editor editor-minified "$runs/editor-files/minified.js" long-lines
editor editor-long-lines "$runs/editor-files/longlines.ts"
if (( failed )); then echo "make perf: FAILED"; exit 1; fi
if (( undecided )); then echo "make perf: NOT COMPARABLE (the Mac was busy while a limit was passed; run it again when it is quiet)"; exit 3; fi
echo "make perf: every check and limit held"
