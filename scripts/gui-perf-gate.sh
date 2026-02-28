#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_BIN="${ZIG_BIN:-zig}"
GUI_BIN="$ROOT_DIR/zig-out/bin/zss-gui"
PERF_GATE_DURATION_MS="${PERF_GATE_DURATION_MS:-12000}"
PERF_GATE_MIN_FPS="${PERF_GATE_MIN_FPS:-20}"
PERF_GATE_REPORT="${PERF_GATE_REPORT:-$ROOT_DIR/zig-out/gui-perf-gate-report.txt}"
PERF_GATE_OPTIMIZE="${PERF_GATE_OPTIMIZE:-Debug}"

log() {
    printf '[gui-perf-gate] %s\n' "$1"
}

command -v "$ZIG_BIN" >/dev/null 2>&1 || {
    echo "[gui-perf-gate] missing zig binary: $ZIG_BIN" >&2
    exit 1
}

command -v xvfb-run >/dev/null 2>&1 || {
    echo "[gui-perf-gate] missing xvfb-run" >&2
    exit 1
}

build_cmd=("$ZIG_BIN" "build" "gui")
if [[ "$PERF_GATE_OPTIMIZE" != "Debug" ]]; then
    build_cmd+=("-Doptimize=$PERF_GATE_OPTIMIZE")
fi

log "building GUI (optimize=$PERF_GATE_OPTIMIZE)"
(
    cd "$ROOT_DIR"
    "${build_cmd[@]}"
)

if [[ ! -x "$GUI_BIN" ]]; then
    echo "[gui-perf-gate] missing GUI binary: $GUI_BIN" >&2
    exit 1
fi

rm -f "$PERF_GATE_REPORT"
log "running automated GUI perf benchmark (duration=${PERF_GATE_DURATION_MS}ms min_fps=${PERF_GATE_MIN_FPS})"
(
    cd "$ROOT_DIR"
    env \
        ZSS_GUI_PERF_AUTOMATION=1 \
        ZSS_GUI_PERF_AUTOMATION_DURATION_MS="$PERF_GATE_DURATION_MS" \
        ZSS_GUI_PERF_AUTOMATION_MIN_FPS="$PERF_GATE_MIN_FPS" \
        ZSS_GUI_PERF_AUTOMATION_REPORT="$PERF_GATE_REPORT" \
        xvfb-run -a "$GUI_BIN"
)

if [[ ! -f "$PERF_GATE_REPORT" ]]; then
    echo "[gui-perf-gate] expected perf report not found: $PERF_GATE_REPORT" >&2
    exit 1
fi

latest_fps="$(awk -F= '/^latest_fps=/{print $2; exit}' "$PERF_GATE_REPORT")"
if [[ -z "$latest_fps" ]]; then
    echo "[gui-perf-gate] failed to parse latest_fps from report" >&2
    exit 1
fi

log "pass latest_fps=$latest_fps report=$PERF_GATE_REPORT"
