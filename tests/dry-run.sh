#!/bin/bash
# =====================================================================
# dry-run.sh - pre-MDM validation ON A REAL MAC.
#
# Runs the real orchestrator as root with the real machinery - console
# user detection, Secure Token gate, the AppKit screens in the user's
# session, the credential helper - while SIMULATING the LDAP result and
# the device binding. Nothing changes in JumpCloud and no sign-out
# happens.
#
#   sudo ./tests/dry-run.sh                       # happy path
#   sudo ./tests/dry-run.sh --ldap invalid        # wrong password
#   sudo ./tests/dry-run.sh --ldap unavailable    # LDAP unreachable
#   sudo ./tests/dry-run.sh --bind assoc_failed   # binding failure
#   sudo ./tests/dry-run.sh --real-ldap --org <ORGID>   # REAL LDAPS bind
#
# --real-ldap performs a genuine (read-only) LDAPS bind so you can prove
# the DN template and LDAP enablement work. Binding stays simulated.
# =====================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SIM_LDAP="success"
SIM_BIND="success"
REAL_LDAP=0
ORG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ldap) SIM_LDAP="$2"; shift 2 ;;
        --bind) SIM_BIND="$2"; shift 2 ;;
        --org)  ORG="$2"; shift 2 ;;
        --real-ldap) REAL_LDAP=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1"; exit 1 ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    printf 'Run with sudo: sudo %s\n' "$0"
    exit 1
fi

if [[ $REAL_LDAP -eq 1 ]]; then
    SIM_LDAP=""
    if [[ -z "$ORG" ]]; then
        printf 'ERROR: --real-ldap needs --org <JumpCloud Org ID> to build the user DN.\n'
        exit 1
    fi
fi

printf '\n=== JumpCloud enrollment DRY RUN ===\n'
printf '  LDAP:    %s\n' "$([[ $REAL_LDAP -eq 1 ]] && echo 'REAL LDAPS bind (read-only)' || echo "simulated: $SIM_LDAP")"
printf '  Binding: simulated: %s (nothing changes in JumpCloud)\n' "$SIM_BIND"
printf '  Sign-out: suppressed\n'
printf '  State:   %s\n\n' "/Library/Application Support/JumpCloudEnrollment (dry-run does not mark completed)"

export JC_DRY_RUN=1
export SIMULATE_LDAP="$SIM_LDAP"
export SIMULATE_BINDING="$SIM_BIND"
export ORG_ID="${ORG:-dryrun-org}"
export COMPANY_NAME="${COMPANY_NAME:-Your Organization (Dry Run)}"
export SUPPORT_CONTACT="${SUPPORT_CONTACT:-the IT service desk}"
# Keep the wait short so a dry run does not sit for 10 minutes.
export CONSOLE_USER_WAIT_MAX="${CONSOLE_USER_WAIT_MAX:-60}"
export START_DELAY_SECONDS="${START_DELAY_SECONDS:-0}"

bash "$ROOT/jc-enroll.sh" --dry-run
rc=$?

printf '\n=== DRY RUN COMPLETE (exit %s) ===\n' "$rc"
printf 'Full log: /var/log/jc_enroll.log  (sudo tail -40 /var/log/jc_enroll.log)\n'
exit $rc
