#!/bin/bash
# =====================================================================
# e2e-local.sh - the whole flow, locally, against a REAL LDAPS bind.
#
# Runs the real orchestrator, the real user/ui-host.sh and the real
# renderer plumbing, and performs a GENUINE LDAPS bind against
# JumpCloud with a test account. Two things are stubbed, and only two:
#
#   * the renderer, so nothing has to be clicked (the screens themselves
#     are covered by tests/test-units.sh and tests/preview-flow.sh);
#   * the JumpCloud REST API, so no API key is needed here and nothing
#     is ever changed in your tenant.
#
# It needs no sudo. This is the test that catches wiring the suites
# cannot: it is how the truncated DN template was found, where every
# verification returned CONFIG_ERROR without ever attempting a bind.
#
#   JC_TEST_EMAIL=user@example.com JC_TEST_PASSWORD='...' \
#       ./tests/e2e-local.sh --org <JumpCloud Org ID>
#
# The password is taken from the environment so it never reaches a
# command line the LDAP tools can leak; if it is unset you are prompted.
# =====================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --org) ORG="$2"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1"; exit 1 ;;
    esac
done

if [[ "$(id -u)" -eq 0 ]]; then
    printf 'Run this WITHOUT sudo.\n'; exit 1
fi
[[ -z "$ORG" ]] && { printf 'ERROR: --org <JumpCloud Org ID> is required.\n'; exit 1; }
EMAIL="${JC_TEST_EMAIL:-}"
[[ -z "$EMAIL" ]] && { printf 'ERROR: set JC_TEST_EMAIL.\n'; exit 1; }
PASSWORD="${JC_TEST_PASSWORD:-}"
if [[ -z "$PASSWORD" ]]; then
    printf 'JumpCloud password for %s: ' "$EMAIL"
    stty -echo 2>/dev/null; IFS= read -r PASSWORD; stty echo 2>/dev/null; printf '\n'
fi
[[ -z "$PASSWORD" ]] && { printf 'ERROR: no password given.\n'; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W="$(mktemp -d)"; B="$W/bin"; mkdir -p "$B"
ORCH="$ROOT/.e2e-local.$$.sh"
trap 'rm -rf "$W"; rm -f "$ORCH"' EXIT

cat > "$B/stat" <<'S'
#!/bin/bash
printf '%s' "${STUB_CONSOLE_USER:-root}"
S
cat > "$B/sysadminctl" <<'S'
#!/bin/bash
printf '%s\n' "_jumpcloudserviceaccount: Secure Token is ENABLED" >&2
S
cat > "$B/launchctl" <<'S'
#!/bin/bash
[[ "${1:-}" == "asuser" ]] && shift 2
"$@" &
wait $!
S
cat > "$B/sudo" <<'S'
#!/bin/bash
[[ "${1:-}" == "-u" ]] && shift 2
exec "$@"
S
# Renderer stand-in speaking the --server protocol. Credentials come from
# the environment, so they never appear in this file or in any argv.
cat > "$B/osascript" <<'S'
#!/bin/bash
srv=0; for a in "$@"; do [[ "$a" == "--server" ]] && srv=1; done
(( srv )) || exit 0
while IFS= read -r spec; do
    case "$spec" in *'"quit":true'*) exit 0 ;; esac
    [[ -z "$spec" ]] && continue
    if [[ "$spec" == *'"screen":"progress"'* ]]; then
        u="$(printf '%s' "$spec" | sed -n 's/.*"until":"\([^"]*\)".*/\1/p')"
        i=0; while [[ -n "$u" && ! -f "$u" && $i -lt 900 ]]; do sleep 0.1; i=$((i+1)); done
        printf '{"button":-3,"fields":{}}\n'; continue
    fi
    if [[ "$spec" == *'"key":"password"'* ]]; then
        printf '{"button":0,"fields":{"email":"%s","password":"%s"}}\n' \
            "$STUB_EMAIL" "$STUB_PASSWORD"
    elif [[ "$spec" == *'Welcome to JumpCloud'* ]]; then
        printf '{"button":0,"fields":{}}\n'
    else
        printf '{"button":1,"fields":{}}\n'
    fi
done
S
# JumpCloud REST stand-in: realistic replies, nothing leaves this machine.
cat > "$B/curl" <<'S'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
all="$*"
code=200; body='{}'
case "$all" in
  *systemusers*filter*)
     body="{\"totalCount\":1,\"results\":[{\"_id\":\"0123456789abcdef01234567\",\"username\":\"${STUB_JC_USERNAME}\",\"email\":\"${STUB_EMAIL}\",\"attributes\":[{\"_id\":\"ffffffffffffffffffffffff\",\"name\":\"dept\"}]}]}" ;;
  *associations*) code=204 ;;
esac
printf '%s\n' "$all" >> "${STUB_CURL_LOG:-/dev/null}"
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
S
chmod +x "$B"/*

sed 's/^if ! jc_require_root; then$/if false; then/' "$ROOT/jc-enroll.sh" > "$ORCH"
grep -q 'if false; then' "$ORCH" || { printf 'could not neutralise the root gate\n'; exit 1; }

# The JumpCloud username the API stub reports. The LDAP DN is built from
# it, so it must be the real one for the bind to succeed.
JC_USERNAME_GUESS="${JC_TEST_USERNAME:-${EMAIL%%@*}}"

run_flow() {   # run_flow <password> <log-file> <curl-log>
    PATH="$B:$PATH" \
    JC_DRY_RUN=0 \
    STUB_CONSOLE_USER="$(id -un)" \
    STUB_EMAIL="$EMAIL" STUB_PASSWORD="$1" STUB_JC_USERNAME="$JC_USERNAME_GUESS" \
    STUB_CURL_LOG="$3" \
    JC_STATE_DIR="$W/state.$RANDOM" JC_LOG_FILE="$2" \
    ORG_ID="$ORG" API_KEY="local-e2e" SYSTEM_ID="local-e2e-system" PRIMARY_USER_ID="" \
    START_DELAY_SECONDS=0 CONSOLE_USER_WAIT_MAX=10 \
    COMPANY_NAME="Local E2E" SUPPORT_CONTACT="IT" \
    LDAP_HOST="${LDAP_HOST:-ldap.jumpcloud.com}" LDAP_PORT="${LDAP_PORT:-636}" \
    LDAP_TIMEOUT="${LDAP_TIMEOUT:-20}" \
        bash "$ORCH" 2>&1
}

printf '\n=== e2e-local: real orchestrator + real ui-host + REAL LDAPS ===\n'
printf '  account : %s (DN uid=%s)\n' "$EMAIL" "$JC_USERNAME_GUESS"
printf '  org     : %s\n' "$ORG"
printf '  stubbed : renderer (no clicking), JumpCloud REST (no API key)\n\n'

printf -- '--- correct password ---\n'
L1="$W/log1"; C1="$W/curl1"
OUT="$(run_flow "$PASSWORD" "$L1" "$C1")"
case "$OUT" in *"Verification result: VERIFIED"*) ok 'credentials verify over real LDAPS' ;;
               *) bad "credentials verify over real LDAPS"; printf '%s\n' "$OUT" | tail -6 ;; esac
grep -q 'ldapwhoami exit code: 0' "$L1" && ok 'a real bind actually happened (exit 0)' \
                                        || bad 'a real bind actually happened (exit 0)'
case "$OUT" in *"Status: Good"*) ok 'flow reaches SUCCESS' ;; *) bad 'flow reaches SUCCESS' ;; esac
grep -q 'systemUsername' "$C1" && ok 'systemUsername alignment issued' \
                               || ok 'systemUsername already matched (no write needed)'
case "$OUT" in *"primary user"*|*"Primary user set succeeded"*) ok 'primary user set' ;;
               *) bad 'primary user set' ;; esac

printf -- '\n--- wrong password (one attempt; does not lock the account) ---\n'
L2="$W/log2"
OUT="$(run_flow "definitely-not-the-password-$$" "$L2" "$W/curl2")"
case "$OUT" in *"Verification result: AUTH_FAILED"*) ok 'a wrong password is rejected' ;;
               *) bad 'a wrong password is rejected'; printf '%s\n' "$OUT" | tail -6 ;; esac
grep -q 'ldapwhoami exit code: 49' "$L2" && ok 'rejection came from LDAP (49), not a config error' \
                                         || bad 'rejection came from LDAP (49), not a config error'
case "$OUT" in *"State -> LINKING"*) bad 'binding never runs after auth failure' ;;
               *) ok 'binding never runs after auth failure' ;; esac

printf -- '\n--- password never lands anywhere it should not ---\n'
if grep -rq -- "$PASSWORD" "$W" 2>/dev/null; then
    bad 'password absent from every log and IPC file'
else
    ok 'password absent from every log and IPC file'
fi

printf '\ne2e-local: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
