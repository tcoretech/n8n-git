#!/usr/bin/env bash
# =========================================================
# lib/n8n/auth.sh - n8n API authentication
# =========================================================
# Authentication and request handling for n8n API

if [[ -n "${LIB_N8N_AUTH_LOADED:-}" ]]; then
  return 0
fi
LIB_N8N_AUTH_LOADED=true

# shellcheck source=lib/n8n/utils.sh
source "${BASH_SOURCE[0]%/*}/utils.sh"

# ============================================================================
# Session-based Authentication Functions for REST API (/rest/* endpoints)
# ============================================================================

# Global variable to store session cookie state
N8N_SESSION_COOKIE_FILE=""
N8N_SESSION_COOKIE_INITIALIZED="false"
N8N_SESSION_COOKIE_READY="false"
N8N_SESSION_REUSE_ENABLED="false"
# Records the current authentication path: "api_key", "session", or empty when undecided.
N8N_API_AUTH_MODE=""
# Optional hint for n8n_api_request to treat certain statuses as expected (suppresses error logging)
N8N_API_EXPECTED_STATUS=""
N8N_API_SUPPRESS_ERRORS="false"
declare -g N8N_PROJECTS_CACHE_JSON=""

determine_n8n_login_throttle_file() {
    local base_dir=""
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        base_dir="${XDG_CACHE_HOME}"
    elif [[ -n "${HOME:-}" ]]; then
        base_dir="${HOME}/.cache"
    else
        base_dir="/tmp"
    fi
    printf '%s/n8n-git/session-login.cooldown' "$base_dir"
}

N8N_LOGIN_THROTTLE_FILE="$(determine_n8n_login_throttle_file)"
N8N_LOGIN_THROTTLE_DIR_READY="false"
N8N_SESSION_COOLDOWN_UNTIL="0"

n8n_ensure_login_throttle_dir() {
    if [[ "$N8N_LOGIN_THROTTLE_DIR_READY" == "true" ]]; then
        return 0
    fi
    local throttle_dir
    throttle_dir="$(dirname "$N8N_LOGIN_THROTTLE_FILE")"
    if ! mkdir -p "$throttle_dir" 2>/dev/null; then
        log WARN "Unable to create throttle directory $throttle_dir"
        return 1
    fi
    if [[ ! -w "$throttle_dir" ]]; then
        log WARN "Throttle directory $throttle_dir is not writable"
        return 1
    fi
    N8N_LOGIN_THROTTLE_DIR_READY="true"
    return 0
}

n8n_load_login_cooldown_from_file() {
    if [[ ! -f "$N8N_LOGIN_THROTTLE_FILE" ]]; then
        N8N_SESSION_COOLDOWN_UNTIL="0"
        return
    fi

    local raw_until
    raw_until=$(tr -d '\r\n' <"$N8N_LOGIN_THROTTLE_FILE" 2>/dev/null || printf '')
    if [[ "$raw_until" =~ ^[0-9]+$ ]]; then
        N8N_SESSION_COOLDOWN_UNTIL="$raw_until"
    else
        N8N_SESSION_COOLDOWN_UNTIL="0"
    fi
}

n8n_wait_for_login_cooldown_if_needed() {
    local now
    now=$(date +%s 2>/dev/null || printf '0')

    if (( N8N_SESSION_COOLDOWN_UNTIL <= now )); then
        n8n_load_login_cooldown_from_file
    fi

    if (( N8N_SESSION_COOLDOWN_UNTIL > now )); then
        local wait_seconds
        wait_seconds=$((N8N_SESSION_COOLDOWN_UNTIL - now))
        if (( wait_seconds > 0 )); then
            log INFO "Waiting ${wait_seconds}s before attempting n8n login to respect server throttling"
            sleep "$wait_seconds"
        fi
        N8N_SESSION_COOLDOWN_UNTIL="0"
        rm -f "$N8N_LOGIN_THROTTLE_FILE" 2>/dev/null || true
    fi
}

n8n_schedule_login_cooldown() {
    local delay_seconds="$1"
    if [[ -z "$delay_seconds" || ! "$delay_seconds" =~ ^[0-9]+$ ]]; then
        return
    fi
    if (( delay_seconds <= 0 )); then
        return
    fi

    local now until_ts
    now=$(date +%s 2>/dev/null || printf '0')
    until_ts=$((now + delay_seconds))
    if n8n_ensure_login_throttle_dir; then
        printf '%s' "$until_ts" >"$N8N_LOGIN_THROTTLE_FILE" 2>/dev/null || true
        N8N_SESSION_COOLDOWN_UNTIL="$until_ts"
    fi
}

n8n_parse_retry_after_header() {
    local header_file="$1"
    if [[ -z "$header_file" || ! -f "$header_file" ]]; then
        return 1
    fi

    local retry_raw
    retry_raw=$(awk 'tolower($1)=="retry-after:" {print $2; exit}' "$header_file" 2>/dev/null | tr -d '\r')
    if [[ -z "$retry_raw" ]]; then
        return 1
    fi

    if [[ "$retry_raw" =~ ^[0-9]+$ ]]; then
        printf '%s' "$retry_raw"
        return 0
    fi

    local retry_epoch
    retry_epoch=$(date -d "$retry_raw" +%s 2>/dev/null || printf '')
    if [[ "$retry_epoch" =~ ^[0-9]+$ ]]; then
        local now
        now=$(date +%s 2>/dev/null || printf '0')
        if (( retry_epoch > now )); then
            printf '%s' $((retry_epoch - now))
            return 0
        fi
    fi

    return 1
}

ensure_n8n_session_credentials() {
    local container_id="$1"
    local credential_name="$2"
    local container_credentials_path="${3:-}"

    if [[ -n "${n8n_email:-}" && -n "${n8n_password:-}" ]]; then
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Using existing n8n session credentials from configuration"
        fi
        return 0
    fi

    if [[ -z "$credential_name" ]]; then
        log ERROR "Session credential name is required to load n8n session access credentials."
        return 1
    fi

    if [[ -z "$container_id" ]]; then
        log ERROR "Docker container ID is required to discover n8n session credentials."
        return 1
    fi

    local lookup_export_path="$container_credentials_path"
    local remove_lookup_file="false"
    if [[ -z "$lookup_export_path" ]]; then
        lookup_export_path="/tmp/n8n-session-credentials-lookup-$$.json"
        remove_lookup_file="true"
    fi

    local skip_export="false"
    if [[ -n "$container_credentials_path" ]]; then
        # Check if file exists silently (without logging "Would execute" in dry run)
        if docker exec "$container_id" sh -c "[ -f '$container_credentials_path' ]" >/dev/null 2>&1; then
            skip_export="true"
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Reusing existing credentials export at $container_credentials_path"
            fi
        fi
    fi

    local host_tmp_dir
    host_tmp_dir=$(portable_mktemp_dir "n8n-session-credentials")
    local host_lookup_file="$host_tmp_dir/credentials.lookup.json"
    local docker_cp_lookup_target
    docker_cp_lookup_target=$(convert_path_for_docker_cp "$host_tmp_dir")
    if [[ -z "$docker_cp_lookup_target" ]]; then
        docker_cp_lookup_target="$host_tmp_dir"
    fi

    if [[ "$skip_export" != "true" ]]; then
        if ! dockExec "$container_id" "n8n export:credentials --all --output='$lookup_export_path'" false; then
            cleanup_temp_path "$host_tmp_dir"
            if [[ "$remove_lookup_file" == "true" ]]; then
                dockExec "$container_id" "rm -f '$lookup_export_path'" false >/dev/null 2>&1 || true
            fi
            log ERROR "Failed to export credentials from n8n container to locate '$credential_name'."
            return 1
        fi
    fi

    local cp_output=""
    local used_exec_fallback="false"
    if ! cp_output=$(docker cp "${container_id}:${lookup_export_path}" "$docker_cp_lookup_target" 2>&1); then
        if [[ -n "$cp_output" ]]; then
            log WARN "docker cp failed while retrieving session credentials: ${cp_output//$'\n'/ }"
        fi

        local fallback_err_file="$host_tmp_dir/exec-fallback.err"
        if docker exec "$container_id" sh -c "cat '$lookup_export_path'" >"$host_lookup_file" 2>"$fallback_err_file"; then
            used_exec_fallback="true"
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Streamed exported credentials via docker exec fallback."
            fi
            rm -f "$fallback_err_file"
        else
            local fallback_error=""
            if [[ -s "$fallback_err_file" ]]; then
                fallback_error=$(tr -d '\r' <"$fallback_err_file")
            fi
            rm -f "$fallback_err_file"
            cleanup_temp_path "$host_tmp_dir"
            if [[ "$remove_lookup_file" == "true" ]]; then
                dockExec "$container_id" "rm -f '$lookup_export_path'" false >/dev/null 2>&1 || true
            fi
            log ERROR "Unable to copy exported credentials from n8n container."
            if [[ -n "$fallback_error" && "$verbose" == "true" ]]; then
                log DEBUG "docker exec fallback error: ${fallback_error//$'\n'/ }"
            fi
            return 1
        fi
    fi

    if [[ "$used_exec_fallback" != "true" ]]; then
        local copied_name
        copied_name=$(basename "$lookup_export_path")
        if [[ ! -f "$host_tmp_dir/$copied_name" ]]; then
            cleanup_temp_path "$host_tmp_dir"
            log ERROR "Exported credentials file '$copied_name' missing after docker cp."
            return 1
        fi
        mv "$host_tmp_dir/$copied_name" "$host_lookup_file"
        if [[ -n "$cp_output" && "$verbose" == "true" ]]; then
            log DEBUG "docker cp output: ${cp_output//$'\n'/ }"
        fi
    fi

    if [[ "$remove_lookup_file" == "true" ]]; then
        dockExec "$container_id" "rm -f '$lookup_export_path'" false >/dev/null 2>&1 || true
    fi

    if ! jq empty "$host_lookup_file" >/dev/null 2>&1; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Exported credentials payload is not valid JSON; cannot locate '$credential_name'."
        return 1
    fi

    local credential_entry
    credential_entry=$(jq -c --arg name "$credential_name" '
        (if type == "array" then . else (.data // []) end)
        | map(select(((.name // "") | ascii_downcase) == ($name | ascii_downcase) or ((.displayName // "") | ascii_downcase) == ($name | ascii_downcase)))
        | first // empty
    ' "$host_lookup_file" 2>/dev/null || true)

    if [[ -z "$credential_entry" || "$credential_entry" == "null" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' not found in exported credentials."
        return 1
    fi

    local credential_id
    credential_id=$(jq -r '.id // empty' <<<"$credential_entry")
    if [[ -z "$credential_id" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' does not include an id."
        return 1
    fi

    local targeted_container_path
    targeted_container_path="/tmp/n8n-session-credential-${credential_id}.json"

    if ! dockExec "$container_id" "n8n export:credentials --id='$credential_id' --decrypted --output='$targeted_container_path'" false; then
        cleanup_temp_path "$host_tmp_dir"
        dockExec "$container_id" "rm -f '$targeted_container_path'" false >/dev/null 2>&1 || true
        log ERROR "Failed to export credential '$credential_name' using targeted ID."
        return 1
    fi

    local host_target_file="$host_tmp_dir/credential.target.json"
    local docker_cp_target_dir="$docker_cp_lookup_target"
    local target_copy_output=""
    local target_fallback_used="false"
    if ! target_copy_output=$(docker cp "${container_id}:${targeted_container_path}" "$docker_cp_target_dir" 2>&1); then
        if [[ -n "$target_copy_output" ]]; then
            log WARN "docker cp failed while retrieving targeted credential: ${target_copy_output//$'\n'/ }"
        fi
        local target_err="$host_tmp_dir/targeted-copy.err"
        if docker exec "$container_id" sh -c "cat '$targeted_container_path'" >"$host_target_file" 2>"$target_err"; then
            target_fallback_used="true"
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Streamed targeted credential export via docker exec fallback."
            fi
            rm -f "$target_err"
        else
            local fallback_error=""
            if [[ -s "$target_err" ]]; then
                fallback_error=$(tr -d '\r' <"$target_err")
            fi
            rm -f "$target_err"
            cleanup_temp_path "$host_tmp_dir"
            dockExec "$container_id" "rm -f '$targeted_container_path'" false >/dev/null 2>&1 || true
            log ERROR "Unable to copy targeted credential export from container."
            if [[ -n "$fallback_error" && "$verbose" == "true" ]]; then
                log DEBUG "docker exec fallback error: ${fallback_error//$'\n'/ }"
            fi
            return 1
        fi
    fi

    if [[ "$target_fallback_used" != "true" ]]; then
        local targeted_name
        targeted_name=$(basename "$targeted_container_path")
        if [[ ! -f "$host_tmp_dir/$targeted_name" ]]; then
            cleanup_temp_path "$host_tmp_dir"
            dockExec "$container_id" "rm -f '$targeted_container_path'" false >/dev/null 2>&1 || true
            log ERROR "Targeted credential export '$targeted_name' missing after docker cp."
            return 1
        fi
        mv "$host_tmp_dir/$targeted_name" "$host_target_file"
        if [[ -n "$target_copy_output" && "$verbose" == "true" ]]; then
            log DEBUG "docker cp output (targeted): ${target_copy_output//$'\n'/ }"
        fi
    fi

    dockExec "$container_id" "rm -f '$targeted_container_path'" false >/dev/null 2>&1 || true

    if ! jq empty "$host_target_file" >/dev/null 2>&1; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Targeted credential export for '$credential_name' is not valid JSON."
        return 1
    fi

    local resolved_user
    local resolved_password
    resolved_user=$(jq -r '
        (if type == "array" then .[0] else . end) |
        .data // {} |
        (.user // .username // .email // .login // .accountId // empty)
    ' "$host_target_file" 2>/dev/null || true)
    resolved_password=$(jq -r '
        (if type == "array" then .[0] else . end) |
        .data // {} |
        (.password // .pass // .userPassword // .apiKey // .token // empty)
    ' "$host_target_file" 2>/dev/null || true)

    if [[ -z "$resolved_user" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' does not contain a username or email field."
        return 1
    fi

    if [[ -z "$resolved_password" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' does not contain a password or token field."
        return 1
    fi

    n8n_email="$(printf '%s' "$resolved_user" | tr -d '\r\n')"
    n8n_password="$(printf '%s' "$resolved_password" | tr -d '\r\n')"

    cleanup_temp_path "$host_tmp_dir"

    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "Loaded n8n session credential '$credential_name' (id: $credential_id, user: $n8n_email)"
    fi

    return 0
}

ensure_n8n_session_cookie_file() {
    if [[ "$N8N_SESSION_COOKIE_INITIALIZED" != "true" || -z "$N8N_SESSION_COOKIE_FILE" ]]; then
        local cookie_path
        cookie_path=$(mktemp -t n8n-session-cookies-XXXXXXXX)
        N8N_SESSION_COOKIE_FILE="$cookie_path"
        N8N_SESSION_COOKIE_INITIALIZED="true"
    fi
}

# Authenticate with n8n and get session cookie for REST API endpoints
authenticate_n8n_session() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local max_attempts="${4:-10}"  # Default to 10 attempts for stability
    local prompt_on_retry="${5:-true}"
    
    # Clean up URL
    base_url="${base_url%/}"

    ensure_n8n_session_cookie_file

    if [[ "$N8N_SESSION_COOKIE_READY" == "true" && -s "$N8N_SESSION_COOKIE_FILE" ]]; then
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "Reusing existing n8n session cookie at $N8N_SESSION_COOKIE_FILE"
        fi
        return 0
    fi

    N8N_SESSION_COOKIE_READY="false"

    local attempt=1
    local base_origin="$base_url"

    while [[ $attempt -le $max_attempts ]]; do
        n8n_wait_for_login_cooldown_if_needed
        : >"$N8N_SESSION_COOKIE_FILE"

        # If this is a retry, prompt for new credentials
        if [[ $attempt -gt 1 ]]; then
            if [[ "$prompt_on_retry" == "true" ]]; then
                log WARN "Login attempt $((attempt-1)) failed. Please try again."
                printf "n8n email: "
                read -r email
                printf "n8n password: "
                read -r -s password
                echo
            else
                log WARN "Login attempt $((attempt-1)) failed. Retrying with existing credentials."
            fi
        fi

        local curl_cookie_file
        curl_cookie_file="$(native_path_for_host_tools "$N8N_SESSION_COOKIE_FILE")"

        # Initialize cookies by hitting root (helps with some n8n versions/environments)
        curl -s -L -c "$curl_cookie_file" -b "$curl_cookie_file" "$base_url/" >/dev/null 2>&1

        local csrf_response
        local csrf_status
        local csrf_body
        local csrf_token=""

        if ! csrf_response=$(curl -s -L -w "\n%{http_code}" -c "$curl_cookie_file" -b "$curl_cookie_file" \
            -H "Accept: application/json, text/plain, */*" \
            -H "X-Requested-With: XMLHttpRequest" \
            "$base_url/rest/login"); then
            log ERROR "Failed to reach n8n login endpoint (attempt $attempt/$max_attempts)"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max attempts reached. Please check network connectivity and n8n server status."
                return 1
            fi
            ((attempt++))
            sleep 1
            continue
        fi

        csrf_status=$(echo "$csrf_response" | tail -n1)
        csrf_body=$(echo "$csrf_response" | head -n -1)

        # Handle server startup states
        if [[ "$csrf_status" == "404" || "$csrf_status" == "502" || "$csrf_status" == "503" || "$csrf_status" == "000" ]]; then
             log WARN "Login endpoint returned HTTP $csrf_status - server might be starting up (attempt $attempt/$max_attempts)"
             ((attempt++))
             sleep 3
             continue
        fi

        if [[ "$csrf_status" == "200" ]]; then
            csrf_token=$(printf '%s' "$csrf_body" | jq -r '.data.csrfToken // empty' 2>/dev/null || true)
            if [[ -z "$csrf_token" ]]; then
                if jq -e '.data.email? // empty' <<<"$csrf_body" >/dev/null 2>&1; then
                    if [[ -s "$N8N_SESSION_COOKIE_FILE" ]]; then
                        log SUCCESS "Successfully authenticated with n8n session!" >&2
                        log DEBUG "Session cookie stored at $N8N_SESSION_COOKIE_FILE"
                        N8N_SESSION_COOKIE_READY="true"
                        return 0
                    fi
                fi
            fi
        fi

        local login_payload
        # Include emailOrLdapLoginId as it may be required by some n8n versions
        login_payload=$(jq -n --arg email "$email" --arg password "$password" '{email:$email,emailOrLdapLoginId:$email,password:$password,rememberMe:true}')

        local -a login_headers=(
            "-H" "Content-Type: application/json"
            "-H" "Accept: application/json, text/plain, */*"
            "-H" "Accept-Language: en"
            "-H" "X-Requested-With: XMLHttpRequest"
            "-H" "Origin: $base_origin"
            "-H" "Referer: ${base_origin}/login"
        )
        if [[ -n "$csrf_token" ]]; then
            login_headers+=("-H" "X-N8N-CSRF-Token: $csrf_token")
        fi

        local auth_response
        local login_header_tmp
        login_header_tmp=$(mktemp -t n8n-login-headers-XXXXXXXX)

        if ! auth_response=$(curl -s -L -D "$login_header_tmp" -w "\n%{http_code}" -c "$curl_cookie_file" -b "$curl_cookie_file" \
            -X POST \
            "${login_headers[@]}" \
            -d "$login_payload" \
            "$base_url/rest/login"); then
            log ERROR "Failed to connect to n8n login endpoint (attempt $attempt/$max_attempts)"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max attempts reached. Please check network connectivity and n8n server status."
                rm -f "$login_header_tmp" 2>/dev/null || true
                return 1
            fi
            rm -f "$login_header_tmp" 2>/dev/null || true
            ((attempt++))
            sleep 1
            continue
        fi

        local http_status
        http_status=$(echo "$auth_response" | tail -n1)
        local response_body
        response_body=$(echo "$auth_response" | head -n -1)

        if [[ "$http_status" == "200" || "$http_status" == "204" ]]; then
            if [[ ! -s "$N8N_SESSION_COOKIE_FILE" ]]; then
                log ERROR "Login response succeeded but session cookie file is empty"
            elif ! grep -q 'n8n-auth' "$N8N_SESSION_COOKIE_FILE" 2>/dev/null; then
                log ERROR "Login response did not provide an n8n session cookie"
            else
                log SUCCESS "Successfully authenticated with n8n session!" >&2
                log DEBUG "Session cookie stored at $N8N_SESSION_COOKIE_FILE"
                N8N_SESSION_COOKIE_READY="true"
                rm -f "$login_header_tmp" 2>/dev/null || true
                return 0
            fi
        elif [[ "$http_status" == "401" ]]; then
            log ERROR "Invalid credentials (HTTP 401) - attempt $attempt/$max_attempts"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max login attempts reached. Please verify your credentials."
                : >"$N8N_SESSION_COOKIE_FILE"
                rm -f "$login_header_tmp" 2>/dev/null || true
                return 1
            fi
        elif [[ "$http_status" == "403" ]]; then
            log ERROR "Access forbidden (HTTP 403) - account may be locked or disabled"
            : >"$N8N_SESSION_COOKIE_FILE"
            rm -f "$login_header_tmp" 2>/dev/null || true
            return 1
        elif [[ "$http_status" == "429" ]]; then
            local retry_after_seconds
            retry_after_seconds=$(n8n_parse_retry_after_header "$login_header_tmp" 2>/dev/null || printf '')
            if [[ -z "$retry_after_seconds" ]]; then
                retry_after_seconds=$((attempt * 2))
                if [[ $retry_after_seconds -lt 2 ]]; then
                    retry_after_seconds=2
                fi
            fi

            if [[ $attempt -lt $max_attempts ]]; then
                log WARN "Too many requests (HTTP 429) - retrying after ${retry_after_seconds}s"
                : >"$N8N_SESSION_COOKIE_FILE"
                n8n_schedule_login_cooldown "$retry_after_seconds"
                rm -f "$login_header_tmp" 2>/dev/null || true
                ((attempt++))
                continue
            fi

            log ERROR "Too many requests (HTTP 429) - please wait before trying again"
            : >"$N8N_SESSION_COOKIE_FILE"
            n8n_schedule_login_cooldown "$retry_after_seconds"
            rm -f "$login_header_tmp" 2>/dev/null || true
            return 1
        else
            log ERROR "Login failed with HTTP $http_status (attempt $attempt/$max_attempts)"
            if [[ -n "$response_body" ]]; then
                log DEBUG "Login response body: $response_body"
            fi
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max attempts reached. Server may be experiencing issues."
                : >"$N8N_SESSION_COOKIE_FILE"
                rm -f "$login_header_tmp" 2>/dev/null || true
                return 1
            fi
        fi

        rm -f "$login_header_tmp" 2>/dev/null || true
        ((attempt++))
        sleep 1
    done

    return 1
}

# Cleanup session cookie file
cleanup_n8n_session() {
    local mode="${1:-auto}"

    if [[ "$mode" == "force" ]]; then
        if [[ -n "$N8N_SESSION_COOKIE_FILE" && -f "$N8N_SESSION_COOKIE_FILE" ]]; then
            rm -f "$N8N_SESSION_COOKIE_FILE"
            log DEBUG "Cleaned up session cookie file (EXIT trap)"
        fi
        N8N_SESSION_COOKIE_FILE=""
        N8N_SESSION_COOKIE_INITIALIZED="false"
        N8N_SESSION_COOKIE_READY="false"
        return 0
    fi

    if [[ "$N8N_SESSION_REUSE_ENABLED" == "true" ]]; then
        return 0
    fi

    if [[ -n "$N8N_SESSION_COOKIE_FILE" && -f "$N8N_SESSION_COOKIE_FILE" ]]; then
        rm -f "$N8N_SESSION_COOKIE_FILE"
        log DEBUG "Cleaned up session cookie file"
    fi
    N8N_SESSION_COOKIE_FILE=""
    N8N_SESSION_COOKIE_INITIALIZED="false"
       N8N_SESSION_COOKIE_READY="false"

    return 0
}

prepare_n8n_api_auth() {
    local container_id="$1"
    local container_credentials_path="${2:-}"

    if [[ "$N8N_API_AUTH_MODE" == "api_key" ]]; then
        return 0
    fi

    if [[ "${verbose:-false}" == "true" ]]; then
        local password_status
        if [[ -n "${n8n_password:-}" ]]; then
            password_status="set"
        else
            password_status="unset"
        fi
        log DEBUG "Preparing n8n API auth (email='${n8n_email:-}', password=${password_status})"
        log DEBUG "Session state: READY=${N8N_SESSION_COOKIE_READY:-} FILE=${N8N_SESSION_COOKIE_FILE:-}"
    fi

    if [[ -z "$n8n_base_url" ]]; then
        log ERROR "n8n base URL is required to interact with the API."
        return 1
    fi

    n8n_base_url="${n8n_base_url%/}"

    if [[ "$N8N_SESSION_COOKIE_READY" == "true" && -f "$N8N_SESSION_COOKIE_FILE" ]]; then
        if [[ "$verbose" == "true" ]]; then
            if [[ "$N8N_API_AUTH_MODE" == "session" ]]; then
                log DEBUG "Reusing existing n8n session."
            else
                log DEBUG "Reusing cached n8n session"
            fi
        fi
        N8N_API_AUTH_MODE="session"
        return 0
    fi

    if [[ "$N8N_API_AUTH_MODE" == "session" ]]; then
        N8N_API_AUTH_MODE=""
    fi

    if [[ -n "${n8n_api_key:-}" ]]; then
        N8N_API_AUTH_MODE="api_key"
        return 0
    fi

    local have_direct_credentials="false"
    if [[ -n "${n8n_email:-}" && -n "${n8n_password:-}" ]]; then
        have_direct_credentials="true"
    fi

    if [[ "$have_direct_credentials" != "true" ]]; then
        if [[ -z "${n8n_session_credential:-}" ]]; then
            log ERROR "n8n session credential name not configured; cannot authenticate without API key."
            return 1
        fi

        if ! ensure_n8n_session_credentials "$container_id" "$n8n_session_credential" "$container_credentials_path"; then
            return 1
        fi

        have_direct_credentials="true"
    fi

    if [[ "$have_direct_credentials" == "true" ]]; then
        local session_attempts="${N8N_SESSION_MAX_ATTEMPTS:-5}"
        if ! [[ "$session_attempts" =~ ^[0-9]+$ ]]; then
            session_attempts=5
        elif (( session_attempts < 1 )); then
            session_attempts=5
        fi

        if ! authenticate_n8n_session "$n8n_base_url" "$n8n_email" "$n8n_password" "$session_attempts" false; then
            log ERROR "Unable to authenticate with n8n session for folder structure operations."
            return 1
        fi

        N8N_API_AUTH_MODE="session"
        return 0
    fi

    log ERROR "Unable to determine n8n authentication mode."
    return 1
}

finalize_n8n_api_auth() {
    # Session will be cleaned up by EXIT trap if needed
    # No need to log here as this is called during normal finalization
    N8N_API_AUTH_MODE=""
}

n8n_api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="${3:-}"

    if [[ -z "$N8N_API_AUTH_MODE" ]]; then
        log ERROR "n8n API authentication not initialised."
        return 1
    fi

    local url="$n8n_base_url/rest${endpoint}"
    local -a curl_args=("-sS" "-w" "\n%{http_code}" "-X" "$method" "$url")

    if [[ -n "$payload" ]]; then
        curl_args+=("-H" "Content-Type: application/json")
        curl_args+=("-d" "$payload")
    fi

    curl_args+=("-H" "Accept: application/json")

    if [[ "$N8N_API_AUTH_MODE" == "api_key" ]]; then
        curl_args+=("-H" "X-N8N-API-KEY: $n8n_api_key")
    else
        local curl_cookie_file
        curl_cookie_file="$(native_path_for_host_tools "$N8N_SESSION_COOKIE_FILE")"
        curl_args+=("-b" "$curl_cookie_file")
    fi

    local response
    N8N_API_LAST_STATUS=""
    N8N_API_LAST_BODY=""
    N8N_API_LAST_ERROR_CATEGORY=""

    if ! response=$(curl "${curl_args[@]}" 2>/dev/null); then
        log ERROR "Failed to contact n8n API endpoint $endpoint"
        return 1
    fi

    local http_status
    http_status=$(echo "$response" | tail -n1)
    N8N_API_LAST_STATUS="$http_status"
    local body_raw
    body_raw=$(echo "$response" | head -n -1)
    N8N_API_LAST_BODY="$body_raw"
    local expected_status="${N8N_API_EXPECTED_STATUS:-}"
    local expected_failure="false"
    if [[ -n "$expected_status" && "$http_status" == "$expected_status" ]]; then
        expected_failure="true"
    fi
    N8N_API_EXPECTED_STATUS=""

    local suppress_errors="${N8N_API_SUPPRESS_ERRORS:-false}"
    N8N_API_SUPPRESS_ERRORS="false"

    if [[ "$http_status" != 2* && "$http_status" != 3* ]]; then
        if [[ "$expected_failure" == "true" ]]; then
            if [[ "$verbose" == "true" && -n "$body_raw" ]]; then
                log DEBUG "n8n API request $endpoint returned expected HTTP $http_status (response: $body_raw)"
            fi
            return 1
        fi

        if [[ "$suppress_errors" == "true" ]]; then
            return 1
        fi

        local license_block="false"
        if [[ "$http_status" == "403" ]]; then
            if printf '%s' "$body_raw" | grep -qi 'plan lacks license'; then
                license_block="true"
            fi
        fi

        if [[ "$license_block" == "true" ]]; then
            N8N_API_LAST_ERROR_CATEGORY="license"
            if [[ "$verbose" == "true" && -n "$body_raw" ]]; then
                log DEBUG "n8n API response: $body_raw"
            fi
        else
            if [[ -n "$body_raw" ]]; then
                log ERROR "n8n API request failed (HTTP $http_status) for $endpoint"
                log DEBUG "n8n API response: $body_raw"
            else
                log ERROR "n8n API request failed (HTTP $http_status) for $endpoint"
            fi
        fi
        return 1
    fi

    local body
    body="$(sanitize_n8n_json_response "$body_raw")"
    N8N_API_LAST_BODY="$body"

    if [[ "$verbose" == "true" ]]; then
        local body_len preview truncated
        body_len="$(printf '%s' "$body" | wc -c | tr -d ' \n')"
        preview="$(printf '%s' "$body" | tr '\n' ' ' | head -c 200)"
        truncated=""
        if [[ "${body_len:-0}" -gt 200 ]]; then
            truncated="…"
        fi
        if [[ -n "$preview" ]]; then
            log DEBUG "n8n API request $endpoint returned ${body_len:-0} bytes (preview: ${preview}${truncated})"
        else
            log DEBUG "n8n API request $endpoint returned ${body_len:-0} bytes"
        fi
    fi

    printf '%s' "$body"
    return 0
}

test_n8n_api_connection() {
    local base_url="$1"
    local api_key="$2"

    if [[ -z "$base_url" || -z "$api_key" ]]; then
        log ERROR "Base URL and API key are required to validate n8n API access."
        return 1
    fi

    local url="${base_url%/}/rest/workflows?limit=1"
    local response
    if ! response=$(curl -s -w "\n%{http_code}" -H "X-N8N-API-KEY: $api_key" -H "Accept: application/json" "$url" 2>/dev/null); then
        log ERROR "Failed to contact n8n API at $url"
        return 1
    fi

    local http_status
    http_status=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | head -n -1)

    if [[ "$http_status" != 2* && "$http_status" != 3* ]]; then
        log ERROR "n8n API validation failed (HTTP $http_status)"
        if [[ -n "$body" ]]; then
            log DEBUG "n8n API response: $body"
        fi
        return 1
    fi

    log DEBUG "n8n API validation succeeded (HTTP $http_status)"
    return 0
}

test_n8n_session_auth() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local verbose="${4:-false}"
    
    if $verbose; then
        log INFO "Testing n8n session authentication to: $base_url"
    fi
    
    # Authenticate first
    if ! authenticate_n8n_session "$base_url" "$email" "$password" 10 false; then
        return 1
    fi
    
    # Test with a simple API call
    local response
    local http_status
    local curl_cookie_file
    curl_cookie_file="$(native_path_for_host_tools "$N8N_SESSION_COOKIE_FILE")"

    if ! response=$(curl -s -w "\n%{http_code}" -b "$curl_cookie_file" "$base_url/rest/workflows?limit=1" 2>/dev/null); then
        log ERROR "Failed to test session authentication"
        rm -f "$N8N_SESSION_COOKIE_FILE"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body
    response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" == "200" ]]; then
        if $verbose; then
            log SUCCESS "n8n session authentication successful!"
            local workflow_count
            workflow_count=$(echo "$response_body" | jq -r '.data | length // 0' 2>/dev/null || echo "0")
            log INFO "Found $workflow_count workflows accessible via session"
        fi
        return 0
    else
        if [[ -s "$N8N_SESSION_COOKIE_FILE" ]]; then
            log WARN "Session cookie ready at $N8N_SESSION_COOKIE_FILE"
            log WARN "Session cookie preview: $(head -n 2 "$N8N_SESSION_COOKIE_FILE" | tr '\r' ' ')"
        else
            log WARN "Session cookie file empty or missing: $N8N_SESSION_COOKIE_FILE"
        fi
        log WARN "Session test response (trimmed): $(printf '%s' "$response_body" | head -c 200)"
        log ERROR "Session authentication test failed with HTTP $http_status"
        rm -f "$N8N_SESSION_COOKIE_FILE"
        return 1
    fi
}

validate_n8n_api_access() {
    local base_url="$1"
    local api_key="$2"
    local email="$3"
    local password="$4"
    local container_id="$5"
    local credential_name="$6"
    local container_credentials_path="${7:-}"

    if [[ -z "$base_url" ]]; then
        log ERROR "n8n base URL is required to validate API access."
        return 1
    fi

    base_url="${base_url%/}"

    if [[ -n "$api_key" ]]; then
        if test_n8n_api_connection "$base_url" "$api_key"; then
            return 0
        fi
        log INFO "n8n API key validation failed; attempting session credential fallback"
    fi

    local attempted_credential="false"
    if [[ -n "$credential_name" ]]; then
        attempted_credential="true"
        if ensure_n8n_session_credentials "$container_id" "$credential_name" "$container_credentials_path"; then
            email="$n8n_email"
            password="$n8n_password"
        else
            if [[ -n "$email" && -n "$password" ]]; then
                log WARN "Falling back to provided n8n email/password after failing to load session credential '$credential_name'."
            else
                return 1
            fi
        fi
    fi

    if [[ -z "$email" || -z "$password" ]]; then
        if [[ "$attempted_credential" == "true" ]]; then
            log ERROR "No usable credentials available after attempting to load '$credential_name'. Configure a valid session credential or supply --n8n-email and --n8n-password."
        else
            log ERROR "Session authentication requires email/password but none are available. Configure --n8n-cred or supply --n8n-email and --n8n-password."
        fi
        return 1
    fi

    if test_n8n_session_auth "$base_url" "$email" "$password" false; then
        cleanup_n8n_session "auto"
        return 0
    fi

    cleanup_n8n_session "auto"
    return 1
}

# Fetch projects using API key authentication
fetch_n8n_projects() {
    local base_url="$1"
    local api_key="$2"

    base_url="${base_url%/}"

    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" \
        -H "X-N8N-API-KEY: $api_key" \
        -H "Accept: application/json" \
        "$base_url/rest/projects"); then
        log ERROR "Failed to fetch projects with API key authentication"
        return 1
    fi

    http_status=$(echo "$response" | tail -n1)
    local response_body
    response_body=$(echo "$response" | head -n -1)

    if [[ "$http_status" != "200" ]]; then
        log ERROR "Projects API returned HTTP $http_status when using API key"
        log DEBUG "Projects API Response Body: $response_body"
        return 1
    fi

    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Projects API (API key) success - received ${#response_body} bytes"
    echo "$response_body"
    return 0
}

# Fetch workflows (including folder metadata) using API key authentication
fetch_workflows_with_folders() {
    local base_url="$1"
    local api_key="$2"

    base_url="${base_url%/}"

    local query_url="$base_url/rest/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=1000&sortBy=updatedAt%3Adesc"

    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" \
        -H "X-N8N-API-KEY: $api_key" \
        -H "Accept: application/json" \
        "$query_url"); then
        log ERROR "Failed to fetch workflows with API key authentication"
        return 1
    fi

    http_status=$(echo "$response" | tail -n1)
    local response_body
    response_body=$(echo "$response" | head -n -1)

    if [[ "$http_status" != "200" ]]; then
        log ERROR "Workflows API returned HTTP $http_status when using API key"
        log DEBUG "Workflows API Response Body: $response_body"
        return 1
    fi

    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Workflows API (API key) success - received ${#response_body} bytes"
    echo "$response_body"
    return 0
}

# Fetch projects using session authentication (REST API)
fetch_n8n_projects_session() {
    local base_url="$1"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    local curl_cookie_file
    curl_cookie_file="$(native_path_for_host_tools "$N8N_SESSION_COOKIE_FILE")"

    if ! response=$(curl -s -w "\n%{http_code}" -b "$curl_cookie_file" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
        "$base_url/rest/projects"); then
        log ERROR "Failed to fetch projects from n8n REST API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body
    response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch projects via session (HTTP $http_status)"
        log DEBUG "Projects API Response Body: $response_body"
        return 1
    fi
    
    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Projects API Success - received ${#response_body} bytes"
    echo "$response_body"
    return 0
}

# Fetch workflows with folders using session authentication (REST API)
fetch_workflows_with_folders_session() {
    local base_url="$1"
    local project_id="$2"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    # Construct the query URL with proper parameters (URL encoded)
    local query_url="$base_url/rest/workflows?includeScopes=true&includeFolders=true"
    
    # Add project filter if provided, otherwise get all workflows
    if [[ -n "$project_id" ]]; then
        # Filter by specific project: isArchived=false, parentFolderId=0, projectId=<id>
        query_url="${query_url}&filter=%7B%22isArchived%22%3Afalse%2C%22parentFolderId%22%3A%220%22%2C%22projectId%22%3A%22${project_id}%22%7D"
    else
        # Get all non-archived workflows
        query_url="${query_url}&filter=%7B%22isArchived%22%3Afalse%7D"
    fi
    
    # Add pagination and sorting
    query_url="${query_url}&skip=0&take=1000&sortBy=updatedAt%3Adesc"
    
    local response
    local http_status
    local curl_cookie_file
    curl_cookie_file="$(native_path_for_host_tools "$N8N_SESSION_COOKIE_FILE")"

    if ! response=$(curl -s -w "\n%{http_code}" -b "$curl_cookie_file" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
        "$query_url"); then
        log ERROR "Failed to fetch workflows from n8n REST API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body
    response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch workflows with folders via session (HTTP $http_status)"
        log DEBUG "Workflows API Response Body: $response_body"
        log DEBUG "Query URL was: $query_url"
        return 1
    fi
    
    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Workflows API Success - received ${#response_body} bytes"
    echo "$response_body"
    return 0
}
