#!/bin/bash
# =====================================================================
# preview-flow.sh - click through the REAL screens WITHOUT sudo.
#
# dry-run.sh needs root because the production flow reaches the console
# user's GUI session through `launchctl asuser <uid> sudo -u <user> ...`.
# When you are ALREADY the console user those two are no-ops, so this
# harness stubs just them and runs the same orchestrator, the same state
# machine and the same lib/jc-ui.js renderer under your own account.
#
# LDAP and binding are simulated and sign-out is suppressed, exactly as in
# dry-run.sh. State and log go to a temp directory, so nothing touches
# /var/log or /Library/Application Support and nothing changes in
# JumpCloud.
#
#   ./tests/preview-flow.sh                      # happy path
#   ./tests/preview-flow.sh --ldap invalid       # wrong password
#   ./tests/preview-flow.sh --bind assoc_failed  # binding failure
#
# This is for reviewing the UI. Run `sudo ./tests/dry-run.sh` for the real
# root path (launchctl asuser, the root-owned log) before deploying.
# =====================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SIM_LDAP="success"
SIM_BIND="success"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ldap) SIM_LDAP="$2"; shift 2 ;;
        --bind) SIM_BIND="$2"; shift 2 ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1"; exit 1 ;;
    esac
done

if [[ "$(id -u)" -eq 0 ]]; then
    printf 'Run this WITHOUT sudo - it previews the flow as the console user.\n'
    printf 'For the real root path use: sudo ./tests/dry-run.sh\n'
    exit 1
fi

WORK="$(mktemp -d)"
STUBS="${WORK}/bin"
mkdir -p "$STUBS"
ORCH="${ROOT}/.jc-enroll-preview.$$.sh"
trap 'rm -rf "$WORK"; rm -f "$ORCH"' EXIT

# Already the console user: asuser/sudo -u are identity here.
cat > "$STUBS/launchctl" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "asuser" ]] && shift 2
exec "$@"
STUB
cat > "$STUBS/sudo" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "-u" ]] && shift 2
exec "$@"
STUB
chmod +x "$STUBS"/*

# Root gate neutralised in a COPY; production code keeps its gate.
sed 's/^if ! jc_require_root; then$/if false; then/' "$ROOT/jc-enroll.sh" > "$ORCH"
grep -q 'if false; then' "$ORCH" || { printf 'could not neutralise the root gate\n'; exit 1; }

printf '\n=== UI PREVIEW (no sudo) ===\n'
printf '  LDAP:    simulated: %s\n' "$SIM_LDAP"
printf '  Binding: simulated: %s (nothing changes in JumpCloud)\n' "$SIM_BIND"
printf '  Sign-out: suppressed\n'
printf '  State:   %s\n' "$WORK/state (discarded on exit)"
printf '  Log:     %s\n\n' "$WORK/jc_enroll.log"

PATH="$STUBS:$PATH" \
JC_DRY_RUN=1 \
SIMULATE_LDAP="$SIM_LDAP" \
SIMULATE_BINDING="$SIM_BIND" \
JC_STATE_DIR="${WORK}/state" \
JC_LOG_FILE="${WORK}/jc_enroll.log" \
ORG_ID="${ORG_ID:-preview-org}" \
API_KEY="${API_KEY:-preview}" \
SYSTEM_ID="${SYSTEM_ID:-preview-system}" \
PRIMARY_USER_ID="" \
START_DELAY_SECONDS=0 \
CONSOLE_USER_WAIT_MAX=30 \
COMPANY_NAME="${COMPANY_NAME:-Your Organization (Preview)}" \
SUPPORT_CONTACT="${SUPPORT_CONTACT:-the IT service desk}" \
bash "$ORCH" --dry-run
rc=$?

printf '\n=== PREVIEW COMPLETE (exit %s) ===\n' "$rc"
printf 'Log kept until this script exits: %s\n' "${WORK}/jc_enroll.log"
exit $rc
