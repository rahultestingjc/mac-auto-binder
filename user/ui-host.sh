#!/bin/bash
# =====================================================================
# ui-host.sh - RUNS AS THE CONSOLE USER (never as root).
#
# Owns the single enrollment window for the whole flow. Root cannot draw
# in the user's GUI session and must never see the password, so this
# process sits on the boundary:
#
#   root  --(cmd FIFO, no secrets)-->  ui-host.sh  --(pipe)-->  jc-ui.js
#   root  <--(resp FIFO, no secrets)--             <--(pipe)--
#
# One `osascript -l JavaScript jc-ui.js --server` runs for the whole
# session, so every screen reuses the SAME window - the card changes in
# place instead of a window closing and another opening for each step.
#
# PROTOCOL (one line per message, on $JC_IPC_DIR/cmd and .../resp)
#   root -> host                       host -> root
#   SCREEN <json-spec>                 BUTTON <0|1|-1>
#   PROGRESS <json-spec with "until">  PROGRESS_DONE   (when the screen ends)
#   CREDENTIALS <prefill-email>        TOKEN <status>
#   QUIT                               BYE
#
# PROGRESS is deliberately asynchronous: the reply is withheld until the
# renderer stops, which happens when root touches the "until" file. That
# lets root work while the spinner runs, without a second window.
#
# SECURITY CONTRACT
#   * The password exists only in this process and the renderer it owns.
#   * It is never printed, logged, written to disk, sent over the FIFOs to
#     root, or passed on a command line (ps-visible). It reaches
#     ldapwhoami / ldapsearch through a FIFO, so it lives only in the
#     kernel buffer.
#   * Root receives only a status token and the (non-secret) email.
#   * Unencrypted LDAP is refused outright - never a silent fallback.
#   * An unknown email still shows the password prompt and returns the
#     same token as a wrong password: no account enumeration.
#
# Inputs (env, all non-secret):
#   JC_UI_JS JC_IPC_DIR JC_COMPANY JC_ACCENT JC_SUPPORT
#   JC_LDAP_HOST JC_LDAP_PORT JC_LDAP_DN_TEMPLATE JC_LDAP_TIMEOUT
#   JC_REQUIRE_SECURE  JC_RESOLVE_TIMEOUT  JC_SIMULATE (test builds only)
# =====================================================================

set -uo pipefail

log() { printf '[JC-UIHOST %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

UI_JS="${JC_UI_JS:-}"
IPC_DIR="${JC_IPC_DIR:-}"
RESOLVE_TIMEOUT="${JC_RESOLVE_TIMEOUT:-60}"
REND_PID=""
REND_DIR=""

cleanup() {
    if [[ -n "$REND_PID" ]]; then
        printf '{"quit":true}\n' >&5 2>/dev/null || true
        kill "$REND_PID" >/dev/null 2>&1 || true
    fi
    PASSWORD=""
    unset PASSWORD
    [[ -n "${REND_DIR:-}" && -d "$REND_DIR" ]] && rm -rf "$REND_DIR"
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

# Read a JSON number (the renderer's "button") without a JSON parser.
json_num() {
    local rest
    rest="${1#*\"$2\"}"
    [[ "$rest" == "$1" ]] && return 1
    rest="${rest#*:}"
    rest="${rest%%,*}"
    rest="${rest%%\}*}"
    printf '%s' "${rest//[[:space:]]/}"
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# ---------------------------------------------------------------------
# The renderer: one long-lived process, one window.
# ---------------------------------------------------------------------
start_renderer() {
    REND_DIR="$(mktemp -d /private/tmp/jc_rend.XXXXXX)"
    chmod 700 "$REND_DIR"
    mkfifo -m 600 "$REND_DIR/in" "$REND_DIR/out" || return 1
    # osascript stays unqualified so tests can stub it.
    osascript -l JavaScript "$UI_JS" --server < "$REND_DIR/in" > "$REND_DIR/out" 2>/dev/null &
    REND_PID=$!
    # <> so opening never blocks waiting for the other end.
    exec 5<> "$REND_DIR/in"
    exec 6<> "$REND_DIR/out"
    return 0
}

# show <json-spec> -> renderer result JSON on stdout (may contain the password)
show() {
    local line
    printf '%s\n' "$1" >&5
    if IFS= read -r -t 3600 line <&6; then
        printf '%s' "$line"
    else
        printf '%s' '{"button":-1,"fields":{}}'
    fi
}

# ---------------------------------------------------------------------
# Credential step: one screen collecting work email AND password.
# The password never leaves this process.
# ---------------------------------------------------------------------
build_credentials_spec() {
    local prefill="$1" err="$2" spec
    spec="{\"company\":\"$(esc "${JC_COMPANY:-}")\",\"accent\":\"$(esc "${JC_ACCENT:-#0E8A5F}")\""
    spec="${spec},\"title\":\"Verify your JumpCloud account\""
    spec="${spec},\"message\":\"Enter your JumpCloud credentials to securely link your account with this Mac.\""
    spec="${spec},\"fields\":["
    spec="${spec}{\"key\":\"email\",\"label\":\"Work email\",\"placeholder\":\"name@company.com\",\"value\":\"$(esc "$prefill")\"},"
    spec="${spec}{\"key\":\"password\",\"label\":\"JumpCloud password\",\"secure\":true}]"
    [[ -n "$err" ]] && spec="${spec},\"error\":\"$(esc "$err")\""
    spec="${spec},\"back\":true,\"button1\":\"Verify & Link Account\""
    spec="${spec},\"support\":\"Managed by $(esc "${JC_COMPANY:-}"). Questions? Contact $(esc "${JC_SUPPORT:-your IT administrator}").\"}"
    printf '%s' "$spec"
}

# Prompts until the fields are well formed. Sets EMAIL and PASSWORD.
# Deliberately NOT called through $( ): a subshell would discard both.
# On abort it sets PROMPT_TOKEN and returns 1.
PROMPT_TOKEN=""
prompt_credentials() {
    local prefill="${1:-}" err="" out btn
    PROMPT_TOKEN=""
    while true; do
        out="$(show "$(build_credentials_spec "$prefill" "$err")")"
        btn="$(json_num "$out" "button")"
        if [[ "$btn" == "1" ]]; then out=""; unset out; PROMPT_TOKEN="BACK"; return 1; fi
        if [[ "$btn" != "0" ]]; then out=""; unset out; PROMPT_TOKEN="CANCELLED"; return 1; fi

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
    return 0
}

# Spinner without a second window: the renderer stays up until we drop the
# signal file, so the same window just changes what it shows.
VERIFY_SIGNAL=""
verifying_screen_start() {
    VERIFY_SIGNAL="${REND_DIR}/verifying.done"
    rm -f "$VERIFY_SIGNAL"
    local spec
    spec="{\"company\":\"$(esc "${JC_COMPANY:-}")\",\"accent\":\"$(esc "${JC_ACCENT:-#0E8A5F}")\""
    spec="${spec},\"screen\":\"progress\",\"title\":\"Verifying your account...\""
    spec="${spec},\"message\":\"This usually takes less than a minute. Please keep this window open.\""
    spec="${spec},\"until\":\"$(esc "$VERIFY_SIGNAL")\"}"
    printf '%s\n' "$spec" >&5
}
verifying_screen_stop() {
    local line
    [[ -n "$VERIFY_SIGNAL" ]] || return 0
    touch "$VERIFY_SIGNAL" 2>/dev/null || true
    IFS= read -r -t 30 line <&6 || true
    VERIFY_SIGNAL=""
}

# Prints exactly one status token:
#   VERIFIED | AUTH_FAILED | UNAVAILABLE | TIMEOUT | CONFIG_ERROR
#   BACK     | CANCELLED
do_credentials() {
    local prefill="${1:-}" token
    if ! prompt_credentials "$prefill"; then
        printf '%s' "$PROMPT_TOKEN"
        return 0
    fi

    verifying_screen_start
    if [[ -n "${JC_SIMULATE:-}" ]]; then
        log "Simulation active: ${JC_SIMULATE}"
        resolve_username || true
        sleep 2
        verifying_screen_stop
        PASSWORD=""; unset PASSWORD
        case "$JC_SIMULATE" in
            success)     printf 'VERIFIED' ;;
            invalid)     printf 'AUTH_FAILED' ;;
            unavailable) printf 'UNAVAILABLE' ;;
            timeout)     printf 'TIMEOUT' ;;
            *)           printf 'CONFIG_ERROR' ;;
        esac
        return 0
    fi

    if ! resolve_username; then
        verifying_screen_stop
        PASSWORD=""; unset PASSWORD
        printf 'UNAVAILABLE'
        return 0
    fi
    # verify_ldap runs in a subshell, which is fine: it only needs to READ
    # the password and print a token.
    token="$(verify_ldap)"
    PASSWORD=""; unset PASSWORD
    verifying_screen_stop
    printf '%s' "$token"
    return 0
}

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
# Main loop: serve root over the FIFO pair.
# ---------------------------------------------------------------------
reply() { printf '%s\n' "$*" >&8; }

if [[ -z "$UI_JS" || ! -f "$UI_JS" ]]; then
    log "UI renderer missing (JC_UI_JS='${UI_JS}')."
    exit 1
fi
if [[ -z "$IPC_DIR" || ! -d "$IPC_DIR" ]]; then
    log "IPC directory missing (JC_IPC_DIR='${IPC_DIR}')."
    exit 1
fi
if ! start_renderer; then
    log "Could not start the renderer."
    exit 1
fi

# <> so neither open blocks waiting for root to show up.
exec 7<> "${IPC_DIR}/cmd"
exec 8<> "${IPC_DIR}/resp"

EMAIL=""
JC_USERNAME=""
PROG_PENDING=0
while IFS= read -r -t 3600 LINE <&7; do
    [[ -z "$LINE" ]] && continue
    VERB="${LINE%% *}"
    ARG=""
    [[ "$LINE" == *" "* ]] && ARG="${LINE#* }"

    case "$VERB" in
        SCREEN)
            # A progress screen still pending would leave its reply unread and
            # desync every later answer by one.
            if [[ "$PROG_PENDING" == "1" ]]; then
                IFS= read -r -t 5 _DISCARD <&6 || true
                PROG_PENDING=0
            fi
            RESULT="$(show "$ARG")"
            reply "BUTTON $(json_num "$RESULT" "button")"
            ;;
        PROGRESS)
            # Asynchronous by design: forward it and withhold the reply
            # until the renderer stops, which happens when root touches
            # the "until" file. Root works while the spinner runs.
            printf '%s\n' "$ARG" >&5
            PROG_PENDING=1
            ;;
        PROGRESS_WAIT)
            if [[ "${PROG_PENDING:-0}" == "1" ]]; then
                IFS= read -r -t 3600 _DISCARD <&6 || true
                PROG_PENDING=0
            fi
            reply "PROGRESS_DONE"
            ;;
        CREDENTIALS)
            reply "TOKEN $(do_credentials "$ARG")"
            ;;
        QUIT)
            reply "BYE"
            break
            ;;
        *)
            log "Unknown command: ${VERB}"
            reply "ERR unknown"
            ;;
    esac
done

exit 0
