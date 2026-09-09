#!/bin/bash
# =====================================================================
# config.sh - GENERIC defaults only.
#
# This file ships inside the deployment package and must stay
# tenant-neutral. Every tenant-specific value is set in the TENANT
# SETTINGS block of the MDM command and exported before this file is
# sourced; each default below only applies when the variable is unset.
# =====================================================================

# ---- JumpCloud tenant ----
: "${ORG_ID:=}"                       # required for LDAP (JumpCloud Org ID)
: "${JC_REGION:=US}"                  # US or EU
: "${API_KEY:=}"                      # injected by the MDM command
: "${SYSTEM_ID:=}"                    # {{device.id}}
: "${PRIMARY_USER_ID:=}"              # {{device.primary_user_id}}

if [[ "$(printf '%s' "$JC_REGION" | tr '[:upper:]' '[:lower:]')" == "eu" ]]; then
    : "${JC_BASE:=https://console.eu.jumpcloud.com}"
else
    : "${JC_BASE:=https://console.jumpcloud.com}"
fi

# ---- LDAP (JumpCloud Cloud LDAP) ----
: "${LDAP_HOST:=ldap.jumpcloud.com}"
: "${LDAP_PORT:=636}"                 # 636 = LDAPS, 389 = StartTLS
: "${LDAP_TIMEOUT:=15}"
# {username} is substituted with the JumpCloud username resolved by the API.
#
# NOT written as `: "${LDAP_USER_DN_TEMPLATE:=uid={username},...}"`. Inside
# ${VAR:=word} the first unescaped } ENDS the expansion, so that form
# silently assigned the truncated "uid={username" - no closing brace, so the
# host's "must contain {username}" check failed and every verification
# returned CONFIG_ERROR ("we couldn't reach the verification service")
# without ever attempting the LDAP bind. A plain assignment has no such trap.
if [[ -z "${LDAP_USER_DN_TEMPLATE:-}" ]]; then
    LDAP_USER_DN_TEMPLATE="uid={username},ou=Users,o=${ORG_ID},dc=jumpcloud,dc=com"
fi
# Hard safety switch: unencrypted LDAP is refused outright, always.
: "${LDAP_REQUIRE_SECURE:=1}"

# ---- Branding / copy ----
: "${COMPANY_NAME:=Your Organization}"
: "${ACCENT_COLOR:=#0E8A5F}"          # brand accent used by every screen
: "${SUPPORT_CONTACT:=your IT administrator}"
# Optional absolute path to an OFFICIAL logo on the device. Empty = use a
# neutral system symbol (never a fabricated JumpCloud logo).
: "${LOGO_PATH:=}"

# ---- Behavior / timing ----
: "${START_DELAY_SECONDS:=5}"
: "${CONSOLE_USER_WAIT_MAX:=600}"
: "${CONSOLE_USER_WAIT_INTERVAL:=10}"
: "${API_MAX_TRIES:=3}"
: "${API_RETRY_SLEEP:=3}"
: "${REQUIRE_SECURE_TOKEN:=1}"        # gate on _jumpcloudserviceaccount
: "${JC_SVC_ACCOUNT:=_jumpcloudserviceaccount}"

# ---- Paths ----
: "${JC_STATE_DIR:=/Library/Application Support/JumpCloudEnrollment}"
: "${JC_LOG_FILE:=/var/log/jc_enroll.log}"

# ---- Test hooks (only honored with --dry-run) ----
: "${JC_DRY_RUN:=0}"
: "${SIMULATE_LDAP:=}"                # success|invalid|unavailable|timeout
: "${SIMULATE_BINDING:=}"             # success|assoc_failed|primary_failed
