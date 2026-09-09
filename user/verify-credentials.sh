#!/bin/bash
# =====================================================================
# verify-credentials.sh - RUNS AS THE CONSOLE USER (never as root).
#
# Owns the whole credential step, matching the Windows client's flow:
# ONE screen collects work email AND JumpCloud password together, then
# the same process verifies them with an encrypted LDAP bind.
#
# Because root must resolve the email to a JumpCloud username (it holds
# the API key) while this process keeps the password, the two exchange
# non-secret messages through a small file IPC - the same split the
# Windows client uses:
#
#   this -> root : $JC_IPC_DIR/email.req   (the entered email)
#   root -> this : $JC_IPC_DIR/user.resp   (username, or NONE)
#
# Prints EXACTLY ONE status token on stdout:
#   VERIFIED | AUTH_FAILED | UNAVAILABLE | TIMEOUT | CONFIG_ERROR
#   BACK     | CANCELLED
#
# SECURITY CONTRACT
#   * The password exists only in this process's memory.
#   * It is never printed, logged, written to disk, sent over the IPC, or
#     passed on a command line (ps-visible). It reaches ldapwhoami /
#     ldapsearch through a FIFO, so it lives only in the kernel buffer.
#   * The caller (root) receives only the status token and the email.
#   * Unencrypted LDAP is refused outright - never a silent fallback.
#
# Inputs (env, all non-secret):
#   JC_UI_JS JC_COMPANY JC_ACCENT JC_SUPPORT JC_PREFILL_EMAIL JC_IPC_DIR
#   JC_LDAP_HOST JC_LDAP_PORT JC_LDAP_DN_TEMPLATE JC_LDAP_TIMEOUT
#   JC_REQUIRE_SECURE  JC_SIMULATE (test builds only)
# =====================================================================

set -uo pipefail

log() { printf '[JC-VERIFY %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

UI_JS="${JC_UI_JS:-}"
IPC_DIR="${JC_IPC_DIR:-}"
RESOLVE_TIMEOUT="${JC_RESOLVE_TIMEOUT:-60}"
PROGRESS_PID=""

cleanup() {
    [[ -n "$PROGRESS_PID" ]] && { kill "$PROGRESS_PID" >/dev/null 2>&1 || true; }
    PASSWORD=""
    unset PASSWORD
    [[ -n "${TMPDIR_PW:-}" && -d "${TMPDIR_PW}" ]] && rm -rf "$TMPDIR_PW"
}
trap cleanup EXIT

esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

# Read one JSON string value out of the renderer's result.
#
# A password legitimately contains " and \, and JSON.stringify escapes both,
# so a plain "([^"]*)" match truncates it at the first escaped quote and the
# LDAP bind then fails with a correct password. This walks the value instead
# and undoes the escapes. \uXXXX is not handled because JSON.stringify only
# emits it for control characters, which a single-line text field cannot
# produce. Pure parameter expansion: bash 3.2, no jq, no interpreter.
json_field() {
    local json="$1" key="$2" rest out="" c i n
    rest="${json#*\"${key}\"}"
    [[ "$rest" == "$json" ]] && return 1      # key not present
    rest="${rest#*\"}"                        # skip the colon + opening quote
    n=${#rest}; i=0
    while (( i < n )); do
        c="${rest:$i:1}"
        [[ "$c" == '"' ]] && break            # closing quote ends the value
        if [[ "$c" == '\' ]]; then
            i=$((i + 1))
            c="${rest:$i:1}"
            case "$c" in
                n) c=$'\n' ;;
                t) c=$'\t' ;;
                r) c=$'\r' ;;
                b) c=$'\b' ;;
                f) c=$'\f' ;;
            esac
        fi
        out="${out}${c}"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

progress_start() {
    local msg="$1" spec
    progress_stop
    spec="{\"company\":\"$(esc "${JC_COMPANY:-}")\",\"accent\":\"$(esc "${JC_ACCENT:-#0E8A5F}")\""
    spec="${spec},\"screen\":\"progress\",\"title\":\"$(esc "$msg")\""
    spec="${spec},\"message\":\"This usually takes less than a minute. Please keep this window open.\"}"
    osascript -l JavaScript "$UI_JS" "$spec" >/dev/null 2>&1 &
    PROGRESS_PID=$!
}
progress_stop() {
    [[ -z "$PROGRESS_PID" ]] && return 0
    kill "$PROGRESS_PID" >/dev/null 2>&1 || true
    wait "$PROGRESS_PID" 2>/dev/null || true
    PROGRESS_PID=""
    return 0
}

# ---------------------------------------------------------------------
# 1) ONE screen: work email + JumpCloud password (Windows parity)
# ---------------------------------------------------------------------
prompt_credentials() {
    local err="" prefill="${JC_PREFILL_EMAIL:-}" spec out rc

    while true; do
        spec="{\"company\":\"$(esc "${JC_COMPANY:-}")\",\"accent\":\"$(esc "${JC_ACCENT:-#0E8A5F}")\""
        spec="${spec},\"title\":\"Verify your JumpCloud account\""
        spec="${spec},\"message\":\"Enter your JumpCloud credentials to securely link your account with this Mac.\""
        spec="${spec},\"fields\":["
        spec="${spec}{\"key\":\"email\",\"label\":\"Work email\",\"placeholder\":\"name@company.com\",\"value\":\"$(esc "$prefill")\"},"
        spec="${spec}{\"key\":\"password\",\"label\":\"JumpCloud password\",\"secure\":true}]"
        [[ -n "$err" ]] && spec="${spec},\"error\":\"$(esc "$err")\""
        spec="${spec},\"back\":true,\"button1\":\"Verify & Link Account\""
        spec="${spec},\"support\":\"Managed by $(esc "${JC_COMPANY:-}"). Questions? Contact $(esc "${JC_SUPPORT:-your IT administrator}").\"}"

        out="$(osascript -l JavaScript "$UI_JS" "$spec" 2>/dev/null)"
        rc=$?

        [[ $rc -eq 1 ]] && { printf 'BACK'; exit 0; }
        [[ $rc -ne 0 ]] && { printf 'CANCELLED'; exit 0; }

        EMAIL="$(json_field "$out" "email" | tr -d '\r\n' | sed -e 's/^ *//' -e 's/ *$//')"
        PASSWORD="$(json_field "$out" "password")"
        out=""
        unset out

        prefill="$EMAIL"   # never clear the email on a retry

        if [[ -z "$EMAIL" ]]; then
            err="Enter your work email address."
            continue
        fi
        if ! valid_email "$EMAIL"; then
            err="That doesn't look like a valid email address. Check it and try again."
            continue
        fi
        if [[ -z "${PASSWORD:-}" ]]; then
            err="Enter your JumpCloud password."
            continue
        fi
        break
    done

    EMAIL="$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]')"
}

# ---------------------------------------------------------------------
# 2) Ask root to resolve the email -> JumpCloud username (no secrets)
# ---------------------------------------------------------------------
resolve_username() {
    local waited=0
    JC_USERNAME=""
    if [[ -z "$IPC_DIR" ]]; then
        log "No IPC dir supplied; cannot resolve username."
        return 1
    fi
    rm -f "${IPC_DIR}/user.resp" 2>/dev/null || true
    printf '%s' "$EMAIL" > "${IPC_DIR}/email.req" 2>/dev/null || {
        log "Could not write email request."; return 1; }

    while (( waited < RESOLVE_TIMEOUT )); do
        if [[ -f "${IPC_DIR}/user.resp" ]]; then
            JC_USERNAME="$(head -n1 "${IPC_DIR}/user.resp" 2>/dev/null)"
            [[ "$JC_USERNAME" == "NONE" ]] && JC_USERNAME=""
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "Timed out waiting for username resolution."
    return 1
}

# ---------------------------------------------------------------------
# 3) Verify over encrypted LDAP
# ---------------------------------------------------------------------
verify_ldap() {
    local dn uri rc tool fifo writer_pid

    # Unknown email -> same token as a bad password. We deliberately
    # prompted for the password first, so the two are indistinguishable
    # (no account enumeration).
    if [[ -z "${JC_USERNAME:-}" ]]; then
        log "No resolved username; reporting generic auth failure."
        printf 'AUTH_FAILED'; exit 0
    fi

    if [[ -z "${JC_LDAP_DN_TEMPLATE:-}" || "$JC_LDAP_DN_TEMPLATE" != *"{username}"* ]]; then
        log "DN template is empty or missing the {username} placeholder."
        printf 'CONFIG_ERROR'; exit 0
    fi

    local esc_user
    esc_user="$(printf '%s' "$JC_USERNAME" | sed -e 's/[\\,+"<>;=]/\\&/g')"
    dn="${JC_LDAP_DN_TEMPLATE//\{username\}/$esc_user}"

    # Encryption is mandatory. 636 = LDAPS, 389 = StartTLS (-ZZ requires
    # a successful upgrade). Anything else is refused.
    local starttls=()
    case "${JC_LDAP_PORT}" in
        636) uri="ldaps://${JC_LDAP_HOST}:636" ;;
        389) uri="ldap://${JC_LDAP_HOST}:389"; starttls=(-ZZ) ;;
        *)
            if [[ "${JC_REQUIRE_SECURE:-1}" == "1" ]]; then
                log "Refusing LDAP on unsupported port ${JC_LDAP_PORT} (need 636 or 389+StartTLS)."
                printf 'CONFIG_ERROR'; exit 0
            fi
            uri="ldaps://${JC_LDAP_HOST}:${JC_LDAP_PORT}"
            ;;
    esac

    if command -v ldapwhoami >/dev/null 2>&1; then
        tool="ldapwhoami"
    elif command -v ldapsearch >/dev/null 2>&1; then
        tool="ldapsearch"
    else
        log "No LDAP client tools available."
        printf 'CONFIG_ERROR'; exit 0
    fi

    # Password reaches the client through a FIFO: never on the command
    # line (ps-visible) and never written to disk.
    TMPDIR_PW="$(mktemp -d /private/tmp/jc_pw.XXXXXX)"
    chmod 700 "$TMPDIR_PW"
    fifo="${TMPDIR_PW}/pw"
    if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
        log "Could not create FIFO for credential handoff."
        printf 'CONFIG_ERROR'; exit 0
    fi

    printf '%s' "$PASSWORD" > "$fifo" &
    writer_pid=$!

    # LDAPTLS_REQCERT=demand: a bad/untrusted certificate fails closed.
    if [[ "$tool" == "ldapwhoami" ]]; then
        LDAPTLS_REQCERT=demand ldapwhoami -H "$uri" ${starttls[@]+"${starttls[@]}"} -x \
            -D "$dn" -y "$fifo" -o nettimeout="${JC_LDAP_TIMEOUT}" >/dev/null 2>&1
        rc=$?
    else
        LDAPTLS_REQCERT=demand ldapsearch -H "$uri" ${starttls[@]+"${starttls[@]}"} -x \
            -D "$dn" -y "$fifo" -b "$dn" -s base -l "${JC_LDAP_TIMEOUT}" \
            -o nettimeout="${JC_LDAP_TIMEOUT}" '(objectClass=*)' 1.1 >/dev/null 2>&1
        rc=$?
    fi
    wait "$writer_pid" 2>/dev/null || true

    PASSWORD=""
    unset PASSWORD
    rm -rf "$TMPDIR_PW"

    log "LDAP ${tool} exit code: ${rc}"
    case $rc in
        0)  printf 'VERIFIED' ;;
        49) printf 'AUTH_FAILED' ;;          # invalid credentials
        32|34) printf 'CONFIG_ERROR' ;;      # noSuchObject / invalidDNSyntax
        85) printf 'TIMEOUT' ;;
        *)  printf 'UNAVAILABLE' ;;
    esac
}

# ---------------------------------------------------------------------
if [[ -z "$UI_JS" || ! -f "$UI_JS" ]]; then
    log "UI renderer missing (JC_UI_JS='${UI_JS}')."
    printf 'CONFIG_ERROR'; exit 0
fi

prompt_credentials

# Simulated runs still exercise the real screens and the real IPC.
if [[ -n "${JC_SIMULATE:-}" ]]; then
    log "Simulation active: ${JC_SIMULATE}"
    resolve_username || true
    progress_start "Verifying your account..."
    sleep 2
    progress_stop
    case "$JC_SIMULATE" in
        success)     printf 'VERIFIED' ;;
        invalid)     printf 'AUTH_FAILED' ;;
        unavailable) printf 'UNAVAILABLE' ;;
        timeout)     printf 'TIMEOUT' ;;
        *)           printf 'CONFIG_ERROR' ;;
    esac
    exit 0
fi

progress_start "Verifying your account..."
if ! resolve_username; then
    progress_stop
    printf 'UNAVAILABLE'
    exit 0
fi
verify_ldap
progress_stop
exit 0
