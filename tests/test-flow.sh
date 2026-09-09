#!/bin/bash
# =====================================================================
# Integration tests for the orchestrator state machine.
#
# macOS-only commands (stat -f, sysadminctl, launchctl, sudo, osascript)
# are replaced with stubs on PATH so the whole flow can be exercised off
# a Mac. Runs in --dry-run, so LDAP and binding are simulated and no
# JumpCloud call is made.
#
# NOTE: the root check is neutralised in a COPY of the orchestrator -
# production code keeps its `jc_require_root` gate untouched.
# =====================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
assert_contains() {
    if printf '%s' "$1" | grep -q -- "$2"; then
        PASS=$((PASS+1)); printf '  PASS  %s\n' "$3"
    else
        FAIL=$((FAIL+1)); printf '  FAIL  %s\n         output: %s\n' "$3" "$(printf '%s' "$1" | tr '\n' '|' | tail -c 300)"
    fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -q -- "$2"; then
        FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$3"
    else
        PASS=$((PASS+1)); printf '  PASS  %s\n' "$3"
    fi
}

assert_eq() {
    if [[ "$1" == "$2" ]]; then
        PASS=$((PASS+1)); printf '  PASS  %s\n' "$3"
    else
        FAIL=$((FAIL+1)); printf '  FAIL  %s (expected [%s] got [%s])\n' "$3" "$2" "$1"
    fi
}

ME="${USER:-${USERNAME:-$(id -un)}}"
LAST_STATE_DIR=""
WORK="$(mktemp -d)"
STUBS="${WORK}/bin"
mkdir -p "$STUBS"

# ---- stubs -----------------------------------------------------------
cat > "$STUBS/stat" <<'EOF'
#!/bin/bash
# stat -f "%Su" /dev/console  -> pretend this user is at the console.
# The heredoc is QUOTED: STUB_CONSOLE_USER has to be read when the stub
# runs, not when it is written, or the console user is baked in at setup
# time and jc_wait_for_console_user never finds a real account.
printf '%s' "${STUB_CONSOLE_USER:-root}"
EOF

cat > "$STUBS/sysadminctl" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_TOKEN_STATUS:-_jumpcloudserviceaccount: Secure Token is ENABLED}" >&2
EOF

# launchctl asuser <uid> <cmd...>  -> run <cmd...> in a CHILD process.
# The real launchctl asuser forks, so the pid the caller backgrounds is a
# wrapper, not the process that ends up owning the window. Modelling that
# here is what makes the progress-window kill path testable.
cat > "$STUBS/launchctl" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "asuser" ]] && shift 2
"$@" &
wait $!
EOF

# sudo -u <user> <cmd...> -> run <cmd...>
cat > "$STUBS/sudo" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "-u" ]] && shift 2
exec "$@"
EOF

# osascript stand-in for lib/jc-ui.js.
#
# The real renderer now runs in --server mode: ONE process reads a screen
# spec per line and answers a JSON result per line, so the whole flow uses
# a single window. The stub speaks that protocol. A progress screen is not
# a queue entry - it waits for its "until" file, exactly as the renderer's
# timer does - or the queue would desync by one on every progress step.
cat > "$STUBS/osascript" <<'EOF'
#!/bin/bash
srv=0
for a in "$@"; do [[ "$a" == "--server" ]] && srv=1; done

answer_from_queue() {
    local q line code out
    q="${STUB_OSA_QUEUE:-/dev/null}"
    line="$(head -n1 "$q" 2>/dev/null)"
    if [[ -z "$line" ]]; then printf '{"button":-1,"fields":{}}\n'; return; fi
    tail -n +2 "$q" > "${q}.tmp" 2>/dev/null && mv "${q}.tmp" "$q"
    code="${line%%:*}"; out="${line#*:}"
    if [[ -n "$out" ]]; then printf '%s\n' "$out"
    else printf '{"button":%s,"fields":{}}\n' "$code"; fi
}

if (( srv )); then
    while IFS= read -r spec; do
        case "$spec" in
            *'"quit":true'*) exit 0 ;;
        esac
        [[ -z "$spec" ]] && continue
        if [[ "$spec" == *'"screen":"progress"'* ]]; then
            until_path="$(printf '%s' "$spec" | sed -n 's/.*"until":"\([^"]*\)".*/\1/p')"
            i=0
            while [[ -n "$until_path" && ! -f "$until_path" && $i -lt 900 ]]; do
                sleep 0.1; i=$((i + 1))
            done
            printf '{"button":-3,"fields":{}}\n'
            continue
        fi
        answer_from_queue
    done
    exit 0
fi

# one-shot mode (previews and any direct caller)
for a in "$@"; do
    case "$a" in
        *'"screen":"progress"'*) exec sleep 30 ;;
    esac
done
line="$(head -n1 "${STUB_OSA_QUEUE:-/dev/null}" 2>/dev/null)"
if [[ -n "$line" ]]; then
    q="${STUB_OSA_QUEUE}"
    tail -n +2 "$q" > "${q}.tmp" 2>/dev/null && mv "${q}.tmp" "$q"
    code="${line%%:*}"; out="${line#*:}"
    [[ -n "$out" ]] && printf '%s\n' "$out"
    exit "$code"
fi
exit 0
EOF
chmod +x "$STUBS"/*

# Orchestrator copy with the root gate neutralised (test harness only).
# It must live in the project root so SCRIPT_DIR still resolves lib/.
ORCH="${ROOT}/.jc-enroll-test.$$.sh"
trap 'rm -f "$ORCH"; rm -rf "$WORK"' EXIT
sed 's/^if ! jc_require_root; then$/if false; then/' "$ROOT/jc-enroll.sh" > "$ORCH"
chmod +x "$ORCH"
grep -q 'if false; then' "$ORCH" || { echo "harness could not neutralise root gate"; exit 1; }

run_flow() {
    # run_flow <queue-lines...>  -> echoes combined output
    local statedir logfile queue out
    statedir="${FLOW_STATE_DIR:-${WORK}/state.$RANDOM}"; logfile="${WORK}/log.$RANDOM"
    queue="${WORK}/queue.$RANDOM"
    : > "$queue"
    for l in "$@"; do printf '%s\n' "$l" >> "$queue"; done

    out="$(PATH="$STUBS:$PATH" \
        JC_DRY_RUN=1 \
        SIMULATE_LDAP="${SIM_LDAP:-success}" \
        SIMULATE_BINDING="${SIM_BIND:-success}" \
        STUB_OSA_QUEUE="$queue" \
        STUB_CONSOLE_USER="$ME" \
        JC_STATE_DIR="$statedir" \
        JC_LOG_FILE="$logfile" \
        ORG_ID="org123" API_KEY="k" SYSTEM_ID="sys1" PRIMARY_USER_ID="" \
        START_DELAY_SECONDS=0 CONSOLE_USER_WAIT_MAX=5 \
        COMPANY_NAME="Acme" SUPPORT_CONTACT="IT" \
        bash "$ORCH" --dry-run 2>&1)"
    LAST_STATE_DIR="$statedir"
    printf '%s' "$out"
}

# osascript stub convention: "0:" = default (primary) button,
#                            "1:" = cancel/secondary.

printf '\n--- happy path: link -> verify -> link -> sign out later ---\n'
SIM_LDAP=success SIM_BIND=success
out="$(run_flow "0:" "0:{\"button\":0,\"fields\":{\"email\":\"user@acme.io\",\"password\":\"pw\"}}" "1:")"
assert_contains "$out" "State -> WELCOME"        "reaches WELCOME"
assert_contains "$out" "State -> CREDENTIALS"  "reaches CREDENTIALS"
assert_contains "$out" "Verification result: VERIFIED" "helper reports VERIFIED"
assert_contains "$out" "State -> LINKING"        "reaches LINKING"
assert_contains "$out" "State -> SUCCESS"        "reaches SUCCESS"
assert_contains "$out" "Status: Good"            "reports Good"
assert_contains "$out" "sign out later"          "records sign-out-later choice"
assert_contains "$out" "us\*\*@acme.io"          "email is masked in the log"
assert_not_contains "$out" "user@acme.io"        "raw email never logged unmasked"

printf '\n--- closing the welcome window just ends the run ---\n'
# There is no "Remind Me Later" and no defer state. Dismissing the window
# ends this run; nothing on disk suppresses the next one.
FLOW_STATE_DIR="${WORK}/state_closed"
out="$(run_flow "2:")"
assert_contains "$out" "State -> CLOSED"        "a dismissed welcome closes the run"
assert_not_contains "$out" "State -> CREDENTIALS" "no credential prompt after dismissing"
assert_not_contains "$out" "Status: Deferred"   "no defer status is reported"
if [[ -e "$FLOW_STATE_DIR/defer_until" || -e "$FLOW_STATE_DIR/defer_count" || -e "$FLOW_STATE_DIR/completed" ]]; then
    FAIL=$((FAIL+1)); printf '  FAIL  no state files are written\n'
else
    PASS=$((PASS+1)); printf '  PASS  no state files are written\n'
fi
unset FLOW_STATE_DIR

printf '\n--- a completed enrollment leaves no marker behind ---\n'
# Only primary_user_id decides whether to run, so success must not write a
# local "completed" file that would suppress a later, legitimate run.
FLOW_STATE_DIR="${WORK}/state_done"
out="$(run_flow "0:" "0:{\"button\":0,\"fields\":{\"email\":\"user@acme.io\",\"password\":\"pw\"}}" "1:")"
assert_contains "$out" "Status: Good"           "happy path still completes"
if [[ -e "$FLOW_STATE_DIR/completed" ]]; then
    FAIL=$((FAIL+1)); printf '  FAIL  success writes no completion marker\n'
else
    PASS=$((PASS+1)); printf '  PASS  success writes no completion marker\n'
fi
unset FLOW_STATE_DIR

printf '\n--- invalid email never leaves the credential screen ---\n'
# The helper owns validation now: a malformed address is rejected on the
# screen and re-prompted, so it never crosses the IPC to root and never
# triggers a JumpCloud lookup. Two credential entries, one welcome, one
# success - no separate verify screen any more.
SIM_LDAP=success SIM_BIND=success
out="$(run_flow "0:" \
    "0:{\"button\":0,\"fields\":{\"email\":\"not-an-email\",\"password\":\"pw\"}}" \
    "0:{\"button\":0,\"fields\":{\"email\":\"good@acme.io\",\"password\":\"pw\"}}" \
    "1:")"
assert_not_contains "$out" "not-an-email"       "malformed email never reaches root"
assert_contains "$out" "go\\*\\*@acme.io"          "corrected email is captured (masked)"
assert_contains "$out" "State -> SUCCESS"        "recovers after correcting the email"

printf '\n--- wrong password -> AUTH_FAILED -> close ---\n'
SIM_LDAP=invalid SIM_BIND=success
out="$(run_flow "0:" "0:{\"button\":0,\"fields\":{\"email\":\"user@acme.io\",\"password\":\"pw\"}}" "1:")"
assert_contains "$out" "State -> AUTH_FAILED"    "bad credentials reach AUTH_FAILED"
assert_not_contains "$out" "State -> LINKING"    "binding never runs after auth failure"

printf '\n--- LDAP unavailable is surfaced, binding still never runs ---\n'
SIM_LDAP=unavailable SIM_BIND=success
out="$(run_flow "0:" "0:{\"button\":0,\"fields\":{\"email\":\"user@acme.io\",\"password\":\"pw\"}}" "1:")"
assert_contains "$out" "State -> AUTH_FAILED"    "unavailable LDAP reaches a failure screen"
assert_not_contains "$out" "State -> LINKING"    "no binding when LDAP is unreachable"

printf '\n--- binding failure -> BIND_FAILED (distinct from auth failure) ---\n'
SIM_LDAP=success SIM_BIND=assoc_failed
out="$(run_flow "0:" "0:{\"button\":0,\"fields\":{\"email\":\"user@acme.io\",\"password\":\"pw\"}}" "1:")"
assert_contains "$out" "State -> BIND_FAILED"    "binding failure reaches BIND_FAILED"
assert_contains "$out" "ASSOC_FAILED"            "failure category recorded"
assert_not_contains "$out" "Status: Good"        "does not report success"

printf '\n--- Try Again on BIND_FAILED re-enters LINKING ---\n'
SIM_LDAP=success SIM_BIND=assoc_failed
out="$(run_flow "0:" "0:{\"button\":0,\"fields\":{\"email\":\"user@acme.io\",\"password\":\"pw\"}}" "0:" "1:")"
assert_contains "$out" "State -> BIND_FAILED"    "first attempt fails"
assert_eq "$(printf '%s\n' "$out" | grep -c 'State -> LINKING')" "2" \
    "Try Again runs the binding pipeline a second time"
# CLOSED keeps the issue the failed step already recorded rather than
# overwriting it, so the binding failure survives into the final status.
assert_contains "$out" "State -> CLOSED"        "Close after a retry ends the run"
assert_contains "$out" "Issue: ASSOC_FAILED"    "binding failure is the reported issue"

printf '\n--- already bound: exits before prompting ---\n'
out="$(PATH="$STUBS:$PATH" JC_DRY_RUN=1 STUB_CONSOLE_USER="$ME" \
    JC_LOG_FILE="${WORK}/log.standalone" JC_STATE_DIR="${WORK}/state.$RANDOM" \
    ORG_ID=o API_KEY=k SYSTEM_ID=s PRIMARY_USER_ID="abc123" \
    START_DELAY_SECONDS=0 bash "$ORCH" --dry-run 2>&1)"
assert_contains "$out" "Status: Skipped"         "already-bound device is skipped"
assert_not_contains "$out" "State -> WELCOME"    "no prompt when already bound"

printf '\n--- Secure Token missing: exits without prompting ---\n'
out="$(PATH="$STUBS:$PATH" JC_DRY_RUN=1 STUB_CONSOLE_USER="$ME" \
    JC_LOG_FILE="${WORK}/log.standalone" JC_STATE_DIR="${WORK}/state.$RANDOM" \
    STUB_TOKEN_STATUS="_jumpcloudserviceaccount: Secure Token is DISABLED" \
    ORG_ID=o API_KEY=k SYSTEM_ID=s PRIMARY_USER_ID="" \
    START_DELAY_SECONDS=0 CONSOLE_USER_WAIT_MAX=5 bash "$ORCH" --dry-run 2>&1)"
assert_contains "$out" "Secure Token"            "Secure Token gate reported"
assert_not_contains "$out" "State -> WELCOME"    "no prompt without Secure Token"

printf '\n--- missing ORG_ID fails fast with a clear message ---\n'
out="$(PATH="$STUBS:$PATH" JC_DRY_RUN=1 STUB_CONSOLE_USER="$ME" \
    JC_LOG_FILE="${WORK}/log.standalone" JC_STATE_DIR="${WORK}/state.$RANDOM" \
    ORG_ID="" API_KEY=k SYSTEM_ID=s PRIMARY_USER_ID="" \
    START_DELAY_SECONDS=0 bash "$ORCH" --dry-run 2>&1)"
assert_contains "$out" "ORG_ID not set"          "missing ORG_ID is caught"

printf '\nFlow tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
