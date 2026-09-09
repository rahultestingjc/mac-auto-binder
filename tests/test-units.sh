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

printf '\n--- LDAP DN template ---\n'
# This was written as `: "${LDAP_USER_DN_TEMPLATE:=uid={username},...}"`.
# Inside ${VAR:=word} the first unescaped } ENDS the expansion, so the value
# silently became "uid={username" - no closing brace. The host's "must
# contain {username}" check then failed and EVERY verification returned
# CONFIG_ERROR ("we couldn't reach the verification service") without ever
# attempting an LDAP bind.
assert_eq "$LDAP_USER_DN_TEMPLATE" \
    'uid={username},ou=Users,o=org123,dc=jumpcloud,dc=com' \
    'DN template is complete, not truncated at the first brace'
case "$LDAP_USER_DN_TEMPLATE" in
    *"{username}"*) assert true  'DN template keeps the {username} placeholder' ;;
    *)              assert false 'DN template keeps the {username} placeholder' ;;
esac
( export ORG_ID=o2 LDAP_USER_DN_TEMPLATE='cn={username},dc=custom'
  . "$ROOT/lib/config.sh"
  [[ "$LDAP_USER_DN_TEMPLATE" == 'cn={username},dc=custom' ]] ) \
    && assert true 'an explicit DN template still overrides the default' \
    || assert false 'an explicit DN template still overrides the default'

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

# The lookup used to send `fields` three times. JumpCloud takes ONE
# space-separated list, so the server honoured a single one and replied
# without _id/username: every lookup missed, and the user was told their
# correct credentials could not be verified.
case "$(mock_last)" in
    *"fields="*) assert false 'no fields projection is sent (it broke the reply)' ;;
    *)           assert true  'no fields projection is sent (it broke the reply)' ;;
esac

# A full record contains nested objects with their own _id. A greedy match
# across the whole body picks the LAST one; the record's own _id is first.
mock_full() {
    MOCK_CODE=200
    MOCK_BODY='{"totalCount":1,"results":[{"_id":"0123456789abcdef01234567","username":"varun","email":"varun@mylab.com","attributes":[{"_id":"ffffffffffffffffffffffff","name":"dept"}],"organization":"aaaaaaaaaaaaaaaaaaaaaaaa"}]}'
}
MOCK_HANDLER=mock_full
jc_find_user_by_email "varun@mylab.com" >/dev/null 2>&1
assert_eq "$JC_USER_ID"  "0123456789abcdef01234567" 'takes the record _id, not a nested one'
assert_eq "$JC_USERNAME" "varun"                    'username drives the LDAP DN'

# A record with no username cannot build a DN, so it must not look resolved.
mock_nouser() {
    MOCK_CODE=200
    MOCK_BODY='{"totalCount":1,"results":[{"_id":"0123456789abcdef01234567","email":"x@y.io"}]}'
}
MOCK_HANDLER=mock_nouser
jc_find_user_by_email "x@y.io" >/dev/null 2>&1
assert_eq "$?" "1" 'a user with no username is reported as unresolved'

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

printf '\n--- systemUsername decides alignment; username is only the fallback ---\n'
# The field written is ALWAYS systemUsername (never username, which the LDAP
# DN depends on). The field COMPARED is systemUsername when the account has
# one, falling back to username only when it is unset.
MOCK_HANDLER=route_ok

# systemUsername already matches the console user -> nothing to write, even
# though username differs. Comparing username alone would have written.
mock_reset
out="$(jc_run_binding_pipeline "u1" "someoneelse" "jdoe" "j@x.io" "jdoe" 2>/dev/null)"
assert_eq "$?" "0" 'succeeds when systemUsername already matches'
assert_eq "$(mock_calls)" "2" 'no write when systemUsername already matches (associate + primary)'

# systemUsername is stale -> write, even though username matches the console
# user. This is the case the old username-only compare silently skipped.
mock_reset
out="$(jc_run_binding_pipeline "u1" "jdoe" "jdoe" "j@x.io" "someoneelse" 2>/dev/null)"
assert_eq "$?" "0" 'succeeds after refreshing a stale systemUsername'
assert_eq "$(mock_calls)" "3" 'stale systemUsername IS written even when username matches'

# No systemUsername on the account -> fall back to comparing username.
mock_reset
out="$(jc_run_binding_pipeline "u1" "jdoe" "jdoe" "j@x.io" "" 2>/dev/null)"
assert_eq "$(mock_calls)" "2" 'falls back to username when systemUsername is unset (match)'
mock_reset
out="$(jc_run_binding_pipeline "u1" "someoneelse" "jdoe" "j@x.io" "" 2>/dev/null)"
assert_eq "$(mock_calls)" "3" 'falls back to username when systemUsername is unset (differs)'

# Whatever the comparison, the write targets systemUsername with the
# unmodified console username.
mock_reset
out="$(jc_run_binding_pipeline "u1" "jdoe" "JDoe.Local" "j@x.io" "stale" 2>/dev/null)"
# mock_last is the FINAL call (primary user); the write we care about is the
# PUT to /api/systemusers, so look for that one specifically.
SYSUSER_CALL="$(grep 'systemusers/u1' "$MOCK_LOG" | tail -n1)"
case "$SYSUSER_CALL" in
    *'"systemUsername":"JDoe.Local"'*) assert true  'writes systemUsername with the console user, case preserved' ;;
    *)                                 assert false 'writes systemUsername with the console user, case preserved' ;;
esac
case "$SYSUSER_CALL" in
    *'"username"'*) assert false 'never writes the username field (the LDAP DN needs it)' ;;
    *)              assert true  'never writes the username field (the LDAP DN needs it)' ;;
esac

printf '\n--- the lookup reads systemUsername too ---\n'
mock_sysuser() {
    MOCK_CODE=200
    MOCK_BODY='{"results":[{"_id":"0123456789abcdef01234567","username":"varun","systemUsername":"rahuljcw","email":"varun@mylab.com"}]}'
}
MOCK_HANDLER=mock_sysuser
jc_find_user_by_email "varun@mylab.com" >/dev/null 2>&1
assert_eq "$JC_USERNAME"        "varun"    'username still parsed (LDAP DN)'
assert_eq "$JC_SYSTEM_USERNAME" "rahuljcw" 'systemUsername parsed'
mock_nullsys() {
    MOCK_CODE=200
    MOCK_BODY='{"results":[{"_id":"0123456789abcdef01234567","username":"varun","systemUsername":null,"email":"v@x.io"}]}'
}
MOCK_HANDLER=mock_nullsys
jc_find_user_by_email "v@x.io" >/dev/null 2>&1
assert_eq "$JC_SYSTEM_USERNAME" "" 'a null systemUsername reads as unset, not the string null'

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

printf '\n--- no local state can suppress or re-schedule the prompt ---\n'
# Deferring and the completion marker were removed: the ONLY thing that
# decides whether the prompt runs is primary_user_id from the MDM command.
MOCK_HANDLER=mock_default
for fn in jc_state_init jc_defer_active jc_defer_allowed jc_record_defer \
          jc_is_completed jc_mark_completed; do
    if type "$fn" >/dev/null 2>&1; then
        assert false "$fn is gone"
    else
        assert true  "$fn is gone"
    fi
done
if grep -q 'DEFER_MINUTES\|DEFER_MAX_COUNT\|DEFER_DEADLINE' "$ROOT/lib/config.sh"; then
    assert false 'no defer knobs remain in config'
else
    assert true  'no defer knobs remain in config'
fi

printf '\n--- already-bound precheck ---\n'
PRIMARY_USER_ID=""; jc_already_bound; assert_eq "$?" "1" 'empty primary user -> not bound'
PRIMARY_USER_ID="0"; jc_already_bound; assert_eq "$?" "1" 'zero primary user -> not bound'
PRIMARY_USER_ID="abc"; jc_already_bound; assert_eq "$?" "0" 'set primary user -> already bound'

printf '\n--- json_field: renderer result parsing ---\n'
# json_field lives inside the UI host (which runs top-level code on load), so
# the test lifts just that function out and sources it.
JF="$(mktemp)"
sed -n '/^json_field() {/,/^}/p' "$ROOT/user/ui-host.sh" > "$JF"
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

printf '\n--- renderer exit-code contract ---\n'
# lib/ui.sh and user/verify-credentials.sh tell the buttons apart by EXIT
# STATUS, not by parsing stdout. The renderer once exited 0 for BOTH
# buttons, so every secondary button ("Remind Me Later", "I'll Sign Out
# Later", "Close", "Back") was read as the primary one. Lock the mapping
# against the real lib/jc-ui.js, with the modal and the order-front calls
# patched out so nothing appears on screen.
if [[ "$(uname)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    RT="$(mktemp -d)"
    rt_run() {   # rt_run <modal-return-code> -> exit status of the renderer
        awk -v c="$1" '
            index($0,"runModalForWindow") && index($0,"var code") { print "  var code = " c ";"; next }
            index($0,"win.makeKeyAndOrderFront")                  { next }
            index($0,"activateIgnoringOtherApps")                 { next }
            { print }' "$ROOT/lib/jc-ui.js" > "$RT/ui.js"
        osascript -l JavaScript "$RT/ui.js" \
            '{"company":"T","title":"T","button1":"One","button2":"Two"}' >/dev/null 2>&1
        printf '%s' "$?"
    }
    assert_eq "$(rt_run 0)"     "0" 'button1 exits 0'
    assert_eq "$(rt_run 1)"     "1" 'button2 exits 1 (Remind Me Later / Sign Out Later / Back)'
    assert_eq "$(rt_run -1000)" "2" 'dismissed window exits 2'
    rm -rf "$RT"
else
    printf '  SKIP  renderer exit-code contract (needs macOS + osascript)\n'
fi

printf '\n--- renderer server mode (real lib/jc-ui.js, one window) ---\n'
# The whole single-window design rests on one renderer process serving many
# screens. Progress screens end on their own when the "until" file appears,
# so this drives the REAL renderer end to end without needing a click.
if [[ "$(uname)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    SD="$(mktemp -d)"
    mkfifo "$SD/in" "$SD/out"
    osascript -l JavaScript "$ROOT/lib/jc-ui.js" --server < "$SD/in" > "$SD/out" 2>"$SD/err" &
    SRV_PID=$!
    exec 7<> "$SD/in"
    exec 8<> "$SD/out"
    srv_recv() { local l; if IFS= read -r -t 25 l <&8; then printf '%s' "$l"; else printf '<TIMEOUT>'; fi; }

    printf '{"company":"T","screen":"progress","title":"Verifying...","until":"%s"}\n' "$SD/s1" >&7
    sleep 0.6
    kill -0 "$SRV_PID" 2>/dev/null && assert true 'renderer stays up during a progress screen' \
                                   || assert false 'renderer stays up during a progress screen'
    touch "$SD/s1"
    assert_eq "$(srv_recv)" '{"button":-3,"fields":{}}' 'progress ends when its signal file appears'

    # A second, taller screen must reuse the SAME process (one window).
    printf '{"company":"T","screen":"progress","title":"Linking your account to this Mac...","message":"A longer message so the card has to grow.","support":"Managed by T.","until":"%s"}\n' "$SD/s2" >&7
    sleep 0.6
    kill -0 "$SRV_PID" 2>/dev/null && assert true 'the same process serves the next screen' \
                                   || assert false 'the same process serves the next screen'
    touch "$SD/s2"
    assert_eq "$(srv_recv)" '{"button":-3,"fields":{}}' 'second screen answers on the same connection'

    printf '{"quit":true}\n' >&7
    sleep 1
    if kill -0 "$SRV_PID" 2>/dev/null; then
        kill -9 "$SRV_PID" 2>/dev/null
        assert false 'quit ends the renderer'
    else
        assert true 'quit ends the renderer'
    fi
    exec 7>&- 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    rm -rf "$SD"
else
    printf '  SKIP  renderer server mode (needs macOS + osascript)\n'
fi

printf '\n--- UI host: one window drives the whole flow ---\n'
# The host is the console-user half of the UI: it owns one long-lived
# renderer and the credential step, so the password never reaches root.
# These drive it over its real FIFO protocol with a stubbed renderer.
if [[ "$(uname)" == "Darwin" ]] || command -v mkfifo >/dev/null 2>&1; then
HDIR="$(mktemp -d)"
mkdir -p "$HDIR/bin"
cat > "$HDIR/bin/osascript" <<'STUBEOF'
#!/bin/bash
# Renderer stand-in speaking the --server line protocol.
srv=0
for a in "$@"; do [[ "$a" == "--server" ]] && srv=1; done
(( srv )) || exit 0
while IFS= read -r spec; do
    case "$spec" in *'"quit":true'*) exit 0 ;; esac
    [[ -z "$spec" ]] && continue
    printf '%s\n' "$spec" >> "${STUB_SPEC_LOG:-/dev/null}"
    if [[ "$spec" == *'"screen":"progress"'* ]]; then
        u="$(printf '%s' "$spec" | sed -n 's/.*"until":"\([^"]*\)".*/\1/p')"
        i=0
        while [[ -n "$u" && ! -f "$u" && $i -lt 900 ]]; do sleep 0.1; i=$((i + 1)); done
        printf '{"button":-3,"fields":{}}\n'
        continue
    fi
    q="${STUB_OSA_QUEUE:-/dev/null}"
    line="$(head -n1 "$q" 2>/dev/null)"
    if [[ -n "$line" ]]; then
        tail -n +2 "$q" > "${q}.tmp" 2>/dev/null && mv "${q}.tmp" "$q"
        printf '%s\n' "$line"
    else
        printf '{"button":-1,"fields":{}}\n'
    fi
done
STUBEOF
chmod +x "$HDIR/bin/osascript"

HOST_PID=""
host_start() {   # host_start <simulate> [queue-lines...]
    local sim="$1"; shift
    HIPC="$HDIR/ipc.$RANDOM"; mkdir -p "$HIPC"
    HQUEUE="$HDIR/queue.$RANDOM"; : > "$HQUEUE"
    HSPECS="$HDIR/specs.$RANDOM"; : > "$HSPECS"
    for l in "$@"; do printf '%s\n' "$l" >> "$HQUEUE"; done
    mkfifo "$HIPC/cmd" "$HIPC/resp"
    PATH="$HDIR/bin:$PATH" \
    STUB_OSA_QUEUE="$HQUEUE" STUB_SPEC_LOG="$HSPECS" \
    JC_UI_JS="$ROOT/lib/jc-ui.js" JC_IPC_DIR="$HIPC" \
    JC_COMPANY="Acme" JC_ACCENT="#0E8A5F" JC_SUPPORT="IT" \
    JC_LDAP_HOST="h" JC_LDAP_PORT=636 JC_LDAP_DN_TEMPLATE="uid={username},o=x" \
    JC_LDAP_TIMEOUT=5 JC_REQUIRE_SECURE=1 JC_RESOLVE_TIMEOUT=10 \
    JC_SIMULATE="$sim" \
        bash "$ROOT/user/ui-host.sh" > "$HDIR/host.out" 2>"$HDIR/host.err" &
    HOST_PID=$!
    exec 7<> "$HIPC/cmd"
    exec 8<> "$HIPC/resp"
}
host_send() { printf '%s\n' "$*" >&7; }
host_recv() { local l; if IFS= read -r -t 8 l <&8; then printf '%s' "$l"; else printf '<TIMEOUT>'; fi; }
host_stop() {
    host_send "QUIT"; host_recv >/dev/null
    exec 7>&- 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    kill "$HOST_PID" 2>/dev/null; wait "$HOST_PID" 2>/dev/null
}
# Root's half of the email -> username lookup.
serve_lookup() {
    local name="$1" i=0
    while (( i < 100 )); do
        if [[ -f "$HIPC/email.req" ]]; then
            printf '%s' "$name" > "$HIPC/user.resp"; return 0
        fi
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

# --- a plain screen round-trips its button ---
host_start "" '{"button":1,"fields":{}}'
host_send 'SCREEN {"title":"T","button1":"One","button2":"Two"}'
assert_eq "$(host_recv)" "BUTTON 1" 'SCREEN returns the button the user pressed'
host_stop

# --- progress stays up until the caller drops the signal file ---
host_start ""
SIGF="$HIPC/sig"
host_send "PROGRESS {\"screen\":\"progress\",\"title\":\"Linking...\",\"until\":\"$SIGF\"}"
sleep 0.6
kill -0 "$HOST_PID" 2>/dev/null && assert true 'progress keeps the window up while root works' \
                                || assert false 'progress keeps the window up while root works'
touch "$SIGF"
host_send "PROGRESS_WAIT"
assert_eq "$(host_recv)" "PROGRESS_DONE" 'progress ends when the signal file appears'
host_stop

# --- credential step: simulation tokens ---
for pair in "success:VERIFIED" "invalid:AUTH_FAILED" "unavailable:UNAVAILABLE" "timeout:TIMEOUT"; do
    sim="${pair%%:*}"; want="${pair##*:}"
    host_start "$sim" '{"button":0,"fields":{"email":"a@b.io","password":"pw"}}'
    serve_lookup "jdoe" &
    LK=$!
    host_send "CREDENTIALS "
    got="$(host_recv)"
    wait "$LK" 2>/dev/null
    assert_eq "$got" "TOKEN $want" "simulate '$sim' -> $want"
    host_stop
done

# --- Back and a closed window are distinct terminal tokens ---
host_start "success" '{"button":1,"fields":{}}'
host_send "CREDENTIALS "
assert_eq "$(host_recv)" "TOKEN BACK" 'Back on the credential screen reports BACK'
host_stop
host_start "success" '{"button":-1,"fields":{}}'
host_send "CREDENTIALS "
assert_eq "$(host_recv)" "TOKEN CANCELLED" 'a dismissed credential screen reports CANCELLED'
host_stop

# --- a malformed email is re-prompted, never sent to root ---
host_start "success" \
    '{"button":0,"fields":{"email":"not-an-email","password":"pw"}}' \
    '{"button":0,"fields":{"email":"good@acme.io","password":"pw"}}'
serve_lookup "jdoe" &
LK=$!
host_send "CREDENTIALS "
got="$(host_recv)"
wait "$LK" 2>/dev/null
assert_eq "$got" "TOKEN VERIFIED" 'malformed email is re-prompted on the same screen'
assert_eq "$(cat "$HIPC/email.req" 2>/dev/null)" "good@acme.io" 'only the corrected email reaches root'
host_stop

# --- the password never crosses to root, and never hits the log ---
host_start "success" '{"button":0,"fields":{"email":"a@b.io","password":"hunter2"}}'
serve_lookup "jdoe" &
LK=$!
host_send "CREDENTIALS "
host_recv >/dev/null
wait "$LK" 2>/dev/null
host_stop
# -type f matters: $HIPC holds the cmd/resp FIFOs, and a recursive grep
# would block forever trying to read them.
PW_LEAK="$(find "$HIPC" -type f -exec grep -l 'hunter2' {} + 2>/dev/null)"
if [[ -n "$PW_LEAK" ]]; then
    assert false 'password never crosses the IPC to root'
else
    assert true 'password never crosses the IPC to root'
fi
if grep -q 'hunter2' "$HDIR/host.err" "$HDIR/host.out" 2>/dev/null; then
    assert false 'password never reaches the host log'
else
    assert true 'password never reaches the host log'
fi

# --- the host refuses to start without a renderer ---
HIPC="$HDIR/ipc.none"; mkdir -p "$HIPC"
PATH="$HDIR/bin:$PATH" JC_UI_JS="/nonexistent/jc-ui.js" JC_IPC_DIR="$HIPC" \
    bash "$ROOT/user/ui-host.sh" >/dev/null 2>&1
assert_eq "$?" "1" 'missing renderer -> host exits non-zero'

rm -rf "$HDIR"
else
    printf '  SKIP  UI host tests (need mkfifo)\n'
fi

printf '\n--- MDM command: package trust ---\n'
# The command downloads a zip and runs it as root, so the SHA-256 pinned in
# the command text is the whole trust anchor. These check the gates that
# run BEFORE anything is extracted.
if [[ -f "$ROOT/dist/MDM-Command.sh" && -f "$ROOT/dist/JumpCloudEnrollment-macOS.zip" ]]; then
    mdm_run() {   # mdm_run <package-url> [zip-to-place-beside-the-command]
        local url="$1" zipsrc="${2:-}" d out
        d="$(mktemp -d)"
        sed -e 's/^API_KEY=.*/API_KEY="k"/' \
            -e 's/^JC_ORG_VAR=.*/JC_ORG_VAR=""/' \
            -e 's/^SYSTEM_ID=.*/SYSTEM_ID="s1"/' \
            -e 's/^PRIMARY_USER_ID=.*/PRIMARY_USER_ID=""/' \
            -e 's|^ORG_ID=""|ORG_ID="org1"|' \
            -e "s|^PACKAGE_URL=.*|PACKAGE_URL=\"${url}\"|" \
            "$ROOT/dist/MDM-Command.sh" > "$d/cmd.sh"
        [[ -n "$zipsrc" ]] && cp "$zipsrc" "$d/JumpCloudEnrollment-macOS.zip"
        out="$(cd "$d" && bash cmd.sh 2>&1)"
        rm -rf "$d"
        printf '%s' "$out"
    }
    ZIPOK="$ROOT/dist/JumpCloudEnrollment-macOS.zip"
    BADZIP="$(mktemp)"; printf 'not the real package' > "$BADZIP"

    case "$(mdm_run 'http://example.com/pkg.zip')" in
        *"must be https"*) assert true  'plain-http PACKAGE_URL is refused' ;;
        *)                 assert false 'plain-http PACKAGE_URL is refused' ;;
    esac
    case "$(mdm_run 'ftp://example.com/pkg.zip')" in
        *"must be https"*) assert true  'non-https scheme is refused' ;;
        *)                 assert false 'non-https scheme is refused' ;;
    esac
    case "$(mdm_run '')" in
        *"not found"*) assert true  'no URL and no attachment is a clear error' ;;
        *)             assert false 'no URL and no attachment is a clear error' ;;
    esac
    case "$(mdm_run '' "$BADZIP")" in
        *"hash mismatch"*) assert true  'a package that does not match the pin is refused' ;;
        *)                 assert false 'a package that does not match the pin is refused' ;;
    esac
    case "$(mdm_run '' "$BADZIP")" in
        *"Package hash verified"*) assert false 'a mismatched package is never extracted' ;;
        *)                         assert true  'a mismatched package is never extracted' ;;
    esac
    case "$(mdm_run 'https://example.invalid/pkg.zip' "$ZIPOK")" in
        *"Package hash verified"*) assert true  'an attached package is used without downloading' ;;
        *)                         assert false 'an attached package is used without downloading' ;;
    esac
    rm -f "$BADZIP"
else
    printf '  SKIP  MDM command tests (run build/build-package.sh first)\n'
fi

printf '\n--- password never appears in the log ---\n'
grep -qi "hunter2\|password.*=" "$JC_LOG_FILE" && \
    assert false 'log is free of credential material' || \
    assert true 'log is free of credential material'

rm -rf "$JC_STATE_DIR" "$JC_LOG_FILE" "$MOCK_LOG"
printf '\nUnit tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
