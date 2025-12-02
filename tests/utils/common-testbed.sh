#!/usr/bin/env bash
# shellcheck shell=bash

TEST_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_COMMON_DIR/../.." && pwd)"

# Source main library for logging and colors
if [[ -f "$PROJECT_ROOT/lib/utils/common.sh" ]]; then
    source "$PROJECT_ROOT/lib/utils/common.sh"
else
    echo "Error: Cannot find lib/utils/common.sh at $PROJECT_ROOT/lib/utils/common.sh" >&2
    exit 1
fi

TESTBED_DOCKER_BIN="${TESTBED_DOCKER_BIN:-}"
TESTBED_DOCKER_CMD="${TESTBED_DOCKER_CMD:-}"
TESTBED_DOCKER_WINDOWS="${TESTBED_DOCKER_WINDOWS:-0}"
TESTBED_DOCKER_WRAPPER="${TESTBED_DOCKER_WRAPPER:-}"

# Toggle verbose behaviour via TEST_VERBOSE or VERBOSE_TESTS.
test_verbose_enabled() {
    [[ "${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}" != "0" ]]
}

testbed_docker_with_wrapper() {
    local wrapper="$TESTBED_DOCKER_WRAPPER"
    local docker_bin="$TESTBED_DOCKER_BIN"

    if [[ -z "$docker_bin" ]]; then
        if ! test_configure_docker_cli "$wrapper"; then
            return 1
        fi
        docker_bin="$TESTBED_DOCKER_BIN"
    fi

    if [[ -n "$wrapper" ]]; then
        "$wrapper" "$docker_bin" "$@"
    else
        "$docker_bin" "$@"
    fi
}

test_configure_docker_cli() {
    local wrapper="${1:-}"

    if [[ -z "$TESTBED_DOCKER_BIN" ]]; then
        local candidates=()
        local selected=""

        if command -v docker >/dev/null 2>&1; then
            candidates+=("$(command -v docker)")
        fi
        if command -v docker.exe >/dev/null 2>&1; then
            candidates+=("$(command -v docker.exe)")
        fi

        if ((${#candidates[@]} == 0)); then
            log ERROR "Docker CLI not found. Install Docker Desktop or ensure docker is on PATH."
            return 1
        fi

        local candidate
        for candidate in "${candidates[@]}"; do
            if "$candidate" version >/dev/null 2>&1; then
                selected="$candidate"
                break
            fi
        done

        if [[ -z "$selected" ]]; then
            log ERROR "Docker CLI detected but not functional. Verify Docker Desktop is running."
            return 1
        fi

        TESTBED_DOCKER_BIN="$selected"
    fi

    if [[ "${TESTBED_DOCKER_BIN##*/}" == "docker.exe" ]]; then
        TESTBED_DOCKER_WINDOWS=1
    else
        TESTBED_DOCKER_WINDOWS=0
    fi

    TESTBED_DOCKER_WRAPPER="$wrapper"

    if [[ -n "$wrapper" ]]; then
        TESTBED_DOCKER_CMD="testbed_docker_with_wrapper"
    else
        TESTBED_DOCKER_CMD="$TESTBED_DOCKER_BIN"
    fi

    if test_verbose_enabled; then
        log INFO "Using Docker CLI: $TESTBED_DOCKER_BIN"
    fi

    return 0
}

# Determine whether artefacts should be preserved for debugging.
test_should_keep_artifacts() {
    if [[ -n "${KEEP_TEST_ARTIFACTS:-}" ]]; then
        return 0
    fi
    if [[ -n "${SAVE_TEST_OUTPUTS:-}" ]]; then
        return 0
    fi
    if [[ "${SAVE_TEST_ARTIFACTS:-0}" != "0" ]]; then
        return 0
    fi
    return 1
}

# Convert filesystem paths for MSYS/MinGW environments.
test_convert_path_for_cli() {
    local input_path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$input_path"
    elif command -v wslpath >/dev/null 2>&1; then
        wslpath -m "$input_path"
    else
        printf '%s\n' "$input_path"
    fi
}

# Return MSYS-friendly environment overrides when running on Windows compatibility layers.
test_msys_env_overrides() {
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        printf 'MSYS_NO_PATHCONV=1\n'
        printf 'MSYS2_ARG_CONV_EXCL=*\n'
    fi
}

test_apply_msys_overrides() {
    local line key value
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        export "$key=$value"
    done < <(test_msys_env_overrides)
}

# Wrapper to run commands with MSYS environment overrides
test_run_with_msys() {
    local overrides=()
    while IFS= read -r override; do
        [[ -z "$override" ]] && continue
        overrides+=("$override")
    done < <(test_msys_env_overrides)

    if ((${#overrides[@]} > 0)); then
        env "${overrides[@]}" "$@"
    else
        "$@"
    fi
}

# Determine whether a TCP port is available for binding on localhost.
test_port_available() {
    local port="$1"

    if command -v python3 >/dev/null 2>&1; then
        if python3 - <<PY >/dev/null 2>&1
import socket
port = ${port}
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        raise SystemExit(1)
PY
        then
            return 0
        else
            return 1
        fi
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -H -tln "sport = :${port}" 2>/dev/null | grep -q .; then
            return 1
        fi
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        if lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi

    # Fallback: optimistically assume the port is free when no detection method is available.
    return 0
}

# Allocate a TCP port starting at base_port, trying up to max_offset increments.
test_allocate_port() {
    local base_port="${1:-5678}"
    local max_offset="${2:-10}"
    local attempt

    for ((attempt=0; attempt<=max_offset; attempt++)); do
        local candidate=$((base_port + attempt))
        if test_port_available "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    log ERROR "Failed to find available port starting at ${base_port} within ${max_offset} attempts"
    return 1
}
