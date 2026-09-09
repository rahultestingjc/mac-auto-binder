#!/bin/bash
# =====================================================================
# logging.sh - diagnostic logging (never credentials, never secrets)
#
# Log lines go to stderr AND the log file. stderr is used deliberately so
# that command substitutions capturing stdout (e.g. helpers that return a
# status token) are never polluted by log output.
# =====================================================================

JC_LOG_FILE="${JC_LOG_FILE:-/var/log/jc_enroll.log}"

jc_log_init() {
    mkdir -p "$(dirname "$JC_LOG_FILE")" 2>/dev/null || true
    touch "$JC_LOG_FILE" 2>/dev/null || true
    # Root-only: the log carries emails and device diagnostics.
    chmod 600 "$JC_LOG_FILE" 2>/dev/null || true
}

jc_log() {
    # jc_log <LEVEL> <message>
    local level="$1"; shift
    printf '[JC-ENROLL %s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
    printf '[JC-ENROLL %s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        >>"$JC_LOG_FILE" 2>/dev/null || true
}

jc_info()  { jc_log INFO  "$@"; }
jc_warn()  { jc_log WARN  "$@"; }
jc_error() { jc_log ERROR "$@"; }

jc_mask_email() {
    # ra***@example.com - keeps logs useful while minimizing PII.
    local email="${1:-}" local_part domain
    [[ -z "$email" ]] && { printf '<empty>'; return; }
    case "$email" in
        *@*) ;;
        *) printf '<invalid>'; return ;;
    esac
    local_part="${email%%@*}"
    domain="${email#*@}"
    if (( ${#local_part} <= 2 )); then
        printf '%s*@%s' "${local_part:0:1}" "$domain"
    else
        local stars
        stars="$(printf '%*s' "$(( ${#local_part} - 2 ))" '' | tr ' ' '*')"
        printf '%s%s@%s' "${local_part:0:2}" "$stars" "$domain"
    fi
}
