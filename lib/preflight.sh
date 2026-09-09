#!/bin/bash
# =====================================================================
# preflight.sh - eligibility and environment checks before prompting.
#
# Preserves the original script's gates:
#   1. primary_user_id already set -> device already bound, skip.
#   2. wait for a REAL console user (not root/_mbsetupuser/loginwindow).
#   3. _jumpcloudserviceaccount must hold a Secure Token, else skip
#      silently (JumpCloud cannot manage the local password without it).
# Adds defer/completion state so "Remind Me Later" can work.
# =====================================================================

CONSOLE_USER=""
CONSOLE_UID=""

jc_require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        jc_error "Must run as root. Current uid: ${EUID:-$(id -u)}"
        return 1
    fi
    return 0
}

# Returns 0 if the device is already bound (per the MDM attribute).
jc_already_bound() {
    if [[ -n "${PRIMARY_USER_ID:-}" && "${PRIMARY_USER_ID}" != "0" ]]; then
        jc_info "Primary user already set (ID: ${PRIMARY_USER_ID}). Nothing to do."
        return 0
    fi
    return 1
}

# Poll /dev/console until a real interactive user owns it.
jc_wait_for_console_user() {
    local waited=0 u
    while (( waited < CONSOLE_USER_WAIT_MAX )); do
        u="$(stat -f "%Su" /dev/console 2>/dev/null || echo "")"
        case "$u" in
            ""|root|_mbsetupuser|loginwindow)
                jc_info "Console user is '${u:-<empty>}'; waiting ${CONSOLE_USER_WAIT_INTERVAL}s..."
                sleep "${CONSOLE_USER_WAIT_INTERVAL}"
                waited=$(( waited + CONSOLE_USER_WAIT_INTERVAL ))
                ;;
            *)
                CONSOLE_USER="$u"
                CONSOLE_UID="$(id -u "$u" 2>/dev/null || echo "")"
                [[ -z "$CONSOLE_UID" ]] && return 1
                jc_info "Console user: ${CONSOLE_USER} (uid ${CONSOLE_UID})"
                return 0
                ;;
        esac
    done
    jc_error "Timed out after ${CONSOLE_USER_WAIT_MAX}s waiting for a console user."
    return 1
}

# Secure Token gate. Returns 0 when enrollment may proceed.
jc_check_secure_token() {
    local status
    if [[ "${REQUIRE_SECURE_TOKEN}" != "1" ]]; then
        jc_warn "Secure Token gate disabled by configuration."
        return 0
    fi
    status="$(sysadminctl -secureTokenStatus "$JC_SVC_ACCOUNT" 2>&1)"
    jc_info "Service account token check: ${status}"
    if printf '%s' "$status" | grep -q "ENABLED"; then
        jc_info "Service account Secure Token confirmed ENABLED."
        return 0
    fi
    jc_warn "${JC_SVC_ACCOUNT} missing or lacks Secure Token - not prompting."
    return 1
}

jc_missing_tools() {
    local t missing=()
    for t in curl sed tr grep mktemp head stat sysadminctl launchctl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if (( ${#missing[@]} > 0 )); then
        jc_error "Missing required tools: ${missing[*]}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# Defer / completion state (plain files - simple and robust).
# ---------------------------------------------------------------------
jc_state_init() {
    mkdir -p "$JC_STATE_DIR" 2>/dev/null || true
    chmod 755 "$JC_STATE_DIR" 2>/dev/null || true
}

jc_state_path() { printf '%s/%s' "$JC_STATE_DIR" "$1"; }

jc_mark_completed() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$(jc_state_path completed)" 2>/dev/null || true
}

jc_is_completed() {
    [[ -f "$(jc_state_path completed)" ]]
}

# Returns 0 while a defer is still active.
jc_defer_active() {
    local f now until
    f="$(jc_state_path defer_until)"
    [[ -f "$f" ]] || return 1
    until="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$until" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    if (( now < until )); then
        jc_info "Defer active until epoch ${until} - not prompting."
        return 0
    fi
    return 1
}

jc_record_defer() {
    local count until
    count="$(cat "$(jc_state_path defer_count)" 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$(( count + 1 ))
    until=$(( $(date +%s) + DEFER_MINUTES * 60 ))
    printf '%s' "$until" > "$(jc_state_path defer_until)" 2>/dev/null || true
    printf '%s' "$count" > "$(jc_state_path defer_count)" 2>/dev/null || true
    jc_info "User deferred; next prompt after epoch ${until} (defer #${count})"
}

# Returns 0 when "Remind Me Later" may still be offered.
jc_defer_allowed() {
    local count deadline_epoch now
    if (( DEFER_MAX_COUNT > 0 )); then
        count="$(cat "$(jc_state_path defer_count)" 2>/dev/null || echo 0)"
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        if (( count >= DEFER_MAX_COUNT )); then
            jc_warn "Defer limit reached (${count}/${DEFER_MAX_COUNT})."
            return 1
        fi
    fi
    if [[ -n "${DEFER_DEADLINE_UTC:-}" ]]; then
        # BSD date (macOS) parsing of ISO-8601.
        deadline_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$DEFER_DEADLINE_UTC" +%s 2>/dev/null || echo "")"
        if [[ -n "$deadline_epoch" ]]; then
            now="$(date +%s)"
            if (( now >= deadline_epoch )); then
                jc_warn "Defer deadline ${DEFER_DEADLINE_UTC} has passed."
                return 1
            fi
        fi
    fi
    return 0
}
