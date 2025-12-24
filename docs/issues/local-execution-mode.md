# Feature Request: Support Local Host Execution Mode with Auto-Detection

> **Status**: Proposed
> **Priority**: Enhancement
> **Labels**: `enhancement`, `feature-request`, `docker`, `architecture`

## Summary

Add support for running n8n-git directly on the same host as n8n (or inside the n8n container itself) instead of assuming Docker-based execution that requires copying files between container and host.

## Motivation

Currently, n8n-git assumes n8n is running in a Docker container and uses `docker exec` and `docker cp` commands to interact with it. This creates overhead and complexity when:

1. **Running inside the n8n container**: Users who want to install n8n-git inside their n8n container (e.g., via custom Dockerfile) to enable workflows to call n8n-git via the Execute Command node
2. **Running on the same host**: Users running n8n directly on the host without Docker containerization
3. **Automation workflows**: Users wanting to trigger git operations from within n8n workflows without needing Docker socket access

## Proposed Solution

### Auto-Detection Logic

Add auto-detection to determine execution mode by checking:

1. **Check for `n8n` command availability**: If `which n8n` succeeds, assume we're on the same host/container as n8n
2. **Environment variable override**: Allow explicit mode setting via `N8N_GIT_EXECUTION_MODE` (values: `auto`, `local`, `docker`)
3. **Fallback**: Default to current Docker-based behavior for backward compatibility

### Implementation Areas

The following functions/modules would need updates to support direct execution:

- **`dockExec()` in `lib/utils/common.sh`**: Add conditional logic to execute commands directly vs `docker exec`
- **`push_collect_workflow_exports()` in `lib/push/container_io.sh`**: Skip `docker cp` when in local mode
- **`pull_import_*` functions in `lib/pull/import.sh`**: Direct filesystem access instead of container copy
- **Configuration**: Add `N8N_EXECUTION_MODE` to `.config.example`

### Example Auto-Detection Logic

```bash
# lib/utils/common.sh

# Detect execution mode (local vs docker)
detect_execution_mode() {
    # Check for explicit override
    if [[ -n "${N8N_GIT_EXECUTION_MODE:-}" ]]; then
        echo "${N8N_GIT_EXECUTION_MODE}"
        return 0
    fi

    # Auto-detect: check if n8n command is available
    if command -v n8n &>/dev/null; then
        log INFO "Detected n8n command available - using local execution mode"
        echo "local"
        return 0
    fi

    # Default to docker mode
    echo "docker"
}

# Enhanced dockExec to support both modes
dockExec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local execution_mode="${N8N_EXECUTION_MODE:-}"

    if [[ -z "$execution_mode" ]]; then
        execution_mode=$(detect_execution_mode)
    fi

    if $is_dry_run; then
        if [[ "$execution_mode" == "local" ]]; then
            log DRYRUN "Would execute locally: $cmd"
        else
            log DRYRUN "Would execute in container $container_id: $cmd"
        fi
        return 0
    fi

    if [[ "$execution_mode" == "local" ]]; then
        log DEBUG "Executing locally: $cmd"
        eval "$cmd"
    else
        log DEBUG "Executing in container $container_id: $cmd"
        local -a exec_cmd=("docker" "exec")
        if [[ -n "${DOCKER_EXEC_USER:-}" ]]; then
            exec_cmd+=("--user" "$DOCKER_EXEC_USER")
        fi
        exec_cmd+=("$container_id" "sh" "-c" "$cmd")
        "${exec_cmd[@]}"
    fi
}
```

## Use Cases

### 1. n8n Container with Embedded n8n-git

**Dockerfile example:**
```dockerfile
FROM n8nio/n8n:latest

# Install n8n-git dependencies
RUN apk add --no-cache bash git curl jq

# Install n8n-git
RUN curl -sSL https://raw.githubusercontent.com/tcoretech/n8n-git/main/install.sh | bash

# Configure for local execution
ENV N8N_GIT_EXECUTION_MODE=local
ENV N8N_BASE_URL=http://localhost:5678

# Optional: Pre-configure git
ENV N8N_LOGIN_CREDENTIAL_NAME="N8N REST BACKUP"
ENV FOLDER_STRUCTURE=true
```

**Benefits:**
- Workflows can use Execute Command node to call `n8n-git push`, `n8n-git pull`, etc.
- Everything stays contained within the container
- No need to expose Docker socket to the container
- Simpler permission management
- Eliminates `docker cp` overhead

### 2. Direct Host Installation

For users running n8n directly on their host (not in Docker):

```bash
# Install n8n globally
npm install -g n8n

# Install n8n-git
curl -sSL https://raw.githubusercontent.com/tcoretech/n8n-git/main/install.sh | bash

# Configure
n8n-git config

# Auto-detection handles the rest
n8n-git push --workflows 2 --folder-structure
```

### 3. Workflow-Triggered Backups

**Example n8n workflow:**

```
[Schedule Trigger: Daily at 2 AM]
    ↓
[Execute Command Node]
  Command: n8n-git push --workflows 2 --credentials 1 --folder-structure --defaults
    ↓
[If Node: Check exit code]
    ├─ Success → [Slack: Backup successful]
    └─ Error → [Slack: Backup failed + logs]
```

This enables automated git backups directly from within n8n without:
- External cron jobs
- Docker socket access
- Host-level permissions

### 4. Kubernetes/Cloud-Native Deployments

In Kubernetes environments where Docker-in-Docker is discouraged:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
spec:
  template:
    spec:
      containers:
      - name: n8n
        image: custom-n8n-with-git:latest
        env:
        - name: N8N_GIT_EXECUTION_MODE
          value: "local"
        - name: N8N_BASE_URL
          value: "http://localhost:5678"
```

## Documentation Updates Needed

1. **README.md**:
   - Add "Execution Modes" section
   - Document Docker vs Local mode differences
   - Add Dockerfile example

2. **Installation Guide**:
   - Add "Installing inside n8n container" section
   - Provide pre-built Docker image option

3. **Configuration Reference** (`.config.example`):
   - Add `N8N_GIT_EXECUTION_MODE` variable
   - Document auto-detection behavior

4. **Troubleshooting**:
   - Add "Execution mode detection" section
   - Document common issues in local mode

5. **Architecture Documentation**:
   - Update `docs/ARCHITECTURE.md` with execution mode design
   - Document `dockExec()` abstraction

## Backward Compatibility

✅ **Fully backward compatible:**

- Default behavior remains unchanged (Docker mode)
- Existing configurations work without modification
- Auto-detection only activates when `n8n` command is available
- Explicit mode can be set via `N8N_GIT_EXECUTION_MODE` environment variable
- No breaking changes to CLI arguments or config file format

## Related Benefits

- **Reduced complexity**: No need for `docker cp` and temporary directories in local mode
- **Better performance**: Direct filesystem access is faster than container copy operations
- **Simplified permissions**: Avoid Docker socket permission issues
- **Cloud-native deployments**: Works better in Kubernetes/container environments
- **Smaller attack surface**: No Docker socket exposure required
- **Easier testing**: Can run tests without Docker daemon
- **Development experience**: Faster iteration during development

## Implementation Checklist

### Phase 1: Core Functionality
- [ ] Add `detect_execution_mode()` function to `lib/utils/common.sh`
- [ ] Update `dockExec()` to support local execution mode
- [ ] Add `N8N_EXECUTION_MODE` global variable and initialization
- [ ] Update `push_collect_workflow_exports()` in `lib/push/container_io.sh`
- [ ] Update docker cp operations in `lib/pull/import.sh`

### Phase 2: Configuration
- [ ] Add `N8N_GIT_EXECUTION_MODE` to `.config.example`
- [ ] Update config wizard to ask about execution mode
- [ ] Add validation for local mode requirements

### Phase 3: Documentation
- [ ] Update README.md with execution modes section
- [ ] Create Dockerfile example in `examples/` directory
- [ ] Update installation guide
- [ ] Add troubleshooting section for execution mode
- [ ] Update `docs/ARCHITECTURE.md`

### Phase 4: Testing
- [ ] Add unit tests for `detect_execution_mode()`
- [ ] Add integration tests for local mode
- [ ] Test credential decryption in local mode
- [ ] Add CI pipeline job for local mode testing
- [ ] Test in Alpine and Debian environments

### Phase 5: Polish
- [ ] Add debug logging for mode detection
- [ ] Add warning when Docker mode selected but `n8n` command available
- [ ] Add `n8n-git doctor` command to diagnose execution mode issues
- [ ] Consider renaming `dockExec()` to `executeCommand()` for clarity

## Technical Considerations

### Container Detection Edge Cases

1. **n8n command available but should use Docker mode**:
   - Solution: Explicit `N8N_GIT_EXECUTION_MODE=docker` override

2. **Multiple n8n instances (host + containers)**:
   - Solution: Config file per instance/directory
   - Document best practices

3. **Credential decryption in local mode**:
   - Current: Uses `docker exec` to access encryption key
   - Solution: Direct access to n8n's encryption key location
   - Security: Ensure same file permissions

### File Path Handling

In local mode:
- No need to copy files with `docker cp`
- Direct export to staging directory: `n8n export:workflow --all --separate --output=/staging/`
- Avoid temporary directories where possible
- Respect `LOCAL_BACKUP_PATH` for local-only storage

### Environment Variables

When running inside container, n8n's environment variables are accessible:
- `N8N_ENCRYPTION_KEY` - for credential decryption
- `N8N_USER_FOLDER` - for data directory location
- Can leverage these for better auto-detection

## Questions for Discussion

1. **Function naming**: Should we rename `dockExec()` to something more generic like `executeCommand()` to reflect both modes?

2. **Container parameter**: Should the container name/ID still be required in local mode, or should it be optional?
   - Proposal: Make it optional when `N8N_EXECUTION_MODE=local`

3. **Credential decryption**: How should we handle credential decryption in local mode?
   - Option A: Direct access to encryption key file (same as Docker mode but no `docker exec`)
   - Option B: Environment variable `N8N_ENCRYPTION_KEY`
   - Option C: Both with fallback logic

4. **Detection accuracy**: Should we do additional checks beyond `command -v n8n`?
   - Check if `n8n --version` works?
   - Check for n8n data directory?
   - Check if n8n API is reachable on localhost?

5. **Pre-built Docker image**: Should we publish a pre-built `n8nio/n8n-git:latest` image?
   - Pros: Easier adoption, official support
   - Cons: Maintenance overhead, version sync

## Success Metrics

- [ ] Zero regression in existing Docker-based deployments
- [ ] Successfully run inside n8n container
- [ ] Execute Command node workflows work correctly
- [ ] Performance improvement (measure `push` operation time)
- [ ] Reduced Docker socket permissions in production
- [ ] Positive community feedback

## References

- Current Docker execution: `lib/utils/common.sh:dockExec()` (line 2119)
- Container I/O: `lib/push/container_io.sh:push_collect_workflow_exports()` (line 8)
- Import operations: `lib/pull/import.sh`
- Architecture docs: `docs/ARCHITECTURE.md`
