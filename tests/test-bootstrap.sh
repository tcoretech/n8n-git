#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Use system temporary directory to avoid polluting the repo
# For WSL/Docker Desktop, we need a path on the Windows filesystem
if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null && command -v cmd.exe &> /dev/null; then
    WIN_TEMP=$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')
    if [[ -n "$WIN_TEMP" ]]; then
        WSL_TEMP_BASE=$(wslpath -u "$WIN_TEMP")
        TEST_TEMP_DIR=$(mktemp -d -p "$WSL_TEMP_BASE")
    else
        TEST_TEMP_DIR=$(mktemp -d)
    fi
else
    TEST_TEMP_DIR=$(mktemp -d)
fi

HOST_MOUNT_PATH="$TEST_TEMP_DIR/mount"
HOST_BACKUP_PATH="$TEST_TEMP_DIR/backup"
mkdir -p "$HOST_MOUNT_PATH" "$HOST_BACKUP_PATH"

# Fix for WSL: Docker Desktop for Windows expects Windows paths for volumes
if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null; then
    if command -v wslpath &> /dev/null; then
        HOST_MOUNT_PATH_DOCKER=$(wslpath -w "$HOST_MOUNT_PATH")
        HOST_BACKUP_PATH_DOCKER=$(wslpath -w "$HOST_BACKUP_PATH")
        # Convert backslashes to forward slashes for Docker compatibility
        HOST_MOUNT_PATH_DOCKER="${HOST_MOUNT_PATH_DOCKER//\\//}"
        HOST_BACKUP_PATH_DOCKER="${HOST_BACKUP_PATH_DOCKER//\\//}"
    else
        HOST_MOUNT_PATH_DOCKER="$HOST_MOUNT_PATH"
        HOST_BACKUP_PATH_DOCKER="$HOST_BACKUP_PATH"
    fi
else
    HOST_MOUNT_PATH_DOCKER="$HOST_MOUNT_PATH"
    HOST_BACKUP_PATH_DOCKER="$HOST_BACKUP_PATH"
fi

ROOT_DIR="${SCRIPT_DIR%/tests}"
IMAGE_NAME="n8n-git-test-embedded"
CONTAINER_NAME="n8n-git-test-container"

# Source testbed utils for logging
source "$SCRIPT_DIR/utils/common-testbed.sh"

log HEADER "n8n-git Embedded Execution Test"

cleanup() {
    log INFO "Cleaning up..."
    
    # Stop the container first to release locks
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    # Use a helper container to remove files created by root in the mounted volumes
    # This avoids permission issues on the host, especially with Docker Desktop/WSL
    if [[ -n "${HOST_MOUNT_PATH_DOCKER:-}" && -n "${HOST_BACKUP_PATH_DOCKER:-}" ]]; then
        docker run --rm \
            -v "$HOST_MOUNT_PATH_DOCKER:/clean_mount" \
            -v "$HOST_BACKUP_PATH_DOCKER:/clean_backup" \
            alpine sh -c "rm -rf /clean_mount/* /clean_mount/.* /clean_backup/* /clean_backup/.* 2>/dev/null || true" >/dev/null 2>&1 || true
    fi

    rm -rf "$TEST_TEMP_DIR"
    # Optional: remove image to save space, or keep for debugging
    # docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Build the test image with local source
log INFO "Building test Docker image from local source..."

# Generate a temporary Dockerfile based on the example, but installing from local source
DOCKERFILE_TMP="$TEST_TEMP_DIR/Dockerfile"
sed '/RUN curl -fsSL/c\
WORKDIR /usr/local/share/n8n-git\
COPY . .\
RUN find . -type f -name "*.sh" -exec sed -i "s/\\r$//" {} + && sed -i "s/\\r$//" n8n-git.sh\
RUN chmod +x install.sh && mkdir -p /usr/local/bin && ln -sf /usr/local/share/n8n-git/n8n-git.sh /usr/local/bin/n8n-git && chmod +x /usr/local/share/n8n-git/n8n-git.sh' "$ROOT_DIR/examples/Dockerfile.n8n-with-git" > "$DOCKERFILE_TMP"

# Use tar pipe to avoid Windows/WSL path issues with Docker Desktop
# We stream the current directory (project root) to docker build
# We include the generated Dockerfile in the context
cd "$ROOT_DIR"

if ! tar -czh --exclude .git --exclude .config . -C "$TEST_TEMP_DIR" Dockerfile | docker build -t "$IMAGE_NAME" -; then
    log ERROR "Failed to build test Docker image"
    exit 1
fi
log SUCCESS "Docker image built: $IMAGE_NAME"
# Ensure fixtures directory exists in the temp mount
mkdir -p "$HOST_MOUNT_PATH/workflows"

# 2. Start the container
log INFO "Starting n8n container..."
# Run standard n8n entrypoint
# Mount local fixtures for test data
if ! docker run -d \
    --name "$CONTAINER_NAME" \
    -e N8N_ENCRYPTION_KEY="test-key" \
    -v "$HOST_MOUNT_PATH_DOCKER:/tmp/git-repo" \
    -v "$HOST_BACKUP_PATH_DOCKER:/tmp/backup-repo" \
    "$IMAGE_NAME" >/dev/null; then
    log ERROR "Failed to start container"
    exit 1
fi

log INFO "Waiting for n8n to initialize..."
for i in {1..150}; do
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Editor is now accessible via"; then
        log INFO "n8n initialized"
        break
    fi
    sleep 2
    if [ "$i" -eq 150 ]; then
        log ERROR "Timeout waiting for n8n to initialize"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi
done

# 3. Setup Credentials
log INFO "Setting up n8n owner account..."
# Try to claim owner via API first (standard for fresh instance)
if docker exec "$CONTAINER_NAME" curl -s -f -X POST http://localhost:5678/rest/owner/setup \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com", "password":"SuperSecret123!", "firstName":"Admin", "lastName":"User"}' >/dev/null; then
    log SUCCESS "Owner account configured via API"
else
    log WARN "Failed to configure owner account via API (maybe already claimed?), trying CLI reset..."
    if docker exec -u node "$CONTAINER_NAME" n8n user-management:reset \
        --email "admin@example.com" \
        --password "SuperSecret123!" \
        --firstName "Admin" \
        --lastName "User" >/dev/null; then
        log SUCCESS "Owner account configured via CLI"
    else
        log ERROR "Failed to configure owner account"
        exit 1
    fi
fi

# 4. Verify n8n-git installation inside container
log INFO "Verifying n8n-git installation inside container..."
if docker exec "$CONTAINER_NAME" n8n-git --help >/dev/null; then
    log SUCCESS "n8n-git found inside container"
else
    log ERROR "n8n-git not found inside container"
    exit 1
fi

# 5. Test: Pull a workflow (simulate by creating a file first)
log INFO "Testing 'n8n-git pull' (Embedded Mode)..."

# Create a dummy workflow file in the mounted volume
cp "$SCRIPT_DIR/fixtures/workflows/bootstrap-test-workflow.json" "$HOST_MOUNT_PATH/workflows/test-workflow.json"

# Run n8n-git pull inside the container
# We use --n8n-email and --n8n-password to authenticate
log INFO "Executing: n8n-git pull --workflows 1 --local-path /tmp/git-repo --defaults --n8n-email admin@example.com --n8n-password SuperSecret123! --n8n-url http://localhost:5678"

if docker exec "$CONTAINER_NAME" n8n-git pull --workflows 1 --local-path /tmp/git-repo --defaults --n8n-email "admin@example.com" --n8n-password "SuperSecret123!" --n8n-url "http://localhost:5678"; then
    log SUCCESS "n8n-git pull executed successfully"
else
    log ERROR "n8n-git pull failed"
    docker logs "$CONTAINER_NAME"
    exit 1
fi

# 6. Test: Push a workflow
log INFO "Testing 'n8n-git push' (Embedded Mode)..."

# Create a dummy credential to ensure export works
# Note: We must provide a valid ID to avoid SQLITE_CONSTRAINT errors during import
cp "$SCRIPT_DIR/fixtures/credentials/bootstrap-credential.json" "$HOST_MOUNT_PATH/test-cred.json"
if docker exec "$CONTAINER_NAME" n8n import:credentials --input=/tmp/git-repo/test-cred.json >/dev/null 2>&1; then
    log SUCCESS "Imported test credential"
else
    log WARN "Failed to import test credential (might already exist)"
fi

# Enable credentials push (local)
log INFO "Executing: n8n-git push --workflows 1 --credentials 1 --local-path /tmp/backup-repo --defaults --n8n-email admin@example.com --n8n-password SuperSecret123! --n8n-url http://localhost:5678"
if docker exec "$CONTAINER_NAME" n8n-git push --workflows 1 --credentials 1 --local-path /tmp/backup-repo --defaults --n8n-email "admin@example.com" --n8n-password "SuperSecret123!" --n8n-url "http://localhost:5678"; then
    log SUCCESS "n8n-git push executed successfully"
else
    log ERROR "n8n-git push failed"
    exit 1
fi

# Verify the file exists in the backup repo (mounted volume)
if [ -f "$HOST_BACKUP_PATH/workflows.json" ]; then
    log SUCCESS "Backup file verified in temp directory"
    # Optional: Check content
    if grep -q "Test Workflow" "$HOST_BACKUP_PATH/workflows.json"; then
        log SUCCESS "Backup file contains expected workflow"
    else
        log ERROR "Backup file does not contain expected workflow"
        exit 1
    fi
else
    log ERROR "Backup file not found in $HOST_BACKUP_PATH"
    exit 1
fi

log SUCCESS "All embedded execution tests passed!"
