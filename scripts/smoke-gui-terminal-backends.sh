#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_BIN="${ZIG_BIN:-zig}"
GUI_BIN="$ROOT_DIR/zig-out/bin/zss-gui"
WIN_GUI_BIN="$ROOT_DIR/zig-out/bin/zss-gui.exe"
SMOKE_TIMEOUT_SEC="${SMOKE_TIMEOUT_SEC:-12}"
SMOKE_SKIP_WINDOWS="${SMOKE_SKIP_WINDOWS:-0}"
SMOKE_SKIP_LINUX="${SMOKE_SKIP_LINUX:-0}"
SMOKE_TMP_DIR=""

log() {
    printf '[smoke-gui] %s\n' "$1"
}

cleanup() {
    if [[ -n "$SMOKE_TMP_DIR" && -d "$SMOKE_TMP_DIR" ]]; then
        rm -rf "$SMOKE_TMP_DIR"
    fi
}
trap cleanup EXIT

run_alive() {
    local label="$1"
    shift
    local log_file
    log_file="$(mktemp)"
    log "$label"
    set +e
    timeout "${SMOKE_TIMEOUT_SEC}s" "$@" >"$log_file" 2>&1
    local rc=$?
    set -e
    if [[ $rc -ne 0 && $rc -ne 124 ]]; then
        printf '[smoke-gui] %s failed (exit=%s)\n' "$label" "$rc" >&2
        cat "$log_file" >&2
        rm -f "$log_file"
        return 1
    fi
    rm -f "$log_file"
}

ensure_tools() {
    command -v "$ZIG_BIN" >/dev/null 2>&1 || {
        echo "[smoke-gui] missing zig binary: $ZIG_BIN" >&2
        exit 1
    }
    command -v xvfb-run >/dev/null 2>&1 || {
        echo "[smoke-gui] missing xvfb-run (required for GUI smoke tests)" >&2
        exit 1
    }
}

build_gui() {
    local backend="$1"
    log "building GUI backend=$backend"
    (cd "$ROOT_DIR" && "$ZIG_BIN" build gui "-Dterminal-backend=$backend")
}

build_windows_gui() {
    local backend="$1"
    log "building Windows GUI backend=$backend"
    (cd "$ROOT_DIR" && "$ZIG_BIN" build gui -Dtarget=x86_64-windows-gnu "-Dterminal-backend=$backend")
}

build_stub_libs() {
    SMOKE_TMP_DIR="$(mktemp -d)"
    log "building stub libghostty-vt shared libraries"
    "$ZIG_BIN" cc -shared -fPIC -O2 -o "$SMOKE_TMP_DIR/libghostty-vt.so" "$ROOT_DIR/scripts/ghostty_vt_stub.c"
    "$ZIG_BIN" cc -target x86_64-windows-gnu -shared -O2 -o "$SMOKE_TMP_DIR/ghostty-vt.dll" "$ROOT_DIR/scripts/ghostty_vt_stub.c"
}

smoke_linux() {
    build_gui plain
    [[ -x "$GUI_BIN" ]] || {
        echo "[smoke-gui] missing GUI binary: $GUI_BIN" >&2
        exit 1
    }
    run_alive "linux plain backend startup" xvfb-run -a "$GUI_BIN"

    build_gui ghostty-vt
    run_alive "linux ghostty backend (library missing -> fallback)" env LD_LIBRARY_PATH="" xvfb-run -a "$GUI_BIN"

    build_stub_libs
    run_alive "linux ghostty backend (library present)" env LD_LIBRARY_PATH="$SMOKE_TMP_DIR" xvfb-run -a "$GUI_BIN"
}

smoke_windows() {
    if [[ "$SMOKE_SKIP_WINDOWS" == "1" ]]; then
        log "windows smoke skipped (SMOKE_SKIP_WINDOWS=1)"
        return
    fi
    if ! command -v wine >/dev/null 2>&1; then
        log "wine not found; skipping windows smoke"
        return
    fi

    build_windows_gui ghostty-vt
    [[ -f "$WIN_GUI_BIN" ]] || {
        echo "[smoke-gui] missing Windows GUI binary: $WIN_GUI_BIN" >&2
        exit 1
    }

    run_alive "windows ghostty backend under wine (library missing -> fallback)" env WINEDEBUG=-all xvfb-run -a wine "$WIN_GUI_BIN"

    build_stub_libs
    cp "$SMOKE_TMP_DIR/ghostty-vt.dll" "$ROOT_DIR/zig-out/bin/ghostty-vt.dll"
    run_alive "windows ghostty backend under wine (library present)" env WINEDEBUG=-all xvfb-run -a wine "$WIN_GUI_BIN"
    rm -f "$ROOT_DIR/zig-out/bin/ghostty-vt.dll"
}

ensure_tools

if [[ "$SMOKE_SKIP_LINUX" != "1" ]]; then
    smoke_linux
else
    log "linux smoke skipped (SMOKE_SKIP_LINUX=1)"
fi
smoke_windows

log "GUI terminal backend smoke completed"
