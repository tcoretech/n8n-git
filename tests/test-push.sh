#!/usr/bin/env bash
# =========================================================
# n8n Git - Push Testing
# =========================================================
# Tests push functionality with a test n8n container

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/utils/n8n-testbed.sh"
TEST_CONTAINER="n8n-git-test"
TEST_CONTAINER_BASE_PORT=${TEST_CONTAINER_BASE_PORT:-5674}
TEST_CONTAINER_PORT=""
HOST_TMP_BASE="${TMPDIR:-/tmp}"
WINDOWS_TMP_GUESS=""
if command -v cmd.exe >/dev/null 2>&1; then
    WINDOWS_TMP_GUESS_RAW=$(cmd.exe /C "echo %TEMP%" 2>/dev/null | tr -d '\r')
    if [[ -n "$WINDOWS_TMP_GUESS_RAW" ]]; then
        WINDOWS_TMP_GUESS=$(wslpath -u "$WINDOWS_TMP_GUESS_RAW" 2>/dev/null || true)
    fi
fi
if [[ -n "$WINDOWS_TMP_GUESS" && -d "$WINDOWS_TMP_GUESS" ]]; then
    HOST_TMP_BASE="$WINDOWS_TMP_GUESS"
fi
mkdir -p "$HOST_TMP_BASE"
TEST_PUSH_DIR=$(mktemp -d "$HOST_TMP_BASE/n8n-git-push.XXXXXX")

test_apply_msys_overrides

TEST_VERBOSE=${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}

log HEADER "n8n-git Push Test"

if ! test_configure_docker_cli test_run_with_msys; then
    exit 1
fi

DOCKER_CLI_BIN="${TESTBED_DOCKER_BIN:-$(command -v docker || true)}"
if [[ -z "$DOCKER_CLI_BIN" ]]; then
    log ERROR "Docker CLI not found; cannot run push regression."
    exit 1
fi
DOCKER_CLI_DIR="$(dirname "$DOCKER_CLI_BIN")"
DOCKER_SHIM_DIR="$TEST_PUSH_DIR/docker-shims"
create_docker_shim() {
    local shim_name="$1"
    local target_bin="$2"
    local shim_path="$DOCKER_SHIM_DIR/$shim_name"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -Eeuo pipefail'
        while IFS= read -r override; do
            [[ -z "$override" ]] && continue
            printf 'export %s\n' "$override"
        done < <(test_msys_env_overrides)
        printf 'TARGET_BIN="%s"\n' "$target_bin"
        cat <<'EOF'
convert_host_path() {
    local candidate="$1"
    if [[ "$candidate" == /* && "$candidate" != *:* ]]; then
        if command -v wslpath >/dev/null 2>&1; then
            if converted=$(wslpath -w "$candidate" 2>/dev/null); then
                printf '%s\n' "$converted"
                return
            fi
        fi
    fi
    printf '%s\n' "$candidate"
}

args=()
for param in "$@"; do
    args+=("$(convert_host_path "$param")")
done
exec "$TARGET_BIN" "${args[@]}"
EOF
    } >"$shim_path"
    chmod +x "$shim_path"
}

log_verbose_mode() {
    if test_verbose_enabled; then
        log INFO "Running n8n-git.sh invocations with --verbose enabled"
    fi
}

generate_test_version_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    fi
}

# Cleanup function
cleanup() {
    log INFO "Cleaning up test environment..."
    testbed_docker stop "$TEST_CONTAINER" >/dev/null 2>&1 || true
    testbed_docker rm "$TEST_CONTAINER" >/dev/null 2>&1 || true
    if test_should_keep_artifacts; then
        log INFO "Preserving test artifacts in $TEST_PUSH_DIR"
    else
        rm -rf "$TEST_PUSH_DIR"
    fi
}

# Trap cleanup on exit
trap cleanup EXIT

# Start test
log INFO "Starting n8n Git push/restore test suite"
log_verbose_mode

# Clean any previous test artifacts
cleanup
mkdir -p "$TEST_PUSH_DIR"
mkdir -p "$DOCKER_SHIM_DIR"
create_docker_shim docker "$DOCKER_CLI_BIN"
if [[ -x "$DOCKER_CLI_DIR/docker-compose.exe" ]]; then
    create_docker_shim docker-compose "$DOCKER_CLI_DIR/docker-compose.exe"
fi

run_n8n_git_cli() {
    PATH="$DOCKER_SHIM_DIR:$PATH" TMPDIR="$HOST_TMP_BASE" test_run_with_msys bash "$PROJECT_ROOT/n8n-git.sh" "$@"
}

# 1. Start n8n test container
log INFO "Starting n8n test container..."
if ! testbed_start_container_basic "$TEST_CONTAINER" "$TEST_CONTAINER_BASE_PORT" -e N8N_BASIC_AUTH_ACTIVE=false; then
    log ERROR "Failed to start n8n container"
    exit 1
fi

TEST_CONTAINER_PORT="$(testbed_container_port "$TEST_CONTAINER")"
if [[ -z "$TEST_CONTAINER_PORT" ]]; then
    log ERROR "Failed to determine exposed container port"
    exit 1
fi

log INFO "Waiting for n8n to be ready..."
if ! testbed_wait_for_container "$TEST_CONTAINER" 30 2; then
    log ERROR "n8n container not running"
    exit 1
fi
log INFO "n8n container is running"

# Wait for the HTTP interface to become responsive before running CLI commands.
log INFO "Waiting for n8n HTTP endpoint..."
if ! testbed_wait_for_http "http://localhost:${TEST_CONTAINER_PORT}/healthz" 40 3; then
    log ERROR "n8n HTTP endpoint not responding"
    exit 1
fi
log INFO "n8n HTTP endpoint is responsive"

# 2. Create test workflow in container
log INFO "Creating test workflow..."
TEST_WORKFLOW_VERSION_ID="$(generate_test_version_id)"
if [[ -z "$TEST_WORKFLOW_VERSION_ID" ]]; then
    log ERROR "Failed to generate versionId for test workflow"
    exit 1
fi
TEST_WORKFLOW=$(sed "s/PLACEHOLDER_VERSION_ID/$TEST_WORKFLOW_VERSION_ID/" "$SCRIPT_DIR/fixtures/workflows/push-workflow-template.json")

TEMP_WORKFLOW=$(testbed_docker exec "$TEST_CONTAINER" mktemp -p /tmp)
testbed_docker exec "$TEST_CONTAINER" sh -c "cat <<'EOF' > $TEMP_WORKFLOW
$TEST_WORKFLOW
EOF"
testbed_docker exec "$TEST_CONTAINER" n8n import:workflow --input "$TEMP_WORKFLOW" >/dev/null 2>&1 || {
    log ERROR "Failed to import test workflow"
    exit 1
}
log INFO "Test workflow created"

# 3. Create test credential in container
log INFO "Creating test credential..."
TEST_CREDENTIAL=$(cat "$SCRIPT_DIR/fixtures/credentials/push-credential.json")

TEMP_CREDENTIAL=$(testbed_docker exec "$TEST_CONTAINER" mktemp -p /tmp)
testbed_docker exec "$TEST_CONTAINER" sh -c "cat <<'EOF' > $TEMP_CREDENTIAL
$TEST_CREDENTIAL
EOF"
testbed_docker exec "$TEST_CONTAINER" n8n import:credentials --input "$TEMP_CREDENTIAL" --decrypted >/dev/null || {
    log ERROR "Failed to import test credential"
    exit 1
}
log INFO "Test credential created"

# 4. Run encrypted push via n8n-git.sh
ENCRYPTED_PUSH_DIR="$TEST_PUSH_DIR/local-encrypted"
mkdir -p "$ENCRYPTED_PUSH_DIR"

log INFO "Running encrypted push..."
ENCRYPTED_PUSH_LOG="$TEST_PUSH_DIR/push_encrypted.log"
CLI_VERBOSE_FLAGS=()
if test_verbose_enabled; then
    CLI_VERBOSE_FLAGS+=(--verbose)
fi

    if ! run_n8n_git_cli push \
        --container "$TEST_CONTAINER" \
        --local-path "$ENCRYPTED_PUSH_DIR" \
        --workflows 1 \
        --credentials 1 \
        --environment 0 \
        --config /dev/null \
        --defaults \
        "${CLI_VERBOSE_FLAGS[@]}" \
        >"$ENCRYPTED_PUSH_LOG" 2>&1; then
        log ERROR "Encrypted push run failed"
        cat "$ENCRYPTED_PUSH_LOG"
        exit 1
    fi

log SUCCESS "Encrypted push completed"

ENCRYPTED_WORKFLOW_JSON="$ENCRYPTED_PUSH_DIR/workflows.json"
ENCRYPTED_CREDENTIALS_DIR="$ENCRYPTED_PUSH_DIR/.credentials"

if [[ ! -s "$ENCRYPTED_WORKFLOW_JSON" ]]; then
    log ERROR "Encrypted workflow push missing"
    exit 1
fi
if [[ ! -d "$ENCRYPTED_CREDENTIALS_DIR" ]]; then
    log ERROR "Encrypted credential directory missing"
    exit 1
fi

mapfile -d '' -t ENCRYPTED_CREDENTIAL_FILES < <(find "$ENCRYPTED_CREDENTIALS_DIR" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
if ((${#ENCRYPTED_CREDENTIAL_FILES[@]} == 0)); then
    log ERROR "Encrypted credential directory is empty"
    exit 1
fi

if ! jq empty "$ENCRYPTED_WORKFLOW_JSON" >/dev/null 2>"$TEST_PUSH_DIR/workflows_jq_error.log"; then
    jq_error=$(<"$TEST_PUSH_DIR/workflows_jq_error.log")
    log ERROR "Encrypted workflow JSON is invalid"
    [[ -n "$jq_error" ]] && log ERROR "$jq_error"
    exit 1
fi
rm -f "$TEST_PUSH_DIR/workflows_jq_error.log" 2>/dev/null || true
log SUCCESS "Encrypted workflow JSON is valid"

for cred_file in "${ENCRYPTED_CREDENTIAL_FILES[@]}"; do
    if ! jq empty "$cred_file" >/dev/null 2>"$TEST_PUSH_DIR/credentials_jq_error.log"; then
        cred_error=$(<"$TEST_PUSH_DIR/credentials_jq_error.log")
        log ERROR "Encrypted credential JSON is invalid ($cred_file)"
        [[ -n "$cred_error" ]] && log ERROR "$cred_error"
        exit 1
    fi
done
rm -f "$TEST_PUSH_DIR/credentials_jq_error.log" 2>/dev/null || true

ENCRYPTED_BUNDLE_PATH="$TEST_PUSH_DIR/encrypted_credentials_bundle.json"
if ! jq -s '.' "${ENCRYPTED_CREDENTIAL_FILES[@]}" >"$ENCRYPTED_BUNDLE_PATH" 2>"$TEST_PUSH_DIR/credentials_bundle_error.log"; then
    bundle_error=$(<"$TEST_PUSH_DIR/credentials_bundle_error.log")
    log ERROR "Failed to assemble encrypted credential bundle"
    [[ -n "$bundle_error" ]] && log ERROR "$bundle_error"
    exit 1
fi
rm -f "$TEST_PUSH_DIR/credentials_bundle_error.log" 2>/dev/null || true

if grep -R "test-password" "$ENCRYPTED_CREDENTIALS_DIR" >/dev/null 2>&1; then
    log ERROR "Encrypted credential push contains plaintext password"
    exit 1
fi
log SUCCESS "Encrypted credential JSON passes validation"

# 5. Run decrypted push via n8n-git.sh
DECRYPTED_PUSH_DIR="$TEST_PUSH_DIR/local-decrypted"
mkdir -p "$DECRYPTED_PUSH_DIR"

log INFO "Running decrypted push"
DECRYPTED_PUSH_LOG="$TEST_PUSH_DIR/push_decrypted.log"
if ! run_n8n_git_cli push \
    --container "$TEST_CONTAINER" \
    --workflows 1 \
    --credentials 1 \
    --environment 0 \
    --local-path "$DECRYPTED_PUSH_DIR" \
    --config /dev/null \
    --decrypt true \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    >"$DECRYPTED_PUSH_LOG" 2>&1; then
    log ERROR "Decrypted push run failed"
    log ERROR "See $DECRYPTED_PUSH_LOG for details"
    exit 1
fi
log SUCCESS "Decrypted push completed"

DECRYPTED_WORKFLOW_JSON="$DECRYPTED_PUSH_DIR/workflows.json"
DECRYPTED_CREDENTIALS_DIR="$DECRYPTED_PUSH_DIR/.credentials"

if [[ ! -s "$DECRYPTED_WORKFLOW_JSON" ]]; then
    log ERROR "Decrypted workflow push missing"
    exit 1
fi
if [[ ! -d "$DECRYPTED_CREDENTIALS_DIR" ]]; then
    log ERROR "Decrypted credential directory missing"
    exit 1
fi

mapfile -t DECRYPTED_CREDENTIAL_FILES < <(find "$DECRYPTED_CREDENTIALS_DIR" -maxdepth 1 -type f -name '*.json' | sort)
if ((${#DECRYPTED_CREDENTIAL_FILES[@]} == 0)); then
    log ERROR "Decrypted credential directory is empty"
    exit 1
fi

if ! jq empty "$DECRYPTED_WORKFLOW_JSON" >/dev/null 2>"$TEST_PUSH_DIR/decrypted_workflows_jq_error.log"; then
    jq_error=$(<"$TEST_PUSH_DIR/decrypted_workflows_jq_error.log")
    log ERROR "Decrypted workflow JSON is invalid"
    [[ -n "$jq_error" ]] && log ERROR "$jq_error"
    exit 1
fi
rm -f "$TEST_PUSH_DIR/decrypted_workflows_jq_error.log" 2>/dev/null || true

for cred_file in "${DECRYPTED_CREDENTIAL_FILES[@]}"; do
    if ! jq empty "$cred_file" >/dev/null 2>"$TEST_PUSH_DIR/decrypted_credentials_jq_error.log"; then
        cred_error=$(<"$TEST_PUSH_DIR/decrypted_credentials_jq_error.log")
        log ERROR "Decrypted credential JSON is invalid ($cred_file)"
        [[ -n "$cred_error" ]] && log ERROR "$cred_error"
        exit 1
    fi
done
rm -f "$TEST_PUSH_DIR/decrypted_credentials_jq_error.log" 2>/dev/null || true

DECRYPTED_BUNDLE_PATH="$TEST_PUSH_DIR/decrypted_credentials_bundle.json"
if ! jq -s '.' "${DECRYPTED_CREDENTIAL_FILES[@]}" >"$DECRYPTED_BUNDLE_PATH" 2>"$TEST_PUSH_DIR/decrypted_credentials_bundle_error.log"; then
    bundle_error=$(<"$TEST_PUSH_DIR/decrypted_credentials_bundle_error.log")
    log ERROR "Failed to assemble decrypted credential bundle"
    [[ -n "$bundle_error" ]] && log ERROR "$bundle_error"
    exit 1
fi
rm -f "$TEST_PUSH_DIR/decrypted_credentials_bundle_error.log" 2>/dev/null || true

DECRYPTED_USER=$(jq -r '.[0].data.user // empty' "$DECRYPTED_BUNDLE_PATH" || true)
DECRYPTED_PASSWORD=$(jq -r '.[0].data.password // empty' "$DECRYPTED_BUNDLE_PATH" || true)
if [[ "$DECRYPTED_USER" != "test-user" || "$DECRYPTED_PASSWORD" != "test-password" ]]; then
    log ERROR "Decrypted credential contents did not match expected values"
    exit 1
fi
log SUCCESS "Decrypted credential JSON contains expected values"

# 6. Test workflow restore using encrypted push
log INFO "Testing workflow restore from encrypted push..."

TEMP_RESTORE_WORKFLOWS="/tmp/workflows-restore.json"
testbed_docker exec "$TEST_CONTAINER" rm -f "$TEMP_RESTORE_WORKFLOWS" >/dev/null 2>&1 || true
RESTORE_WORKFLOW_LOG="$TEST_PUSH_DIR/restore_workflow.log"

WORKFLOW_JSON_DOCKER_PATH=$(test_convert_path_for_cli "$ENCRYPTED_WORKFLOW_JSON")
if ! testbed_docker cp "${WORKFLOW_JSON_DOCKER_PATH}" "$TEST_CONTAINER:$TEMP_RESTORE_WORKFLOWS" >/dev/null 2>&1; then
    log ERROR "Failed to copy encrypted workflow push into container"
    exit 1
fi

if ! testbed_docker exec --user root "$TEST_CONTAINER" chmod 644 "$TEMP_RESTORE_WORKFLOWS" >/dev/null 2>&1; then
    log ERROR "Failed to set readable permissions on workflow restore artifact"
    exit 1
fi

log SUCCESS "Encrypted workflow copied into container"

if ! testbed_docker exec "$TEST_CONTAINER" n8n import:workflow --input "$TEMP_RESTORE_WORKFLOWS" >"$RESTORE_WORKFLOW_LOG" 2>&1; then
    log ERROR "Failed to restore workflows from encrypted push"
    if [[ -s "$RESTORE_WORKFLOW_LOG" ]]; then
        while IFS= read -r line; do
            log ERROR "$line"
        done <"$RESTORE_WORKFLOW_LOG"
    fi
    exit 1
fi


log HEADER "Push Test Summary"
TEMP_VERIFY=$(testbed_docker exec "$TEST_CONTAINER" mktemp -p /tmp)
testbed_docker exec "$TEST_CONTAINER" n8n export:workflow --all --output "$TEMP_VERIFY" >/dev/null 2>&1
WORKFLOW_COUNT=$(testbed_docker exec "$TEST_CONTAINER" jq 'length' "$TEMP_VERIFY")

if [ "$WORKFLOW_COUNT" -lt 1 ]; then
    log ERROR "No workflows found after restore"
    exit 1
fi
log INFO "Verified $WORKFLOW_COUNT workflow(s) after restore"
log SUCCESS "All push tests passed"

exit 0
