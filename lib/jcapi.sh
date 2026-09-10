#!/bin/bash
# =====================================================================
# jcapi.sh - JumpCloud REST operations.
#
# These are the proven calls from the original jc_bind.sh, refactored to
# RETURN status instead of exiting inline, so the orchestrator can decide
# which screen to show (auth failure and binding failure are different
# user-facing states). Endpoints, bodies, retry policy, the
# username-alignment rule and the 409-is-success rule are preserved.
#
# Runs as root only. Never sees the user's password.
# =====================================================================

# Populated by jc_curl; read immediately after each call.
CURL_CODE=""
CURL_BODY=""

# Header args live in a global array. macOS ships bash 3.2, which has no
# `mapfile`, so arrays are built directly rather than read from a pipe.
JC_HDR=()
jc_build_headers() {
    JC_HDR=(-H "x-api-key: ${API_KEY}" -H "Accept: application/json")
    if [[ -n "${ORG_ID:-}" ]]; then
        JC_HDR+=(-H "x-org-id: ${ORG_ID}")
    fi
}

# JSON-escape using only bash parameter expansion (no jq / python).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

jc_lower() { tr '[:upper:]' '[:lower:]'; }

# Retries on network error (curl rc != 0 -> "000") or HTTP 5xx.
# Results are returned via the globals CURL_CODE / CURL_BODY. Caller-named
# output vars are deliberately avoided: bash dynamic scoping made them
# collide with same-named locals and silently produced empty HTTP codes.
jc_curl() {
    local __tmp __code __attempt=1
    __tmp="$(mktemp)"
    while (( __attempt <= API_MAX_TRIES )); do
        # Bounded: without these a dropped (not refused) connection hangs for
        # minutes per attempt, root never answers the UI host's
        # email -> username lookup, and the user sits on "Verifying your
        # account..." with nothing to show for it.
        __code="$(curl -sS --connect-timeout 15 --max-time 45 \
                       -o "$__tmp" -w '%{http_code}' "$@" || echo "000")"
        if [[ "$__code" != "000" ]] && ! [[ "$__code" =~ ^5 ]]; then
            break
        fi
        jc_warn "API attempt ${__attempt} returned HTTP ${__code}; retrying in ${API_RETRY_SLEEP}s..."
        sleep "${API_RETRY_SLEEP}"
        __attempt=$(( __attempt + 1 ))
    done
    CURL_CODE="$__code"
    CURL_BODY="$(cat "$__tmp")"
    rm -f "$__tmp"
}

# ---------------------------------------------------------------------
# Look up a JumpCloud user by email.
# Sets JC_USER_ID / JC_USERNAME. Returns:
#   0 found | 1 not found | 2 lookup error (network/API)
# ---------------------------------------------------------------------
JC_USER_ID=""
JC_USERNAME=""
# The local account name JumpCloud binds to on the device. May be unset on a
# fresh account, where JumpCloud derives it from username.
JC_SYSTEM_USERNAME=""
jc_find_user_by_email() {
    local email="$1"
    jc_build_headers
    jc_info "Looking up JumpCloud user for $(jc_mask_email "$email")"

    # NO `fields` projection. It used to be sent as three separate
    # `fields=` params; JumpCloud takes a single space-separated list, so
    # the server honoured only one and the reply came back WITHOUT _id and
    # username. That made every lookup miss, root answered NONE, and the
    # user was told their (correct) credentials could not be verified -
    # the LDAP bind was never even attempted. Asking for the whole record
    # cannot go wrong the same way.
    jc_curl -G "${JC_BASE}/api/systemusers" \
        --data-urlencode "filter=email:eq:${email}" \
        "${JC_HDR[@]}"

    if ! [[ "$CURL_CODE" =~ ^2 ]]; then
        jc_error "User lookup failed (HTTP ${CURL_CODE})"
        return 2
    fi

    # Split on commas first: a greedy .* across the whole body would jump
    # between fields and, in a full record, pick up a nested _id instead of
    # the record's own. One field per line keeps each match local, and
    # head -n1 takes the first result rather than the last.
    JC_USER_ID="$(printf '%s' "$CURL_BODY" | tr ',' '\n' \
        | sed -n -E 's/.*"_id"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]{24})".*/\1/p' | head -n1)"
    JC_USERNAME="$(printf '%s' "$CURL_BODY" | tr ',' '\n' \
        | sed -n -E 's/.*"username"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"
    # systemUsername is the field the binding step writes, so it is also the
    # field worth comparing against. An unset one is `"systemUsername":null`,
    # which does not match this quoted-string pattern, so it comes back empty
    # and the caller falls back to username.
    JC_SYSTEM_USERNAME="$(printf '%s' "$CURL_BODY" | tr ',' '\n' \
        | sed -n -E 's/.*"systemUsername"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"

    if [[ -z "$JC_USER_ID" ]]; then
        jc_warn "No JumpCloud user matches that email"
        return 1
    fi
    if [[ -z "$JC_USERNAME" ]]; then
        # The LDAP DN is built from the username, so this cannot proceed.
        jc_error "JumpCloud user ${JC_USER_ID} has no username in the API reply"
        return 1
    fi
    jc_info "Resolved JC user_id=${JC_USER_ID} username=${JC_USERNAME}"
    return 0
}

# ---------------------------------------------------------------------
# Current device description (so failure breadcrumbs append, not clobber).
# ---------------------------------------------------------------------
jc_get_system_description() {
    local sid="$1"
    jc_build_headers
    jc_curl -X GET "${JC_BASE}/api/systems/${sid}" "${JC_HDR[@]}"
    if ! [[ "$CURL_CODE" =~ ^2 ]]; then
        printf ''
        return
    fi
    printf '%s' "$CURL_BODY" | tr -d '\n' \
        | sed -n -E 's/.*"description"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' \
        | head -n1
}

jc_append_system_description() {
    # jc_append_system_description <note>
    local note="$1" existing combined esc
    jc_build_headers
    existing="$(jc_get_system_description "$SYSTEM_ID")"
    if [[ -n "$existing" ]]; then
        combined="${existing}"$'\n'"${note}"
    else
        combined="${note}"
    fi
    esc="$(json_escape "$combined")"
    jc_curl -X PUT "${JC_BASE}/api/systems/${SYSTEM_ID}" \
        "${JC_HDR[@]}" -H "Content-Type: application/json" \
        -d "{\"description\":\"${esc}\"}"
    jc_info "Failure breadcrumb write: HTTP ${CURL_CODE}"
}

# ---------------------------------------------------------------------
# Update systemUsername verbatim (original case preserved). Returns 0/1.
# ---------------------------------------------------------------------
jc_update_system_username() {
    local user_id="$1" new_username="$2" email="$3"
    local esc payload code_snapshot body_snapshot safe_msg note
    jc_build_headers

    esc="$(json_escape "$new_username")"
    payload="{\"systemUsername\":\"${esc}\"}"
    jc_info "Updating systemUsername for user_id=${user_id} to '${new_username}' (case preserved)"

    jc_curl -X PUT "${JC_BASE}/api/systemusers/${user_id}" \
        "${JC_HDR[@]}" -H "Content-Type: application/json" -d "$payload"

    if [[ "$CURL_CODE" =~ ^(200|204)$ ]]; then
        jc_info "systemUsername update succeeded (HTTP ${CURL_CODE})"
        return 0
    fi

    # Snapshot before the next curl overwrites the globals.
    code_snapshot="$CURL_CODE"
    body_snapshot="$CURL_BODY"
    jc_error "systemUsername update FAILED (HTTP ${code_snapshot})"

    safe_msg="$(printf '%s' "$body_snapshot" | tr -d '\n' | cut -c1-300)"
    note="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] systemUsername update failed | LocalUser: ${CONSOLE_USER} | JCUsername: ${JC_USERNAME} | UserEmail: ${email} | HTTP ${code_snapshot} | Error: ${safe_msg}"
    jc_append_system_description "$note"
    return 1
}

# ---------------------------------------------------------------------
# Bind user to system. 409 (already associated) counts as success.
# ---------------------------------------------------------------------
jc_associate_user_system() {
    local user_id="$1" system_id="$2" body_json
    jc_build_headers
    jc_info "Binding user_id=${user_id} to system_id=${system_id}"

    body_json=$(cat <<JSON
{
  "attributes": { "sudo": { "enabled": true, "withoutPassword": false } },
  "op": "add",
  "type": "system",
  "id": "${system_id}"
}
JSON
)
    jc_curl -X POST "${JC_BASE}/api/v2/users/${user_id}/associations" \
        "${JC_HDR[@]}" -H "Content-Type: application/json" -d "${body_json}"

    if [[ "$CURL_CODE" =~ ^(200|204|409)$ ]]; then
        jc_info "Bind succeeded (HTTP ${CURL_CODE})"
        return 0
    fi
    jc_error "Bind FAILED (HTTP ${CURL_CODE})"
    return 1
}

# ---------------------------------------------------------------------
# Set the primary system user.
# ---------------------------------------------------------------------
jc_set_primary_user() {
    local user_id="$1" system_id="$2"
    jc_build_headers
    jc_info "Setting user_id=${user_id} as primary user on system_id=${system_id}"

    jc_curl -X PUT "${JC_BASE}/api/systems/${system_id}" \
        "${JC_HDR[@]}" -H "Content-Type: application/json" \
        -d "{\"primarySystemUser\":{\"id\":\"${user_id}\"}}"

    if [[ "$CURL_CODE" =~ ^(200|204)$ ]]; then
        jc_info "Primary user set succeeded (HTTP ${CURL_CODE})"
        return 0
    fi
    jc_error "Primary user set FAILED (HTTP ${CURL_CODE})"
    return 1
}

# ---------------------------------------------------------------------
# Full binding pipeline: align username -> associate -> set primary user.
# Echoes a failure category on failure. Returns 0 on success.
# ---------------------------------------------------------------------
jc_run_binding_pipeline() {
    local user_id="$1" jc_username="$2" local_user="$3" email="$4"
    # Optional 5th arg: the account's current systemUsername. Falls back to
    # the global the lookup filled in, so older call sites keep working.
    local jc_system_username="${5:-${JC_SYSTEM_USERNAME:-}}"
    local local_l cur_l current

    if [[ -n "${SIMULATE_BINDING:-}" && "${JC_DRY_RUN}" == "1" ]]; then
        jc_warn "Binding simulation active: ${SIMULATE_BINDING}"
        sleep 2
        case "$SIMULATE_BINDING" in
            success) return 0 ;;
            *) printf '%s' "$(printf '%s' "$SIMULATE_BINDING" | tr '[:lower:]' '[:upper:]')"; return 1 ;;
        esac
    fi

    # Compare against systemUsername when the account has one: that is the
    # field this step writes, so it is the one that decides whether a write
    # is needed. Fall back to username only when systemUsername is unset (a
    # fresh account, where JumpCloud derives it from username). Comparing
    # against username alone used to skip the update whenever username
    # happened to match the console user, leaving a stale systemUsername.
    current="${jc_system_username:-$jc_username}"
    local_l="$(printf '%s' "$local_user" | jc_lower)"
    cur_l="$(printf '%s' "$current" | jc_lower)"

    # Case-insensitive compare decides IF a write is needed; the value
    # actually sent is always the unmodified console username, and the field
    # written is always systemUsername (never username, which the LDAP DN
    # depends on).
    if [[ "$local_l" != "$cur_l" ]]; then
        jc_info "systemUsername differs (local='${local_user}' current='${current}') - aligning"
        if ! jc_update_system_username "$user_id" "$local_user" "$email"; then
            printf 'USERNAME_ALIGNMENT_FAILED'
            return 1
        fi
    else
        jc_info "systemUsername already matches the console user; no alignment needed"
    fi

    if ! jc_associate_user_system "$user_id" "$SYSTEM_ID"; then
        printf 'ASSOCIATION_FAILED'
        return 1
    fi
    if ! jc_set_primary_user "$user_id" "$SYSTEM_ID"; then
        printf 'PRIMARY_USER_FAILED'
        return 1
    fi
    return 0
}
