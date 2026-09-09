#!/bin/bash
# =====================================================================
# preflight.sh - eligibility and environment checks before prompting.
#
# Preserves the original script's gates:
#   1. primary_user_id already set -> device already bound, skip.
#   2. wait for a REAL console user (not root/_mbsetupuser/loginwindow).
#   3. _jumpcloudserviceaccount must hold a Secure Token, else skip
#      silently (JumpCloud cannot manage the local password without it).
# There is NO local state: whether to prompt is decided ONLY by the
# primary_user_id the MDM command passes in. Nothing on disk can suppress
# or re-schedule the prompt.
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
