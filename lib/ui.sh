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
# ONE WINDOW FOR THE WHOLE FLOW. Root cannot draw in the user's GUI
# session, so a single console-user process (user/ui-host.sh) owns one
# long-lived renderer and every screen reuses its window: the card
# changes in place instead of a window closing and another opening for
# each step. This layer just sends it commands and reads back answers:
#
#   SCREEN <spec>    -> BUTTON <0|1|-1>
#   PROGRESS <spec>  -> (no reply yet; the spinner stays up)
#   PROGRESS_WAIT    -> PROGRESS_DONE once the "until" file appears
#   CREDENTIALS <em> -> TOKEN <status>
#   QUIT             -> BYE
#
# This layer NEVER handles the password. The credential screen and the
# LDAP bind both live in user/ui-host.sh, which runs as the console user
# and returns only a status token - the password never reaches root.
#
# ERREXIT CONTRACT: jc-enroll.sh deliberately runs WITHOUT `set -e` - it
# is a state machine whose steps report status through non-zero return
# codes. Nothing here may switch errexit on. An earlier version wrapped
# each render in `set +e ... set -e`, which left errexit ENABLED for the
# rest of the run; after the first screen, "Remind Me Later" and every
# binding failure aborted the script instead of reaching CLOSED and
# BIND_FAILED.
# =====================================================================

UI_RENDERER=""
UI_HOST_PID=""
UI_IPC_DIR=""
UI_PROGRESS_SIGNAL=""
UI_PROGRESS_ACTIVE=0
UI_READY=0

ui_as_user() {
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$@"
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

ui_send() { printf '%s\n' "$*" >&7; }

ui_init() {
    UI_RENDERER="${LIB_DIR}/jc-ui.js"
    if [[ ! -f "$UI_RENDERER" ]]; then
        jc_error "UI renderer missing at ${UI_RENDERER}"
        return 1
    fi
    if [[ ! -f "$UI_HOST_SCRIPT" ]]; then
        jc_error "UI host missing at ${UI_HOST_SCRIPT}"
        return 1
    fi
    # Readable/runnable by the console user (we run them as that user).
    chmod 644 "$UI_RENDERER" 2>/dev/null || true
    chmod 755 "$UI_HOST_SCRIPT" 2>/dev/null || true

    UI_IPC_DIR="${JC_STATE_DIR}/ipc"
    rm -rf "$UI_IPC_DIR" 2>/dev/null || true
    mkdir -p "$UI_IPC_DIR" || { jc_error "Could not create ${UI_IPC_DIR}"; return 1; }
    if ! mkfifo -m 600 "${UI_IPC_DIR}/cmd" "${UI_IPC_DIR}/resp" 2>/dev/null; then
        jc_error "Could not create UI control FIFOs"
        return 1
    fi
    # The host runs as the console user and must own the channel.
    chown "$CONSOLE_USER" "$UI_IPC_DIR" "${UI_IPC_DIR}/cmd" "${UI_IPC_DIR}/resp" 2>/dev/null || true
    chmod 700 "$UI_IPC_DIR" 2>/dev/null || true

    ui_as_user /usr/bin/env \
        JC_UI_JS="$UI_RENDERER" \
        JC_IPC_DIR="$UI_IPC_DIR" \
        JC_COMPANY="${COMPANY_NAME}" \
        JC_ACCENT="${ACCENT_COLOR:-#0E8A5F}" \
        JC_SUPPORT="${SUPPORT_CONTACT}" \
        JC_LDAP_HOST="${LDAP_HOST}" \
        JC_LDAP_PORT="${LDAP_PORT}" \
        JC_LDAP_DN_TEMPLATE="${LDAP_USER_DN_TEMPLATE}" \
        JC_LDAP_TIMEOUT="${LDAP_TIMEOUT}" \
        JC_REQUIRE_SECURE="${LDAP_REQUIRE_SECURE}" \
        JC_SIMULATE="${UI_SIMULATE:-}" \
        "$UI_HOST_SCRIPT" >>"$JC_LOG_FILE" 2>&1 &
    UI_HOST_PID=$!

    # <> so opening never blocks waiting for the other end to appear.
    exec 7<> "${UI_IPC_DIR}/cmd" || { jc_error "Could not open UI command channel"; return 1; }
    exec 8<> "${UI_IPC_DIR}/resp" || { jc_error "Could not open UI reply channel"; return 1; }

    UI_READY=1
    jc_info "UI mode: native AppKit, single window (osascript JXA server, pid ${UI_HOST_PID})"
    return 0
}

ui_cleanup() {
    ui_progress_stop
    if [[ "$UI_READY" == "1" ]]; then
        ui_send "QUIT" 2>/dev/null || true
        local bye
        IFS= read -r -t 10 bye <&8 2>/dev/null || true
        exec 7>&- 2>/dev/null || true
        exec 8>&- 2>/dev/null || true
        UI_READY=0
    fi
    if [[ -n "$UI_HOST_PID" ]]; then
        kill "$UI_HOST_PID" >/dev/null 2>&1 || true
        wait "$UI_HOST_PID" 2>/dev/null || true
        UI_HOST_PID=""
    fi
    [[ -n "$UI_IPC_DIR" ]] && rm -rf "$UI_IPC_DIR" 2>/dev/null || true
    return 0
}

# ui_render <json-spec> -> 0 = button1, 1 = button2, 2 = closed/dismissed
ui_render() {
    local spec="$1" reply btn
    [[ "$UI_READY" == "1" ]] || return 2
    ui_send "SCREEN ${spec}"
    if ! IFS= read -r -t 3900 reply <&8; then
        jc_error "UI host did not answer; treating the screen as dismissed."
        return 2
    fi
    btn="${reply#BUTTON }"
    case "$btn" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# ---------------------------------------------------------------------
# Progress overlay - the SAME window, showing a spinner. It stays up
# until ui_progress_stop drops the signal file the renderer watches, so
# root can work while it spins without a second window appearing.
# ---------------------------------------------------------------------
ui_progress_start() {
    local msg="$1" spec
    ui_progress_stop
    [[ "$UI_READY" == "1" ]] || return 0
    UI_PROGRESS_SIGNAL="${UI_IPC_DIR}/progress.$$.${RANDOM}"
    rm -f "$UI_PROGRESS_SIGNAL" 2>/dev/null || true
    spec="{$(ui_common_json),\"screen\":\"progress\",\"title\":\"$(ui_esc "$msg")\""
    spec="${spec},\"message\":\"This usually takes less than a minute. Please keep this window open.\""
    spec="${spec},\"until\":\"$(ui_esc "$UI_PROGRESS_SIGNAL")\"}"
    ui_send "PROGRESS ${spec}"
    UI_PROGRESS_ACTIVE=1
}

ui_progress_update() {
    # Same window; an update is just the next progress screen.
    ui_progress_start "$1"
}

ui_progress_stop() {
    [[ "${UI_PROGRESS_ACTIVE:-0}" == "1" ]] || return 0
    local done_reply
    touch "$UI_PROGRESS_SIGNAL" 2>/dev/null || true
    ui_send "PROGRESS_WAIT"
    IFS= read -r -t 60 done_reply <&8 2>/dev/null || true
    rm -f "$UI_PROGRESS_SIGNAL" 2>/dev/null || true
    UI_PROGRESS_ACTIVE=0
    return 0
}

# ---------------------------------------------------------------------
# Credential step - the host owns the screen AND the LDAP bind, so the
# password never crosses into this process. Root only answers the
# email -> JumpCloud username lookup, because it holds the API key.
#
# NOT called via $( ): it must set globals (VERIFY_TOKEN, EMAIL,
# JC_USER_ID, JC_USERNAME), which a subshell would discard.
# ---------------------------------------------------------------------
ui_credentials_step() {
    local reply="" served=0
    VERIFY_TOKEN=""
    [[ "$UI_READY" == "1" ]] || { VERIFY_TOKEN="CONFIG_ERROR"; return 0; }
    rm -f "${UI_IPC_DIR}/email.req" "${UI_IPC_DIR}/user.resp" 2>/dev/null || true
    ui_send "CREDENTIALS ${EMAIL}"

    while true; do
        if [[ $served -eq 0 && -f "${UI_IPC_DIR}/email.req" ]]; then
            EMAIL="$(head -n1 "${UI_IPC_DIR}/email.req" 2>/dev/null | tr -d '\r\n')"
            jc_info "Email captured: $(jc_mask_email "$EMAIL")"
            if [[ "${JC_DRY_RUN}" == "1" ]]; then
                JC_USER_ID="dryrun-user-id"
                JC_USERNAME="${CONSOLE_USER}"
            else
                if ! jc_find_user_by_email "$EMAIL"; then
                    # Unknown email: answer NONE. The host still fails with
                    # the same token as a bad password.
                    JC_USER_ID=""
                    JC_USERNAME=""
                fi
            fi
            printf '%s' "${JC_USERNAME:-NONE}" > "${UI_IPC_DIR}/user.resp" 2>/dev/null || true
            served=1
        fi
        if IFS= read -r -t 2 reply <&8; then
            [[ -n "$reply" ]] && break
        fi
        if ! kill -0 "$UI_HOST_PID" 2>/dev/null; then
            jc_error "UI host exited during the credential step."
            VERIFY_TOKEN=""
            return 0
        fi
    done
    VERIFY_TOKEN="${reply#TOKEN }"
    rm -f "${UI_IPC_DIR}/email.req" "${UI_IPC_DIR}/user.resp" 2>/dev/null || true
    return 0
}

ui_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# ---------------------------------------------------------------------
# WELCOME -> 0 = link now, 1 = remind me later, 2 = closed/dismissed
# ---------------------------------------------------------------------
ui_welcome() {
    local rc msg spec
    msg="${COMPANY_NAME} uses JumpCloud to securely manage identity and access to company resources. To provide a seamless sign-in experience, link your JumpCloud account with this Mac."

    # "Remind Me Later" is only a way out of the window - it ends this run
    # and writes NOTHING. There is no snooze and no local state: whether
    # this runs again is decided solely by primary_user_id in the MDM
    # command, plus whatever schedule the command is on.
    spec="{$(ui_common_json),\"icon\":\"link\",\"title\":\"Welcome to JumpCloud\""
    spec="${spec},\"message\":\"$(ui_esc "$msg")\""
    spec="${spec},\"footer\":\"Once linked, your JumpCloud password becomes your Mac login password.\""
    spec="${spec},\"button1\":\"Link My JumpCloud Account\""
    spec="${spec},\"button2\":\"Remind Me Later\""
    spec="${spec},\"support\":\"Managed by $(ui_esc "${COMPANY_NAME}"). Questions? Contact $(ui_esc "${SUPPORT_CONTACT}").\"}"

    ui_render "$spec"; rc=$?
    [[ $rc -eq 0 ]] && return 0 || return 2
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
    local rc
    ui_message_screen "warn" "We couldn't verify your account" \
        "The email address or password you entered couldn't be verified. Check your credentials and try again." \
        "Try Again" "Close"
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
