#!/bin/bash
# =====================================================================
# ui.sh - user-facing screens, rendered by lib/jc-ui.js (native AppKit).
#
# Zero third-party dependencies: jc-ui.js runs through
# `osascript -l JavaScript`, which ships with every macOS. There is no
# swiftDialog requirement and no plain-osascript fallback - the design
# matches the Windows WPF client (rounded card, brand accent, numbered
# step card, native spinner).
#
# Every screen must appear inside the console user's GUI session, so
# each invocation goes through launchctl asuser + sudo -u.
#
# This layer NEVER handles the password. The credential screen is
# rendered by user/verify-credentials.sh, which runs as the console user
# and returns only a status token - the password never reaches root.
# =====================================================================

UI_PROGRESS_PID=""
UI_RENDERER=""
UI_LAST_JSON=""
UI_PROGRESS_PIDFILE=""

ui_as_user() {
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$@"
}

ui_init() {
    UI_RENDERER="${LIB_DIR}/jc-ui.js"
    if [[ ! -f "$UI_RENDERER" ]]; then
        jc_error "UI renderer missing at ${UI_RENDERER}"
        return 1
    fi
    # Readable by the console user (we run it as them).
    chmod 644 "$UI_RENDERER" 2>/dev/null || true
    jc_info "UI mode: native AppKit (osascript JXA)"
    return 0
}

ui_cleanup() {
    ui_progress_stop
    return 0
}

# Minimal JSON string escaper (bash 3.2, no jq).
ui_esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Build the JSON fragment common to every screen.
ui_common_json() {
    printf '"company":"%s","accent":"%s"' \
        "$(ui_esc "${COMPANY_NAME}")" "$(ui_esc "${ACCENT_COLOR:-#0E8A5F}")"
}

# ui_render <json-spec>  ->  exit code from renderer (0 btn1, 1 btn2, 2 closed)
# Renderer stdout (JSON) is captured in UI_LAST_JSON.
#
# ERREXIT CONTRACT: jc-enroll.sh deliberately runs WITHOUT `set -e` - it is
# a state machine whose steps report status through non-zero return codes.
# These functions must never switch errexit on. An earlier version wrapped
# each render in `set +e ... set -e`, which left errexit ENABLED for the
# rest of the run; after the first screen, "Remind Me Later" and every
# binding failure aborted the script instead of reaching DEFERRED and
# BIND_FAILED, so neither the defer state nor the failure screen happened.
ui_render() {
    local spec="$1" rc
    UI_LAST_JSON=""
    UI_LAST_JSON="$(ui_as_user osascript -l JavaScript "$UI_RENDERER" "$spec" 2>/dev/null)"
    rc=$?
    return $rc
}

# ---------------------------------------------------------------------
# Progress overlay - runs in the background; killed when the step ends.
# ---------------------------------------------------------------------
ui_progress_start() {
    local msg="$1" spec
    ui_progress_stop

    # `launchctl asuser` FORKS, so $! is a wrapper PID, not the process that
    # owns the window - killing it left the progress window on screen for the
    # rest of the session. Have the console-user shell record its own PID and
    # then `exec` the renderer in place, so the file holds the PID that
    # actually draws the window. (The stubs in tests/ use exec, which is why
    # the old code passed there and failed on a real Mac.)
    UI_PROGRESS_PIDFILE="$(mktemp /private/tmp/jc_prog.XXXXXX)"
    chmod 644 "$UI_PROGRESS_PIDFILE" 2>/dev/null || true
    chown "$CONSOLE_USER" "$UI_PROGRESS_PIDFILE" 2>/dev/null || true

    spec="{$(ui_common_json),\"screen\":\"progress\",\"title\":\"$(ui_esc "$msg")\",\"message\":\"This usually takes less than a minute. Please keep this window open.\"}"
    # osascript stays unqualified so tests can stub it.
    ui_as_user /bin/bash -c 'printf "%s" "$$" > "$1"; exec osascript -l JavaScript "$2" "$3"' \
        jc-progress "$UI_PROGRESS_PIDFILE" "$UI_RENDERER" "$spec" >/dev/null 2>&1 &
    UI_PROGRESS_PID=$!
}

ui_progress_update() {
    # Each screen is its own modal window, so an update is a restart.
    ui_progress_start "$1"
}

ui_progress_stop() {
    local pid waited=0
    if [[ -n "${UI_PROGRESS_PIDFILE:-}" ]]; then
        # A very fast step can finish before the helper has written its PID.
        while (( waited < 20 )); do
            [[ -s "$UI_PROGRESS_PIDFILE" ]] && break
            kill -0 "${UI_PROGRESS_PID:-0}" 2>/dev/null || break
            sleep 0.1
            waited=$((waited + 1))
        done
        pid="$(head -n1 "$UI_PROGRESS_PIDFILE" 2>/dev/null)"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi
        rm -f "$UI_PROGRESS_PIDFILE" 2>/dev/null || true
        UI_PROGRESS_PIDFILE=""
    fi
    [[ -z "${UI_PROGRESS_PID:-}" ]] && return 0
    kill "$UI_PROGRESS_PID" >/dev/null 2>&1 || true
    wait "$UI_PROGRESS_PID" 2>/dev/null || true
    UI_PROGRESS_PID=""
    return 0
}

# ---------------------------------------------------------------------
# WELCOME -> 0 = link now, 1 = remind me later, 2 = closed/dismissed
# ---------------------------------------------------------------------
ui_welcome() {
    local rc msg note btn2="" spec
    msg="${COMPANY_NAME} uses JumpCloud to securely manage identity and access to company resources. To provide a seamless sign-in experience, link your JumpCloud account with this Mac."

    if jc_defer_allowed; then
        note="Not a good time? You'll be reminded again in about $(( DEFER_MINUTES / 60 )) hours."
        btn2=",\"button2\":\"Remind Me Later\""
    else
        note="Linking is required and can no longer be postponed."
    fi

    spec="{$(ui_common_json),\"icon\":\"link\",\"title\":\"Welcome to JumpCloud\""
    spec="${spec},\"message\":\"$(ui_esc "$msg")\""
    spec="${spec},\"footer\":\"Once linked, your JumpCloud password becomes your Mac login password.\""
    spec="${spec},\"button1\":\"Link My JumpCloud Account\"${btn2}"
    spec="${spec},\"note\":\"$(ui_esc "$note")\""
    spec="${spec},\"support\":\"Managed by $(ui_esc "${COMPANY_NAME}"). Questions? Contact $(ui_esc "${SUPPORT_CONTACT}").\"}"

    ui_render "$spec"; rc=$?
    case $rc in
        0) return 0 ;;
        1) jc_defer_allowed && return 1 || return 2 ;;
        *) return 2 ;;
    esac
}

ui_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# ---------------------------------------------------------------------
# Result screens
# ---------------------------------------------------------------------
# ui_message_screen <icon> <title> <message> <btn1> [btn2] [extra-json]
ui_message_screen() {
    local icon="$1" title="$2" msg="$3" b1="$4" b2="${5:-}" extra="${6:-}"
    local spec rc
    spec="{$(ui_common_json),\"icon\":\"$(ui_esc "$icon")\",\"title\":\"$(ui_esc "$title")\""
    spec="${spec},\"message\":\"$(ui_esc "$msg")\",\"button1\":\"$(ui_esc "$b1")\""
    [[ -n "$b2" ]] && spec="${spec},\"button2\":\"$(ui_esc "$b2")\""
    [[ -n "$extra" ]] && spec="${spec},${extra}"
    spec="${spec},\"support\":\"Managed by $(ui_esc "${COMPANY_NAME}"). Questions? Contact $(ui_esc "${SUPPORT_CONTACT}").\"}"
    ui_render "$spec"; rc=$?
    return $rc
}

# 0 = try again, 1 = remind me later / closed
ui_auth_failed() {
    local b2="" rc
    jc_defer_allowed && b2="Remind Me Later"
    ui_message_screen "warn" "We couldn't verify your account" \
        "The email address or password you entered couldn't be verified. Check your credentials and try again." \
        "Try Again" "$b2"
    rc=$?
    [[ $rc -eq 0 ]] && return 0 || return 1
}

# 0 = try again, 1 = close
ui_bind_failed() {
    local ref="${1:-}" rc note=""
    [[ -n "$ref" ]] && note=",\"reference\":\"Support reference: $(ui_esc "$ref")\""
    ui_message_screen "error" "We couldn't link your account" \
        "Your account was verified, but we couldn't finish linking it to this Mac. Please try again, or contact ${SUPPORT_CONTACT} if the problem continues." \
        "Try Again" "Close" "$note"
    rc=$?
    [[ $rc -eq 0 ]] && return 0 || return 1
}

ui_unavailable() {
    ui_message_screen "warn" "Enrollment is unavailable" \
        "We couldn't reach the verification service. Check your network connection and try again later." \
        "Close"
    return 0
}

ui_blocked() {
    local ref="${1:-}" note=""
    [[ -n "$ref" ]] && note=",\"reference\":\"Support reference: $(ui_esc "$ref")\""
    ui_message_screen "info" "This Mac isn't ready to be linked" \
        "This Mac is missing a required management component, so account linking can't continue. Please contact ${SUPPORT_CONTACT} for help getting set up." \
        "Close" "" "$note"
    return 0
}

# 0 = sign out now, 1 = sign out later
ui_success() {
    local rc spec
    spec="{$(ui_common_json),\"icon\":\"check\",\"title\":\"Your JumpCloud account is linked\""
    spec="${spec},\"message\":\"Your JumpCloud account has been successfully linked to this Mac.\""
    spec="${spec},\"steps\":["
    spec="${spec}\"Save your work and close your apps.\","
    spec="${spec}\"Log out of macOS.\","
    spec="${spec}\"At the login window, sign in with your JumpCloud password.\","
    spec="${spec}\"If macOS asks for your old password to update your keychain, enter your previous Mac password once.\"]"
    spec="${spec},\"footer\":\"After that first sign-in, use your JumpCloud password to log in to this Mac from now on.\""
    spec="${spec},\"button1\":\"Sign Out Now\",\"button2\":\"I'll Sign Out Later\""
    spec="${spec},\"support\":\"Managed by $(ui_esc "${COMPANY_NAME}"). Questions? Contact $(ui_esc "${SUPPORT_CONTACT}").\"}"
    ui_render "$spec"; rc=$?
    [[ $rc -eq 0 ]] && return 0 || return 1
}

# Standard, user-initiated macOS logout. Never called without an explicit
# click on "Sign Out Now".
ui_sign_out_now() {
    if [[ "${JC_DRY_RUN}" == "1" ]]; then
        jc_warn "Dry run: sign-out suppressed."
        return 0
    fi
    jc_info "User selected Sign Out Now - requesting logout."
    ui_as_user osascript -e 'tell application "System Events" to log out' >/dev/null 2>&1 || \
        jc_warn "Logout request failed; the user can log out manually."
}
