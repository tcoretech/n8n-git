#!/usr/bin/env bash
# Shared helpers for n8n integration tests.
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

TESTBED_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTBED_UTILS_DIR/common-testbed.sh"

declare -Ag TESTBED_CONTAINER_PORT_MAP=()

TESTBED_PORT_RETRY_LIMIT="${TESTBED_PORT_RETRY_LIMIT:-10}"
TESTBED_OWNER_EMAIL_DEFAULT="${TESTBED_OWNER_EMAIL_DEFAULT:-pull-tester@example.com}"
TESTBED_OWNER_PASSWORD_DEFAULT="${TESTBED_OWNER_PASSWORD_DEFAULT:-SuperSecret123!}"
TESTBED_OWNER_FIRST_DEFAULT="${TESTBED_OWNER_FIRST_DEFAULT:-Pull}"
TESTBED_OWNER_LAST_DEFAULT="${TESTBED_OWNER_LAST_DEFAULT:-Tester}"

# Wrapper for docker commands so tests can override with platform-specific wrappers.
# Define TESTBED_DOCKER_CMD to point to a function or binary (default: docker).
# shellcheck disable=SC2120 # optional arguments
testbed_docker() {
    if [[ -z "${TESTBED_DOCKER_CMD:-}" ]]; then
        if ! test_configure_docker_cli; then
            return 1
        fi
    fi

    local docker_cmd="$TESTBED_DOCKER_CMD"
    if declare -F "$docker_cmd" >/dev/null 2>&1; then
        "$docker_cmd" "$@"
    else
        "$docker_cmd" "$@"
    fi
}

testbed_resolve_port() {
    local requested_port="${1:-5678}"
    if ! test_allocate_port "$requested_port" "$TESTBED_PORT_RETRY_LIMIT"; then
        return 1
    fi
}

testbed_register_port() {
    local name="$1"
    local port="$2"
    TESTBED_CONTAINER_PORT_MAP["$name"]="$port"
}

testbed_container_port() {
    local name="$1"
    printf '%s\n' "${TESTBED_CONTAINER_PORT_MAP[$name]:-}"
}

testbed_default_owner_email() {
    printf '%s\n' "${TESTBED_OWNER_EMAIL:-$TESTBED_OWNER_EMAIL_DEFAULT}"
}

testbed_default_owner_password() {
    printf '%s\n' "${TESTBED_OWNER_PASSWORD:-$TESTBED_OWNER_PASSWORD_DEFAULT}"
}

testbed_default_owner_first() {
    printf '%s\n' "${TESTBED_OWNER_FIRST:-$TESTBED_OWNER_FIRST_DEFAULT}"
}

testbed_default_owner_last() {
    printf '%s\n' "${TESTBED_OWNER_LAST:-$TESTBED_OWNER_LAST_DEFAULT}"
}

# Resolve the bundled license patch script (path without platform translation).
testbed_license_patch_script() {
    local script="$TESTBED_UTILS_DIR/license-patch.js"
    if [[ ! -f "$script" ]]; then
        echo "[n8n-testbed] license patch script not found at $script" >&2
        return 1
    fi
    printf '%s\n' "$script"
}

# Resolve the license patch mount path for Docker (with Windows path conversion if needed).
testbed_license_patch_mount() {
    local script
    script="$(testbed_license_patch_script)"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$script"
    elif [[ "$script" == /mnt/[a-zA-Z]/?* ]] && command -v wslpath >/dev/null 2>&1; then
        wslpath -m "$script"
    elif [[ "${TESTBED_DOCKER_WINDOWS:-0}" == "1" ]] && command -v wslpath >/dev/null 2>&1; then
        wslpath -m "$script"
    else
        printf '%s\n' "$script"
    fi
}

# Start an n8n container without license patching (used for push tests).
testbed_start_container_basic() {
    local name="$1"
    local base_port="$2"
    shift 2 || true

    local attempt port_candidate
    for ((attempt=0; attempt<=TESTBED_PORT_RETRY_LIMIT; attempt++)); do
        port_candidate=$((base_port + attempt))
        if ! test_port_available "$port_candidate"; then
            continue
        fi

        if testbed_docker run -d \
            --name "$name" \
            -p "${port_candidate}:5678" \
            "$@" \
            n8nio/n8n:latest >/dev/null 2>&1
        then
            testbed_register_port "$name" "$port_candidate"
            return 0
        fi

        testbed_docker rm -f "$name" >/dev/null 2>&1 || true
    done

    local max_port=$((base_port + TESTBED_PORT_RETRY_LIMIT))
    log ERROR "Unable to start container $name on ports ${base_port}-${max_port}"
    return 1
}

# Start an n8n container with the enterprise license patch applied.
testbed_start_container_with_license_patch() {
    local name="$1"
    local base_port="$2"
    shift 2 || true

    local patch_mount
    patch_mount="$(testbed_license_patch_mount)"
    local patch_dir
    local patch_file

    patch_dir=$(dirname "$patch_mount")
    patch_file=$(basename "$patch_mount")

    if [[ -z "$patch_dir" || -z "$patch_file" ]]; then
        log ERROR "Unable to determine license patch mount path from $patch_mount"
        return 1
    fi

    local attempt port_candidate
    for ((attempt=0; attempt<=TESTBED_PORT_RETRY_LIMIT; attempt++)); do
        port_candidate=$((base_port + attempt))
        if ! test_port_available "$port_candidate"; then
            continue
        fi

        if testbed_docker run -d \
            --name "$name" \
            -p "${port_candidate}:5678" \
            -v "$patch_dir:/license-patch:ro" \
            --user root \
            --entrypoint sh \
            "$@" \
            n8nio/n8n:latest \
            -c "node '/license-patch/$patch_file' && exec su node -c '/docker-entrypoint.sh start'" >/dev/null 2>&1
        then
            testbed_register_port "$name" "$port_candidate"
            return 0
        fi

        testbed_docker rm -f "$name" >/dev/null 2>&1 || true
    done

    local max_port=$((base_port + TESTBED_PORT_RETRY_LIMIT))
    log ERROR "Unable to start container $name on ports ${base_port}-${max_port}"
    return 1
}

# Wait for a container to report healthy status via docker ps.
testbed_wait_for_container() {
    local name="$1"
    local attempts="${2:-30}"
    local interval="${3:-2}"
    local attempt

    for (( attempt=1; attempt<=attempts; attempt++ )); do
        if testbed_docker ps --filter "name=$name" --filter "status=running" --format '{{.ID}}' | grep -q .; then
            return 0
        fi
        sleep "$interval"
    done

    return 1
}

# Wait for an HTTP endpoint to return successfully.
testbed_wait_for_http() {
    local url="$1"
    local attempts="${2:-40}"
    local interval="${3:-3}"
    local attempt

    for (( attempt=1; attempt<=attempts; attempt++ )); do
        if curl -sf "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
    done

    return 1
}

# Reset or create the owner account inside the container.
testbed_reset_owner() {
    local container="$1"
    local email="$2"
    local password="$3"
    local first_name="$4"
    local last_name="$5"

    testbed_docker exec -u node "$container" \
        n8n user-management:reset \
            --email "$email" \
            --password "$password" \
            --firstName "$first_name" \
            --lastName "$last_name"
}

# Claim ownership of a fresh n8n instance via REST API.
testbed_claim_owner() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local first_name="$4"
    local last_name="$5"
    local cookie_jar="$6"

    local i
    for ((i=1; i<=10; i++)); do
        if curl -sSf \
            -c "$cookie_jar" \
            -b "$cookie_jar" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"$email\",\"password\":\"$password\",\"firstName\":\"$first_name\",\"lastName\":\"$last_name\"}" \
            "$base_url/rest/owner/setup" >/dev/null; then
            log INFO "Owner claimed successfully on attempt $i"
            return 0
        fi
        sleep 2
    done
    return 1
}

# Reset the owner account directly via the CLI and wait for the login endpoint.
testbed_prepare_owner() {
    local container="$1"
    local base_url="$2"
    local email="$3"
    local password="$4"
    local first_name="$5"
    local last_name="$6"
    local cookies="$7"

    # Force credentials inside the instance to the expected values.
    testbed_reset_owner "$container" "$email" "$password" "$first_name" "$last_name" >/dev/null 2>&1 || true

    # Wait until the login endpoint is reachable before attempting claim/login.
    local attempts=30
    local delay=2
    local i
    for ((i=1; i<=attempts; i++)); do
        if curl -sSf "$base_url/rest/login" >/dev/null 2>&1; then
            break
        fi
        sleep "$delay"
    done

    # Claim ownership to align cookies/session with provided credentials.
    testbed_claim_owner "$base_url" "$email" "$password" "$first_name" "$last_name" "$cookies"
}

# Authenticate with the n8n instance and save cookies.
testbed_login() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local cookie_jar="$4"

    # Ensure we have a cookie jar
    touch "$cookie_jar"

    # Fetch root to initialize cookies
    curl -sS -L -c "$cookie_jar" -b "$cookie_jar" "$base_url/" >/dev/null

    local login_metadata
    login_metadata=$(curl -sS -L --retry 5 --retry-delay 2 --retry-all-errors -c "$cookie_jar" -b "$cookie_jar" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Accept: application/json" \
        "$base_url/rest/login")

    local csrf_token
    csrf_token=$(jq -r '.data.csrfToken // empty' <<<"$login_metadata" || true)

    if [[ -z "$csrf_token" || "$csrf_token" == "null" ]]; then
        # If we are already logged in or something else is wrong, check if we have email
        if ! jq -e '.data.email? // empty' <<<"$login_metadata" >/dev/null; then
            echo "Failed to obtain CSRF token for login" >&2
            printf '%s\n' "$login_metadata" >&2
            return 1
        fi
        # Already logged in?
        return 0
    fi

    local login_response
    login_response=$(curl -sS --retry 5 --retry_delay 2 --retry_all_errors -f -c "$cookie_jar" \
        -b "$cookie_jar" \
        -H "Content-Type: application/json" \
        -H "Origin: $base_url" \
        -H "Referer: $base_url/login" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "X-N8N-CSRF-Token: $csrf_token" \
        -d "{\"email\":\"$email\",\"password\":\"$password\",\"rememberMe\":true}" \
        "$base_url/rest/login")

    if ! jq -e '.data != null' <<<"$login_response" >/dev/null; then
        echo "Failed to establish authenticated session" >&2
        printf '%s\n' "$login_response" >&2
        return 1
    fi
}
