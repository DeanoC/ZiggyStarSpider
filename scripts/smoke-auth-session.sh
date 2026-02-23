#!/usr/bin/env bash
# Auth/session smoke checks for ZiggyStarSpider.
# Covers auth role matrix, token rotation, and session_busy behavior.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZSS_BIN="${ZSS_BIN:-$ROOT_DIR/zig-out/bin/zss}"
SPIDERWEB_URL="${SPIDERWEB_URL:-ws://127.0.0.1:18790}"
SPIDERWEB_CONTROL_BIN="${SPIDERWEB_CONTROL_BIN:-spiderweb-control}"

SMOKE_ADMIN_TOKEN="${SMOKE_ADMIN_TOKEN:-}"
SMOKE_USER_TOKEN="${SMOKE_USER_TOKEN:-}"
SMOKE_SKIP_SESSION_BUSY="${SMOKE_SKIP_SESSION_BUSY:-0}"
SMOKE_REQUIRE_SESSION_BUSY="${SMOKE_REQUIRE_SESSION_BUSY:-1}"
SMOKE_SKIP_CHAT="${SMOKE_SKIP_CHAT:-0}"
SMOKE_SESSION_AGENT_ID="${SMOKE_SESSION_AGENT_ID:-default}"
SMOKE_SESSION_BUSY_PROMPT="${SMOKE_SESSION_BUSY_PROMPT:-session busy smoke: produce a long, detailed response with at least 2500 words and explicit section headings.}"
SMOKE_SESSION_BUSY_MAX_ATTEMPTS="${SMOKE_SESSION_BUSY_MAX_ATTEMPTS:-30}"
SMOKE_SESSION_BUSY_POLL_SEC="${SMOKE_SESSION_BUSY_POLL_SEC:-0.25}"

log() {
    printf '[smoke-auth] %s\n' "$1"
}

fail() {
    printf '[smoke-auth] ERROR: %s\n' "$1" >&2
    exit 1
}

extract_field() {
    local key="$1"
    local text="$2"
    printf '%s\n' "$text" | awk -v k="$key" '$1 == (k ":") { print $2; exit }'
}

run_admin() {
    if [[ -n "$SMOKE_ADMIN_TOKEN" ]]; then
        "$ZSS_BIN" --url "$SPIDERWEB_URL" --role admin --operator-token "$SMOKE_ADMIN_TOKEN" "$@"
    else
        "$ZSS_BIN" --url "$SPIDERWEB_URL" --role admin "$@"
    fi
}

run_user() {
    if [[ -z "$SMOKE_USER_TOKEN" ]]; then
        fail "SMOKE_USER_TOKEN is empty; run admin auth status/rotate first or set env explicitly"
    fi
    "$ZSS_BIN" --url "$SPIDERWEB_URL" --role user --operator-token "$SMOKE_USER_TOKEN" "$@"
}

if [[ ! -x "$ZSS_BIN" ]]; then
    fail "missing CLI binary: $ZSS_BIN"
fi

verify_user_forbidden_with_control() {
    local control_out_file="$1"
    if ! command -v "$SPIDERWEB_CONTROL_BIN" >/dev/null 2>&1; then
        return 1
    fi
    if "$SPIDERWEB_CONTROL_BIN" --url "$SPIDERWEB_URL" --auth-token "$SMOKE_USER_TOKEN" auth_status >"$control_out_file" 2>&1; then
        return 1
    fi
    grep -Eq 'forbidden|requires admin token|"code":"forbidden"' "$control_out_file"
}

log "admin auth status reveal"
if ! status_reveal="$(run_admin auth status --reveal 2>&1)"; then
    printf '%s\n' "$status_reveal" >&2
    fail "admin auth status --reveal failed"
fi
printf '%s\n' "$status_reveal"

parsed_admin="$(extract_field "admin_token" "$status_reveal")"
parsed_user="$(extract_field "user_token" "$status_reveal")"
if [[ -z "$SMOKE_ADMIN_TOKEN" ]]; then
    SMOKE_ADMIN_TOKEN="$parsed_admin"
fi
if [[ -z "$SMOKE_USER_TOKEN" ]]; then
    SMOKE_USER_TOKEN="$parsed_user"
fi
[[ -n "$SMOKE_ADMIN_TOKEN" ]] || fail "unable to resolve admin token"
[[ -n "$SMOKE_USER_TOKEN" ]] || fail "unable to resolve user token"

log "user auth status should be forbidden"
tmp_forbidden="$(mktemp)"
tmp_forbidden_control="$(mktemp)"
trap 'rm -f "$tmp_forbidden" "$tmp_forbidden_control"' EXIT
if run_user auth status >"$tmp_forbidden" 2>&1; then
    cat "$tmp_forbidden"
    fail "expected user auth status to fail with forbidden"
fi
if ! grep -Eq 'forbidden|requires admin token|"code":"forbidden"' "$tmp_forbidden"; then
    if grep -q 'RemoteError' "$tmp_forbidden" && verify_user_forbidden_with_control "$tmp_forbidden_control"; then
        log "user auth status returned RemoteError in zss output; control-plane confirms forbidden"
    else
        cat "$tmp_forbidden"
        if [[ -s "$tmp_forbidden_control" ]]; then
            printf '[smoke-auth] control fallback output:\n'
            cat "$tmp_forbidden_control"
        fi
        fail "user auth status failed but missing forbidden marker"
    fi
fi

log "rotate user token via admin"
if ! rotate_user_out="$(run_admin auth rotate user --reveal 2>&1)"; then
    printf '%s\n' "$rotate_user_out" >&2
    fail "admin auth rotate user failed"
fi
printf '%s\n' "$rotate_user_out"
new_user="$(extract_field "token" "$rotate_user_out")"
[[ -n "$new_user" ]] || fail "failed to parse rotated user token"
SMOKE_USER_TOKEN="$new_user"

log "user auth status still forbidden with new user token"
if run_user auth status >"$tmp_forbidden" 2>&1; then
    cat "$tmp_forbidden"
    fail "expected user auth status to fail after rotate"
fi
if ! grep -Eq 'forbidden|requires admin token|"code":"forbidden"' "$tmp_forbidden"; then
    if grep -q 'RemoteError' "$tmp_forbidden" && verify_user_forbidden_with_control "$tmp_forbidden_control"; then
        log "post-rotate user auth status returned RemoteError in zss output; control-plane confirms forbidden"
    else
        cat "$tmp_forbidden"
        if [[ -s "$tmp_forbidden_control" ]]; then
            printf '[smoke-auth] control fallback output:\n'
            cat "$tmp_forbidden_control"
        fi
        fail "user auth status post-rotate failed but missing forbidden marker"
    fi
fi

log "rotate admin token via admin"
if ! rotate_admin_out="$(run_admin auth rotate admin --reveal 2>&1)"; then
    printf '%s\n' "$rotate_admin_out" >&2
    fail "admin auth rotate admin failed"
fi
printf '%s\n' "$rotate_admin_out"
new_admin="$(extract_field "token" "$rotate_admin_out")"
[[ -n "$new_admin" ]] || fail "failed to parse rotated admin token"
SMOKE_ADMIN_TOKEN="$new_admin"

log "admin auth status with new token"
if ! status_after_rotate="$(run_admin auth status 2>&1)"; then
    printf '%s\n' "$status_after_rotate" >&2
    fail "admin auth status failed after admin rotate"
fi
printf '%s\n' "$status_after_rotate"

if [[ "$SMOKE_SKIP_SESSION_BUSY" == "1" || "$SMOKE_SKIP_CHAT" == "1" ]]; then
    log "session_busy check skipped"
    log "auth/session smoke checks completed (session_busy skipped)"
    exit 0
fi

if ! command -v "$SPIDERWEB_CONTROL_BIN" >/dev/null 2>&1; then
    if [[ "$SMOKE_REQUIRE_SESSION_BUSY" == "1" ]]; then
        fail "SPIDERWEB_CONTROL_BIN not found: $SPIDERWEB_CONTROL_BIN"
    fi
    log "session_busy check skipped (missing $SPIDERWEB_CONTROL_BIN)"
    log "auth/session smoke checks completed (session_busy skipped)"
    exit 0
fi

log "session_busy check (background chat + session_attach probes)"
chat_log="$(mktemp)"
attach_log="$(mktemp)"
trap 'rm -f "$tmp_forbidden" "$chat_log" "$attach_log"' EXIT

"$ZSS_BIN" --url "$SPIDERWEB_URL" --role admin --operator-token "$SMOKE_ADMIN_TOKEN" chat send "$SMOKE_SESSION_BUSY_PROMPT" >"$chat_log" 2>&1 &
chat_pid=$!

busy_detected=0
attempt=0
payload="$(printf '{"session_key":"main","agent_id":"%s","project_id":"proj-session-busy-smoke"}' "$SMOKE_SESSION_AGENT_ID")"
while kill -0 "$chat_pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if "$SPIDERWEB_CONTROL_BIN" --url "$SPIDERWEB_URL" --auth-token "$SMOKE_ADMIN_TOKEN" session_attach "$payload" >"$attach_log" 2>&1; then
        true
    else
        if grep -q '"code":"session_busy"' "$attach_log"; then
            busy_detected=1
            break
        fi
    fi
    if [[ "$attempt" -ge "$SMOKE_SESSION_BUSY_MAX_ATTEMPTS" ]]; then
        break
    fi
    sleep "$SMOKE_SESSION_BUSY_POLL_SEC"
done

wait "$chat_pid" || true

if [[ "$busy_detected" != "1" ]]; then
    if [[ "$SMOKE_REQUIRE_SESSION_BUSY" == "1" ]]; then
        printf '[smoke-auth] chat log:\n'
        cat "$chat_log"
        printf '[smoke-auth] attach log:\n'
        cat "$attach_log"
        fail "session_busy was not observed"
    fi
    log "session_busy was not observed (non-fatal)"
else
    log "session_busy observed"
fi

log "auth/session smoke checks completed successfully"
