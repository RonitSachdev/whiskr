#!/bin/zsh
# make perf: the profile build in isolated, invisible runs (`DebugPerf`), one after another so they never
# compete: the checks (closing tabs, sizes, interactions), then the measurements with working cats in the
# meadow, then the editor on big files. Prints each run's table; fails when a check fails or a measurement
# passes its limit (`--perf-limits`, `--measure-limits`).
#
#   Scripts/perf.sh <Whiskr.app> <folder for the runs>
set -u
app=$1
runs=$2
mkdir -p "$runs"
failed=0

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
    (( code != 0 )) && stop_host "$dir"
    cat "$dir/table.txt" 2>/dev/null || tail -20 "$dir/log.txt"
    if (( code != 0 )); then
        echo "$name: failed (exit $code; 70 is a crash, 1 a check or a limit). Log: $dir/log.txt"
        failed=1
    fi
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
    "$app/Contents/MacOS/Whiskr" --isolated "$dir/isolated" --background --window 1440x900 --folder "${file:h}" \
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
    if (( code != 0 )); then
        echo "$name: failed (exit $code; 70 is a crash, 1 a limit). Log: $dir/log.txt"
        failed=1
    fi
    echo
}

run checks --window 1440x900 --perf-flows closing,sizes,interactions
run measure --window 1440x900 --perf-cats
make_editor_files "$runs/editor-files"
editor editor-swift "$runs/editor-files/big50k.swift"
editor editor-typescript "$runs/editor-files/big50k.ts"
editor editor-minified "$runs/editor-files/minified.js" long-lines
editor editor-long-lines "$runs/editor-files/longlines.ts"
exit $failed
