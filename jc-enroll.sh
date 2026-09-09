#!/bin/bash
# =====================================================================
# jc-enroll.sh - JumpCloud device enrollment for macOS (orchestrator).
#
# Runs as root from a JumpCloud MDM command. Performs preflight checks,
# drives the enrollment UI in the console user's session, verifies the
# user's JumpCloud credentials over encrypted LDAP, then runs the proven
# device-binding pipeline.
#
# State model:
#   WELCOME -> CREDENTIALS -> LINKING -> SUCCESS
#   WELCOME -> DEFERRED
#   CREDENTIALS -> AUTH_FAILED -> CREDENTIALS
#   LINKING  -> BIND_FAILED  -> LINKING (retry)
#   any      -> BLOCKED / UNAVAILABLE / CLOSED
#
# The user's password NEVER enters this process: the credential prompt
# and LDAP bind run in user/verify-credentials.sh as the console user,
# which returns only a status token.
#
# NOTE: `set -e` is deliberately NOT used. This is a state machine built
# on functions that report status via return codes; -e would abort on
# perfectly normal non-zero returns.
# =====================================================================

set -uo pipefail

APP_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Arguments -------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --dry-run) JC_DRY_RUN=1 ;;
        --version) printf 'jc-enroll %s\n' "$APP_VERSION"; exit 0 ;;
        --help)
            cat <<'USAGE'
Usage: jc-enroll.sh [--dry-run]

  --dry-run   Exercise the real UI and preflight machinery, but simulate
              LDAP verification and device binding. Nothing is changed in
              JumpCloud and no sign-out is performed. Combine with the
              SIMULATE_LDAP / SIMULATE_BINDING environment variables.
USAGE
            exit 0 ;;
    esac
done

# ---- Load layers -----------------------------------------------------
# shellcheck source=lib/logging.sh
. "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/preflight.sh
. "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/jcapi.sh
. "${SCRIPT_DIR}/lib/jcapi.sh"
# shellcheck source=lib/ui.sh
. "${SCRIPT_DIR}/lib/ui.sh"

VERIFY_HELPER="${SCRIPT_DIR}/user/verify-credentials.sh"
LIB_DIR="${SCRIPT_DIR}/lib"

FINAL_STATUS="RequiresAction"
FINAL_ISSUE="None"
FINAL_NOTE=""

finish() {
    ui_cleanup
    local summary
    summary="Status: ${FINAL_STATUS} | Issue: ${FINAL_ISSUE} | LocalUser: ${CONSOLE_USER:-} | JCUser: ${JC_USERNAME:-} | SystemID: ${SYSTEM_ID:-}"
    [[ -n "$FINAL_NOTE" ]] && summary="${summary} | Note: ${FINAL_NOTE}"
    jc_info "===== Enrollment finished: ${summary} ====="
    printf '%s\n' "$summary"
    case "$FINAL_STATUS" in
        Good|Deferred|Skipped) exit 0 ;;
        *) exit 1 ;;
    esac
}

# =====================================================================
# Preflight
# =====================================================================
jc_log_init
jc_info "===== jc-enroll.sh ${APP_VERSION} starting ====="
[[ "${JC_DRY_RUN}" == "1" ]] && jc_warn "DRY RUN - LDAP and binding are simulated; no sign-out."

if ! jc_require_root; then
    FINAL_ISSUE="Not running as root"; finish
fi

if jc_already_bound; then
    FINAL_STATUS="Skipped"; FINAL_ISSUE="None"; FINAL_NOTE="Primary user already set"; finish
fi
jc_info "No primary user detected. Continuing workflow..."

jc_state_init
if jc_is_completed; then
    jc_info "Enrollment already completed on this Mac."
    FINAL_STATUS="Skipped"; FINAL_ISSUE="None"; FINAL_NOTE="Already completed"; finish
fi
if jc_defer_active; then
    FINAL_STATUS="Deferred"; FINAL_ISSUE="None"; FINAL_NOTE="Defer window active"; finish
fi

if ! jc_missing_tools; then
    FINAL_ISSUE="Missing required tools"; finish
fi

if [[ "${JC_DRY_RUN}" != "1" ]]; then
    if [[ -z "${API_KEY}" ]]; then FINAL_ISSUE="API_KEY is empty"; jc_error "$FINAL_ISSUE"; finish; fi
    if [[ -z "${SYSTEM_ID}" ]]; then FINAL_ISSUE="SYSTEM_ID is empty"; jc_error "$FINAL_ISSUE"; finish; fi
fi
if [[ -z "${ORG_ID}" ]]; then
    jc_error "ORG_ID is not set - required to build the LDAP user DN."
    FINAL_ISSUE="ORG_ID not set (edit TENANT SETTINGS in the command)"; finish
fi

jc_info "Waiting ${START_DELAY_SECONDS}s before starting workflow..."
sleep "${START_DELAY_SECONDS}"

if ! jc_wait_for_console_user; then
    FINAL_STATUS="Deferred"; FINAL_ISSUE="No interactive user"; finish
fi

# Secure Token gate. Default behavior matches the original script: exit
# quietly without prompting when the service account isn't ready.
if ! jc_check_secure_token; then
    if [[ "${SHOW_BLOCKED_SCREEN:-0}" == "1" ]]; then
        ui_init; ui_blocked "SECURE_TOKEN_MISSING"
    fi
    FINAL_STATUS="Skipped"; FINAL_ISSUE="Secure Token not enabled on ${JC_SVC_ACCOUNT}"; finish
fi

jc_info "System ID: ${SYSTEM_ID} | Base: ${JC_BASE}"
ui_init

# =====================================================================
# State machine
# =====================================================================
STATE="WELCOME"
EMAIL=""
BIND_FAIL_REASON=""

# Runs the credential step in the console user's session. The helper
# owns the single email+password screen (Windows parity) and the LDAP
# bind; this side only answers its email -> username lookup, because
# root holds the API key. The password never crosses this boundary.
#
# NOT called via $( ) - it must set globals (VERIFY_TOKEN, EMAIL,
# JC_USER_ID, JC_USERNAME), which a subshell would discard.
VERIFY_TOKEN=""
run_credentials_step() {
    local sim="" out_file helper_pid served=0 ipc
    [[ "${JC_DRY_RUN}" == "1" ]] && sim="${SIMULATE_LDAP:-}"

    ipc="${JC_STATE_DIR}/ipc"
    rm -rf "$ipc" 2>/dev/null || true
    mkdir -p "$ipc"
    chown "$CONSOLE_USER" "$ipc" 2>/dev/null || true
    chmod 700 "$ipc" 2>/dev/null || true

    out_file="$(mktemp /private/tmp/jc_token.XXXXXX)"
    chmod 600 "$out_file"
    chmod 755 "$VERIFY_HELPER" 2>/dev/null || true

    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" /usr/bin/env \
        JC_UI_JS="${LIB_DIR}/jc-ui.js" \
        JC_COMPANY="${COMPANY_NAME}" \
        JC_ACCENT="${ACCENT_COLOR:-#0E8A5F}" \
        JC_SUPPORT="${SUPPORT_CONTACT}" \
        JC_PREFILL_EMAIL="${EMAIL}" \
        JC_IPC_DIR="${ipc}" \
        JC_LDAP_HOST="${LDAP_HOST}" \
        JC_LDAP_PORT="${LDAP_PORT}" \
        JC_LDAP_DN_TEMPLATE="${LDAP_USER_DN_TEMPLATE}" \
        JC_LDAP_TIMEOUT="${LDAP_TIMEOUT}" \
        JC_REQUIRE_SECURE="${LDAP_REQUIRE_SECURE}" \
        JC_SIMULATE="${sim}" \
        "$VERIFY_HELPER" >"$out_file" 2>>"$JC_LOG_FILE" &
    helper_pid=$!

    # Serve the lookup while the helper still holds the password.
    while kill -0 "$helper_pid" 2>/dev/null; do
        if [[ $served -eq 0 && -f "${ipc}/email.req" ]]; then
            EMAIL="$(head -n1 "${ipc}/email.req" 2>/dev/null | tr -d '\r\n')"
            jc_info "Email captured: $(jc_mask_email "$EMAIL")"
            if [[ "${JC_DRY_RUN}" == "1" ]]; then
                JC_USER_ID="dryrun-user-id"
                JC_USERNAME="${CONSOLE_USER}"
            else
                if ! jc_find_user_by_email "$EMAIL"; then
                    # Unknown email: answer NONE. The helper still fails
                    # with the same token as a bad password.
                    JC_USER_ID=""
                    JC_USERNAME=""
                fi
            fi
            printf '%s' "${JC_USERNAME:-NONE}" > "${ipc}/user.resp" 2>/dev/null || true
            served=1
        fi
        sleep 1
    done
    wait "$helper_pid" 2>/dev/null || true

    VERIFY_TOKEN="$(head -n1 "$out_file" 2>/dev/null)"
    rm -f "$out_file"
    rm -rf "$ipc" 2>/dev/null || true
}

while true; do
    case "$STATE" in

    WELCOME)
        jc_info "State -> WELCOME"
        ui_welcome
        case $? in
            0) STATE="CREDENTIALS" ;;
            1) STATE="DEFERRED" ;;
            *) STATE="CLOSED" ;;
        esac
        ;;

    CREDENTIALS)
        jc_info "State -> CREDENTIALS (single email+password screen)"
        run_credentials_step
        jc_info "Verification result: ${VERIFY_TOKEN:-<empty>}"
        case "$VERIFY_TOKEN" in
            VERIFIED)
                if [[ -z "${JC_USER_ID}" ]]; then
                    FINAL_ISSUE="Verified but no JumpCloud user"; STATE="UNAVAILABLE"
                else
                    STATE="LINKING"
                fi
                ;;
            AUTH_FAILED)  STATE="AUTH_FAILED" ;;
            BACK)         STATE="WELCOME" ;;
            CANCELLED)    STATE="CLOSED" ;;
            TIMEOUT|UNAVAILABLE)
                FINAL_ISSUE="LDAP ${VERIFY_TOKEN}"; STATE="AUTH_FAILED" ;;
            CONFIG_ERROR)
                FINAL_ISSUE="LDAP configuration error"; STATE="UNAVAILABLE" ;;
            *)
                FINAL_ISSUE="Verification helper returned '${VERIFY_TOKEN:-<empty>}'"
                STATE="UNAVAILABLE" ;;
        esac
        ;;

    LINKING)
        jc_info "State -> LINKING"
        ui_progress_start "Linking your account to this Mac..."
        BIND_FAIL_REASON="$(jc_run_binding_pipeline "$JC_USER_ID" "$JC_USERNAME" "$CONSOLE_USER" "$EMAIL")"
        rc=$?
        ui_progress_stop
        if [[ $rc -eq 0 ]]; then
            STATE="SUCCESS"
        else
            jc_error "Binding failed: ${BIND_FAIL_REASON}"
            FINAL_ISSUE="${BIND_FAIL_REASON}"
            STATE="BIND_FAILED"
        fi
        ;;

    AUTH_FAILED)
        jc_info "State -> AUTH_FAILED"
        if ui_auth_failed; then
            STATE="CREDENTIALS"
        else
            jc_defer_allowed && STATE="DEFERRED" || STATE="CLOSED"
        fi
        ;;

    BIND_FAILED)
        jc_info "State -> BIND_FAILED"
        if ui_bind_failed "$BIND_FAIL_REASON"; then
            STATE="LINKING"
        else
            STATE="CLOSED"
        fi
        ;;

    SUCCESS)
        jc_info "State -> SUCCESS"
        [[ "${JC_DRY_RUN}" != "1" ]] && jc_mark_completed
        FINAL_STATUS="Good"; FINAL_ISSUE="None"
        if ui_success; then
            FINAL_NOTE="User signed out immediately"
            ui_cleanup
            ui_sign_out_now
        else
            FINAL_NOTE="User will sign out later"
        fi
        finish
        ;;

    UNAVAILABLE)
        jc_info "State -> UNAVAILABLE"
        ui_unavailable
        [[ "$FINAL_ISSUE" == "None" ]] && FINAL_ISSUE="Service unavailable"
        finish
        ;;

    DEFERRED)
        jc_info "State -> DEFERRED"
        jc_record_defer
        FINAL_STATUS="Deferred"; FINAL_ISSUE="None"; FINAL_NOTE="User chose Remind Me Later"
        finish
        ;;

    CLOSED)
        jc_info "State -> CLOSED"
        [[ "$FINAL_ISSUE" == "None" ]] && FINAL_ISSUE="User closed before completing"
        finish
        ;;

    *)
        jc_error "Unknown state '${STATE}'"
        FINAL_ISSUE="Internal state error"
        finish
        ;;
    esac
done
