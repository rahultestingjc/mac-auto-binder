#!/bin/bash
# =====================================================================
# Unit tests for the portable logic layers.
#
# JumpCloud API calls are shimmed by defining a `curl` shell function
# (functions take precedence over binaries), so these run anywhere bash
# runs - including on a non-Mac dev box. macOS-only paths (osascript,
# launchctl, sysadminctl, ldapsearch) are NOT covered here; they must be
# exercised on a real Mac with tests/dry-run.sh.
# =====================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
assert() {
    if [[ "$1" == "true" || "$1" == "0" ]]; then
        PASS=$((PASS + 1)); printf '  PASS  %s\n' "$2"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$2"
    fi
}
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        PASS=$((PASS + 1)); printf '  PASS  %s\n' "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %s (expected [%s] got [%s])\n' "$3" "$2" "$1"
    fi
}

# ---- environment ----------------------------------------------------
export JC_LOG_FILE="$(mktemp)"
export JC_STATE_DIR="$(mktemp -d)"
export API_KEY="test-key" SYSTEM_ID="sys123" ORG_ID="org123"
export API_MAX_TRIES=2 API_RETRY_SLEEP=0
export DEFER_MINUTES=120 DEFER_MAX_COUNT=0 DEFER_DEADLINE_UTC=""
export CONSOLE_USER="jdoe"

. "$ROOT/lib/logging.sh"
. "$ROOT/lib/config.sh"
. "$ROOT/lib/jcapi.sh"
. "$ROOT/lib/preflight.sh"

# ---- curl shim ------------------------------------------------------
# Call accounting goes to a FILE: jc_curl invokes curl inside $( ), which
# runs in a subshell, so variables set by the mock would not survive.
MOCK_LOG="$(mktemp)"
MOCK_HANDLER="mock_default"
mock_reset() { : > "$MOCK_LOG"; }
mock_calls() { wc -l < "$MOCK_LOG" | tr -d ' '; }
mock_last()  { tail -n1 "$MOCK_LOG" 2>/dev/null || printf ''; }
mock_default() { MOCK_CODE=200; MOCK_BODY='{}'; }

curl() {
    local out="" prev="" a
    for a in "$@"; do
        [[ "$prev" == "-o" ]] && out="$a"
        prev="$a"
    done
    printf '%s
' "$(printf '%s' "$*" | tr '
' ' ')" >> "$MOCK_LOG"
    "$MOCK_HANDLER" "$@"
    [[ -n "$out" ]] && printf '%s' "$MOCK_BODY" > "$out"
    printf '%s' "$MOCK_CODE"
    return 0
}

printf '\n--- json_escape ---\n'
assert_eq "$(json_escape 'a"b\c')" 'a\"b\\c' 'escapes quotes and backslashes'
assert_eq "$(json_escape "$(printf 'x\ty')")" 'x\ty' 'escapes tabs'

printf '\n--- jc_mask_email ---\n'
assert_eq "$(jc_mask_email 'rahul@example.com')" 'ra***@example.com' 'masks local part'
assert_eq "$(jc_mask_email 'ab@x.io')" 'a*@x.io' 'two-char local part is masked'
assert_eq "$(jc_mask_email 'a@x.io')" 'a*@x.io' 'single char local part'
assert_eq "$(jc_mask_email '')" '<empty>' 'empty email'
assert_eq "$(jc_mask_email 'notanemail')" '<invalid>' 'invalid email'

printf '\n--- jc_find_user_by_email ---\n'
mock_found() {
    MOCK_CODE=200
    MOCK_BODY='{"results":[{"_id":"0123456789abcdef01234567","username":"JDoe","email":"j@x.io"}]}'
}
MOCK_HANDLER=mock_found
jc_find_user_by_email "j@x.io" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" 'returns 0 when user found'
assert_eq "$JC_USER_ID" "0123456789abcdef01234567" 'parses 24-hex _id'
assert_eq "$JC_USERNAME" "JDoe" 'parses username with original case'
case "$(mock_last)" in
    *"filter=email:eq:j@x.io"*) assert true 'sends email filter' ;;
    *) assert false 'sends email filter' ;;
esac

mock_none() { MOCK_CODE=200; MOCK_BODY='{"results":[]}'; }
MOCK_HANDLER=mock_none
jc_find_user_by_email "ghost@x.io" >/dev/null 2>&1
assert_eq "$?" "1" 'returns 1 when no user matches'

mock_err() { MOCK_CODE=401; MOCK_BODY='unauthorized'; }
MOCK_HANDLER=mock_err
jc_find_user_by_email "j@x.io" >/dev/null 2>&1
assert_eq "$?" "2" 'returns 2 on API error'

printf '\n--- retry on 5xx ---\n'
mock_500() { MOCK_CODE=503; MOCK_BODY='busy'; }
MOCK_HANDLER=mock_500
mock_reset
jc_curl -X GET "http://x" >/dev/null 2>&1
assert_eq "$(mock_calls)" "2" 'retries up to API_MAX_TRIES on 5xx'

printf '\n--- binding pipeline: usernames match ---\n'
route_ok() {
    MOCK_CODE=200; MOCK_BODY='{}'
    case "$*" in
        *"/api/systemusers/"*) MOCK_CODE=200 ;;
        *"associations"*)      MOCK_CODE=204 ;;
        *"/api/systems/"*)     MOCK_CODE=200 ;;
    esac
}
MOCK_HANDLER=route_ok
mock_reset
out="$(jc_run_binding_pipeline "u1" "jdoe" "jdoe" "j@x.io" 2>/dev/null)"
assert_eq "$?" "0" 'succeeds when usernames match'
assert_eq "$(mock_calls)" "2" 'skips username update (associate + primary only)'

printf '\n--- binding pipeline: usernames differ (case-only) ---\n'
mock_reset
out="$(jc_run_binding_pipeline "u1" "JDoe" "jdoe" "j@x.io" 2>/dev/null)"
assert_eq "$?" "0" 'case-only difference needs no update'
assert_eq "$(mock_calls)" "2" 'compare is case-insensitive'

printf '\n--- binding pipeline: real mismatch triggers update ---\n'
mock_reset
out="$(jc_run_binding_pipeline "u1" "someoneelse" "jdoe" "j@x.io" 2>/dev/null)"
assert_eq "$?" "0" 'succeeds after aligning username'
assert_eq "$(mock_calls)" "3" 'update + associate + primary'

printf '\n--- association 409 counts as success ---\n'
route_409() {
    MOCK_CODE=200; MOCK_BODY='{}'
    case "$*" in *"associations"*) MOCK_CODE=409 ;; esac
}
MOCK_HANDLER=route_409
out="$(jc_run_binding_pipeline "u1" "jdoe" "jdoe" "j@x.io" 2>/dev/null)"
assert_eq "$?" "0" 'already-associated (409) is success - retries are idempotent'

printf '\n--- failure categories ---\n'
route_assoc_fail() {
    MOCK_CODE=200; MOCK_BODY='{}'
    case "$*" in *"associations"*) MOCK_CODE=500 ;; esac
}
MOCK_HANDLER=route_assoc_fail
out="$(jc_run_binding_pipeline "u1" "jdoe" "jdoe" "j@x.io" 2>/dev/null)"
rc=$?
assert_eq "$rc" "1" 'association failure returns 1'
assert_eq "$out" "ASSOCIATION_FAILED" 'reports ASSOCIATION_FAILED'

route_primary_fail() {
    MOCK_CODE=200; MOCK_BODY='{}'
    case "$*" in
        *"associations"*) MOCK_CODE=204 ;;
        *"PUT"*) : ;;
    esac
    case "$*" in *"/api/systems/sys123"*) MOCK_CODE=500 ;; esac
}
MOCK_HANDLER=route_primary_fail
out="$(jc_run_binding_pipeline "u1" "jdoe" "jdoe" "j@x.io" 2>/dev/null)"
assert_eq "$out" "PRIMARY_USER_FAILED" 'reports PRIMARY_USER_FAILED'

route_username_fail() {
    MOCK_CODE=200; MOCK_BODY='{}'
    case "$*" in *"/api/systemusers/u1"*) MOCK_CODE=400 ;; esac
}
MOCK_HANDLER=route_username_fail
out="$(jc_run_binding_pipeline "u1" "different" "jdoe" "j@x.io" 2>/dev/null)"
assert_eq "$out" "USERNAME_ALIGNMENT_FAILED" 'reports USERNAME_ALIGNMENT_FAILED'

printf '\n--- defer state ---\n'
MOCK_HANDLER=mock_default
jc_state_init
jc_defer_active; assert_eq "$?" "1" 'no defer active initially'
jc_record_defer
jc_defer_active; assert_eq "$?" "0" 'defer active after recording'
assert_eq "$(cat "$JC_STATE_DIR/defer_count")" "1" 'defer count incremented'
jc_defer_allowed; assert_eq "$?" "0" 'defer allowed when unlimited'

DEFER_MAX_COUNT=1
jc_defer_allowed; assert_eq "$?" "1" 'defer refused once limit reached'
DEFER_MAX_COUNT=0

jc_is_completed; assert_eq "$?" "1" 'not completed initially'
jc_mark_completed
jc_is_completed; assert_eq "$?" "0" 'completed marker detected'

printf '\n--- already-bound precheck ---\n'
PRIMARY_USER_ID=""; jc_already_bound; assert_eq "$?" "1" 'empty primary user -> not bound'
PRIMARY_USER_ID="0"; jc_already_bound; assert_eq "$?" "1" 'zero primary user -> not bound'
PRIMARY_USER_ID="abc"; jc_already_bound; assert_eq "$?" "0" 'set primary user -> already bound'

printf '\n--- json_field: renderer result parsing ---\n'
# json_field lives inside the helper (which runs top-level code on load), so
# the test lifts just that function out and sources it.
JF="$(mktemp)"
sed -n '/^json_field() {/,/^}/p' "$ROOT/user/verify-credentials.sh" > "$JF"
. "$JF"
# What lib/jc-ui.js actually emits for the password  a"b\c d
JRES='{"button":0,"fields":{"email":"a@b.com","password":"a\"b\\c d"}}'
assert_eq "$(json_field "$JRES" email)" 'a@b.com' 'reads the email'
assert_eq "$(json_field "$JRES" password)" 'a"b\c d' 'password keeps an escaped quote and backslash'
assert_eq "$(json_field '{"fields":{"password":"pw"}}' password)" 'pw' 'plain password'
assert_eq "$(json_field '{"fields":{"password":"ab\\"}}' password)" 'ab\' 'password ending in a backslash'
assert_eq "$(json_field '{"fields":{"password":"a{b}:c,d"}}' password)" 'a{b}:c,d' 'JSON punctuation in a password'
assert_eq "$(json_field '{"fields":{"password":""}}' password)" '' 'empty password'
json_field '{"fields":{}}' password >/dev/null
assert_eq "$?" "1" 'absent key reports failure'
rm -f "$JF"

printf '\n--- credential helper: simulation tokens ---\n'
# The helper now renders through lib/jc-ui.js via `osascript`, so the stub
# speaks the renderer's JSON protocol and is placed on PATH (the helper
# calls osascript unqualified precisely so this is possible).
VSTUBS="$(mktemp -d)"; VIPC="$(mktemp -d)"
cat > "$VSTUBS/osascript" <<'STUBEOF'
#!/bin/bash
# A progress screen is a transient window with no result - it must never
# answer with credentials.
for a in "$@"; do
    case "$a" in
        *'"screen":"progress"'*) exit 0 ;;
    esac
done
printf '{"button":0,"fields":{"email":"a@b.io","password":"pw"}}\n'
exit 0
STUBEOF
chmod +x "$VSTUBS/osascript"

# Stand in for root's half of the file IPC: answer email.req with a
# username, exactly as run_credentials_step does.
ipc_responder() {
    local dir="$1" name="$2" i=0
    while (( i < 100 )); do
        if [[ -f "$dir/email.req" ]]; then
            printf '%s' "$name" > "$dir/user.resp"
            return 0
        fi
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

for pair in "success:VERIFIED" "invalid:AUTH_FAILED" "unavailable:UNAVAILABLE" "timeout:TIMEOUT"; do
    sim="${pair%%:*}"; want="${pair##*:}"
    rm -f "$VIPC/email.req" "$VIPC/user.resp"
    ipc_responder "$VIPC" "jdoe" &
    responder_pid=$!
    got="$(PATH="$VSTUBS:$PATH" JC_SIMULATE="$sim" \
        JC_UI_JS="$ROOT/lib/jc-ui.js" JC_IPC_DIR="$VIPC" JC_RESOLVE_TIMEOUT=10 \
        JC_COMPANY="Acme" JC_ACCENT="#0E8A5F" JC_SUPPORT="IT" JC_PREFILL_EMAIL="" \
        JC_LDAP_HOST="h" JC_LDAP_PORT=636 JC_LDAP_DN_TEMPLATE="uid={username},o=x" \
        JC_LDAP_TIMEOUT=5 JC_REQUIRE_SECURE=1 \
        bash "$ROOT/user/verify-credentials.sh" 2>/dev/null)"
    wait "$responder_pid" 2>/dev/null
    assert_eq "$got" "$want" "simulate '$sim' -> $want"
done

printf '\n--- credential helper: IPC carries the email, never the password ---\n'
rm -f "$VIPC/email.req" "$VIPC/user.resp"
ipc_responder "$VIPC" "jdoe" &
responder_pid=$!
PATH="$VSTUBS:$PATH" JC_SIMULATE="success" \
    JC_UI_JS="$ROOT/lib/jc-ui.js" JC_IPC_DIR="$VIPC" JC_RESOLVE_TIMEOUT=10 \
    JC_COMPANY="Acme" JC_ACCENT="#0E8A5F" JC_SUPPORT="IT" JC_PREFILL_EMAIL="" \
    JC_LDAP_HOST="h" JC_LDAP_PORT=636 JC_LDAP_DN_TEMPLATE="uid={username},o=x" \
    JC_LDAP_TIMEOUT=5 JC_REQUIRE_SECURE=1 \
    bash "$ROOT/user/verify-credentials.sh" >/dev/null 2>"$VIPC/helper.err"
wait "$responder_pid" 2>/dev/null
assert_eq "$(cat "$VIPC/email.req" 2>/dev/null)" "a@b.io" 'email.req carries the entered email'
grep -q 'pw' "$VIPC/email.req" 2>/dev/null && \
    assert false 'password never crosses the IPC' || \
    assert true 'password never crosses the IPC'
grep -q 'pw' "$VIPC/helper.err" 2>/dev/null && \
    assert false 'password never reaches the helper log' || \
    assert true 'password never reaches the helper log'

printf '\n--- credential helper: refuses to run without a renderer ---\n'
got="$(PATH="$VSTUBS:$PATH" JC_UI_JS="/nonexistent/jc-ui.js" JC_IPC_DIR="$VIPC" \
    bash "$ROOT/user/verify-credentials.sh" 2>/dev/null)"
assert_eq "$got" "CONFIG_ERROR" 'missing renderer -> CONFIG_ERROR'

rm -rf "$VSTUBS" "$VIPC"

printf '\n--- password never appears in the log ---\n'
grep -qi "hunter2\|password.*=" "$JC_LOG_FILE" && \
    assert false 'log is free of credential material' || \
    assert true 'log is free of credential material'

rm -rf "$JC_STATE_DIR" "$JC_LOG_FILE" "$MOCK_LOG"
printf '\nUnit tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
