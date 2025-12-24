# Implementation Plan: Local n8n CLI Execution Support

**Status**: Approved - Ready for Implementation
**Created**: 2024-12-24
**Updated**: 2024-12-24 (Simplified based on stakeholder feedback)
**Target Version**: 1.5.0 (Minor update - backward compatible)
**Estimated Effort**: 20-30 hours

---

## Executive Summary

Enable n8n-git to execute n8n CLI commands directly when running on the same host as n8n (or inside the n8n container), while maintaining full backward compatibility with Docker-based execution. This is achieved through intelligent container parameter detection and a unified execution abstraction.

### Key Principle
**This is NOT a new "mode" - it's simply smart execution**: If a container is specified, use it. If not, try local n8n CLI. If neither works, prompt interactively.

### Key Metrics
- **Files Modified**: 6-8 core files
- **Functions Affected**: 33 `dockExec()` calls renamed to `n8n_exec()`
- **Docker cp Operations**: 16 operations updated to support both paths
- **New Config Variables**: 0 (no new configuration needed!)
- **Backward Compatibility**: 100% (existing configs work unchanged)
- **Performance Gain**: 30-50% faster in local execution

---

## Table of Contents

1. [Simplified Design](#1-simplified-design)
2. [Implementation Phases](#2-implementation-phases)
3. [Technical Specifications](#3-technical-specifications)
4. [Testing Strategy](#4-testing-strategy)
5. [Documentation Updates](#5-documentation-updates)
6. [Migration Guide](#6-migration-guide)
7. [Success Criteria](#7-success-criteria)

---

## 1. Simplified Design

### 1.1 Execution Logic

**Simple Container Detection Flow**:

```
┌─────────────────────────────────────┐
│ Is --container parameter set?       │
└────┬─────────────────────────┬──────┘
     │ YES                     │ NO
     ▼                         ▼
┌──────────────────┐    ┌──────────────────────┐
│ Use Docker       │    │ Try local n8n CLI     │
│ Validate exists  │    │ command -v n8n        │
│ Fail if missing  │    └────┬────────────┬─────┘
└──────────────────┘         │ Found      │ Not found
                             ▼            ▼
                      ┌─────────────┐  ┌──────────────────┐
                      │ Execute     │  │ Interactive      │
                      │ Locally     │  │ Container Select │
                      └─────────────┘  │ (with warning)   │
                                       └──────────────────┘
```

**Execution determination**:
```bash
# Pseudo-code
if container_id is set:
    execution = "docker"  # Use docker exec
    validate_container(container_id)  # Fail if doesn't exist
else:
    if command -v n8n exists:
        execution = "local"  # Direct execution
    else:
        if interactive:
            warn "n8n CLI not found locally"
            execution = "docker"
            container_id = select_container()  # Interactive selection
        else:
            error "Neither --container specified nor n8n CLI available"
```

### 1.2 Core Function: n8n_exec()

**Renamed from `dockExec()` to `n8n_exec()` for clarity**:

```bash
n8n_exec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3

    if $is_dry_run; then
        if [[ -z "$container_id" ]]; then
            log DRYRUN "Would execute locally: $cmd"
        else
            log DRYRUN "Would execute in container $container_id: $cmd"
        fi
        return 0
    fi

    # Execute based on whether container is set
    if [[ -z "$container_id" ]]; then
        # Local execution
        log DEBUG "Executing locally: $cmd"
        eval "$cmd"
    else
        # Docker execution
        log DEBUG "Executing in container $container_id: $cmd"
        local -a exec_cmd=("docker" "exec")
        if [[ -n "${DOCKER_EXEC_USER:-}" ]]; then
            exec_cmd+=("--user" "$DOCKER_EXEC_USER")
        fi
        exec_cmd+=("$container_id" "sh" "-c" "$cmd")
        "${exec_cmd[@]}"
    fi
}

# Also rename dockExecAsRoot → n8n_exec_root
n8n_exec_root() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3

    if $is_dry_run; then
        if [[ -z "$container_id" ]]; then
            log DRYRUN "Would execute locally as root: $cmd"
        else
            log DRYRUN "Would execute in container $container_id as root: $cmd"
        fi
        return 0
    fi

    if [[ -z "$container_id" ]]; then
        # Local execution with sudo
        log DEBUG "Executing locally with sudo: $cmd"
        sudo sh -c "$cmd"
    else
        # Docker execution as root
        log DEBUG "Executing in container $container_id as root: $cmd"
        docker exec --user root "$container_id" sh -c "$cmd"
    fi
}
```

### 1.3 File Operations

**Helper functions for file copy abstraction**:

```bash
copy_from_n8n() {
    local source_path="$1"
    local dest_path="$2"
    local container_id="${3:-}"

    if [[ -z "$container_id" ]]; then
        # Local copy
        log DEBUG "Copying locally: $source_path → $dest_path"
        cp "$source_path" "$dest_path"
    else
        # Docker copy
        log DEBUG "Copying from container: $container_id:$source_path → $dest_path"
        local docker_cp_dest
        docker_cp_dest=$(convert_path_for_docker_cp "$dest_path")
        [[ -z "$docker_cp_dest" ]] && docker_cp_dest="$dest_path"
        docker cp "${container_id}:${source_path}" "$docker_cp_dest"
    fi
}

copy_to_n8n() {
    local source_path="$1"
    local dest_path="$2"
    local container_id="${3:-}"

    if [[ -z "$container_id" ]]; then
        # Local copy
        log DEBUG "Copying locally: $source_path → $dest_path"
        cp "$source_path" "$dest_path"
    else
        # Docker copy
        log DEBUG "Copying to container: $source_path → $container_id:$dest_path"
        local docker_cp_source
        docker_cp_source=$(convert_path_for_docker_cp "$source_path")
        [[ -z "$docker_cp_source" ]] && docker_cp_source="$source_path"
        docker cp "$docker_cp_source" "${container_id}:${dest_path}"
    fi
}
```

### 1.4 No Configuration Changes

**Key point**: No new configuration variables needed!

- Existing `N8N_CONTAINER` config works as before
- CLI `--container` argument works as before
- If neither set, local execution is attempted automatically
- Falls back to interactive selection if needed

---

## 2. Implementation Phases

### Phase 1: Core Execution Abstraction (Week 1)

**Estimated Effort**: 12-16 hours

**Deliverables**:
- [ ] Rename `dockExec()` to `n8n_exec()` in `lib/utils/common.sh`
- [ ] Rename `dockExecAsRoot()` to `n8n_exec_root()`
- [ ] Update function to detect container_id presence
- [ ] Add local n8n CLI execution path
- [ ] Create `copy_from_n8n()` and `copy_to_n8n()` helpers
- [ ] Update all 33 call sites across 6 files

**Files Modified**:
- `lib/utils/common.sh` - Core function implementation
- `lib/push/export.sh` - Update 7 calls
- `lib/push/container_io.sh` - Update 2 calls
- `lib/pull/import.sh` - Update 12 calls
- `lib/pull/staging.sh` - Update 2 calls
- `lib/n8n/auth.sh` - Update 4 calls
- `lib/n8n/snapshot.sh` - Update 2 calls (if separate from auth)

**Call Site Update Pattern**:

```bash
# Before
dockExec "$container_id" "n8n export:workflow --all --output=/tmp/workflows.json" false

# After (same call, just renamed function)
n8n_exec "$container_id" "n8n export:workflow --all --output=/tmp/workflows.json" false
```

**Acceptance Criteria**:
- All tests pass with existing docker-based configs
- Local execution works when container_id is empty string or unset
- No functional changes, just renamed functions

---

### Phase 2: Container Detection & Validation (Week 2)

**Estimated Effort**: 6-8 hours

**Deliverables**:
- [ ] Update container validation in `n8n-git.sh`
- [ ] Make container parameter truly optional
- [ ] Add n8n CLI availability check
- [ ] Update interactive container selection with warning
- [ ] Add helpful error messages for missing prerequisites

**Files Modified**:
- `n8n-git.sh` - Main script validation logic

**Container Validation Logic**:

```bash
# In n8n-git.sh

# Determine execution approach
if [[ -n "$container" ]]; then
    # Container explicitly specified - validate it exists
    log DEBUG "Container specified: $container"
    container=$(echo "$container" | tr -d '\n\r' | xargs)
    found_id=$(docker ps -q --filter "id=$container" | head -n 1)
    if [ -z "$found_id" ]; then
        found_id=$(docker ps -q --filter "name=$container" | head -n 1)
    fi
    if [ -z "$found_id" ]; then
        log ERROR "Specified container '$container' not found or not running."
        log INFO "Use 'docker ps' to see available running containers."
        exit 1
    fi
    container=$found_id
    log DEBUG "Using Docker execution with container: $container"
else
    # No container specified - try local n8n CLI
    if command -v n8n &>/dev/null; then
        log DEBUG "n8n CLI detected - using local execution"
        container=""  # Explicitly empty for local execution
    else
        # n8n CLI not available - need to select container
        if [[ "$stdin_is_tty" == "true" && "$assume_defaults" != "true" ]]; then
            log WARN "n8n CLI not found locally and no container specified"
            log INFO "Please select an n8n container for Docker execution:"
            select_container
            container="$SELECTED_CONTAINER_ID"
            log DEBUG "Using Docker execution with container: $container"
        else
            log ERROR "Cannot determine execution method:"
            log ERROR "  - No --container specified"
            log ERROR "  - n8n CLI command not found"
            log ERROR "  - Not running interactively (cannot prompt)"
            log INFO ""
            log INFO "Solutions:"
            log INFO "  1. Specify container: --container <id|name>"
            log INFO "  2. Install n8n CLI: npm install -g n8n"
            exit 1
        fi
    fi
fi
```

**Acceptance Criteria**:
- Explicit container parameter validated and used
- Local n8n CLI detected and used when no container specified
- Interactive fallback works with helpful warning
- Clear error messages guide users to resolution

---

### Phase 3: File Operations Update (Week 2-3)

**Estimated Effort**: 8-10 hours

**Deliverables**:
- [ ] Update all `docker cp` operations to use helper functions
- [ ] Handle path resolution for both local and docker execution
- [ ] Update push operations (7 docker cp calls)
- [ ] Update pull operations (4 docker cp calls)
- [ ] Update auth operations (2 docker cp calls)
- [ ] Update snapshot operations (1 docker cp call)

**Files Modified**:
- `lib/push/export.sh` - 7 docker cp operations
- `lib/push/container_io.sh` - 1 docker cp operation
- `lib/pull/import.sh` - 3 docker cp operations
- `lib/pull/staging.sh` - 1 docker cp operation
- `lib/n8n/auth.sh` - 2 docker cp operations
- `lib/n8n/snapshot.sh` - 1 docker cp operation

**Update Pattern**:

```bash
# Before
docker cp "${container_id}:/tmp/workflows.json" "$local_path"

# After
copy_from_n8n "/tmp/workflows.json" "$local_path" "$container_id"
```

**Path Handling**:

```bash
# For local execution, we can use the same temp paths
# n8n CLI will create files in the same locations:

# Docker: docker exec container "n8n export:workflow --output=/tmp/workflows.json"
#         docker cp container:/tmp/workflows.json ./local.json

# Local:  n8n export:workflow --output=/tmp/workflows.json
#         cp /tmp/workflows.json ./local.json

# OR for cleaner local execution:

# Local:  n8n export:workflow --output=./local.json
#         (no copy needed if we export directly to destination)
```

**Acceptance Criteria**:
- All docker cp operations work in both contexts
- File permissions preserved (600/700 as appropriate)
- Temporary files cleaned up properly
- Push/pull operations complete successfully

---

### Phase 4: Documentation Updates (Week 3)

**Estimated Effort**: 4-6 hours

**Deliverables**:
- [ ] Update README.md with local execution explanation
- [ ] Update ARCHITECTURE.md with n8n_exec() design
- [ ] Enhance examples/Dockerfile.n8n-with-git
- [ ] Update examples/README.md with embedded usage
- [ ] Add troubleshooting section for local execution

**Files Modified**:
- `README.md`
- `docs/ARCHITECTURE.md`
- `examples/README.md`

**Documentation Additions**:

**README.md**:
```markdown
## Installation

### Prerequisites

n8n-git can run in two ways:

1. **With local n8n CLI** - If you have n8n installed locally:
   ```bash
   npm install -g n8n
   # n8n-git will automatically use the local CLI
   ```

2. **With Docker container** - If n8n runs in Docker:
   ```bash
   docker run -d --name n8n -p 5678:5678 n8nio/n8n
   # Specify container with --container flag
   n8n-git push --container n8n
   ```

3. **Embedded in n8n container** - Install n8n-git inside your n8n container:
   ```dockerfile
   FROM n8nio/n8n:latest
   RUN apk add --no-cache bash git curl jq
   RUN curl -sSL https://raw.githubusercontent.com/tcoretech/n8n-git/main/install.sh | bash
   ```
   ```bash
   # From inside container, n8n-git automatically uses local CLI
   n8n-git push --workflows 2
   ```

The tool automatically detects the best execution method. No configuration needed!
```

**ARCHITECTURE.md**:
```markdown
## Execution Abstraction

### n8n_exec() Function

The core `n8n_exec()` function (formerly `dockExec()`) provides transparent execution
of n8n CLI commands regardless of environment:

- **Container specified**: Uses `docker exec` to run commands in container
- **No container specified**: Attempts direct execution of n8n CLI on host
- **Neither available**: Interactive container selection (if TTY)

This is not a "mode" - it's intelligent execution path selection based on available
resources and user input.

```bash
n8n_exec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3

    if [[ -z "$container_id" ]]; then
        eval "$cmd"  # Local execution
    else
        docker exec "$container_id" sh -c "$cmd"  # Container execution
    fi
}
```

File operations follow the same pattern via `copy_from_n8n()` and `copy_to_n8n()`
helper functions.
```

**Acceptance Criteria**:
- Installation instructions clear for all scenarios
- Architecture documentation accurate
- Examples work as documented
- Troubleshooting covers common issues

---

### Phase 5: Testing (Week 3-4)

**Estimated Effort**: 8-10 hours

**Deliverables**:
- [ ] Update existing tests to work with renamed functions
- [ ] Add local execution test scenarios
- [ ] Test embedded container scenario
- [ ] Test regression (existing docker-based usage)
- [ ] Performance benchmarks

**Test Scenarios**:

1. **Existing Docker Usage** (Regression):
   ```bash
   # With container specified
   N8N_CONTAINER="n8n-test" ./tests/test-push.sh
   ```

2. **Local n8n CLI**:
   ```bash
   # Install n8n locally
   npm install -g n8n
   # Start n8n
   n8n start &
   # Test without container
   ./tests/test-push.sh
   ```

3. **Embedded Container**:
   ```bash
   # Build test image
   docker build -f examples/Dockerfile.n8n-with-git -t n8n-test .
   # Test from inside
   docker exec n8n-test n8n-git push --dry-run --workflows 2
   ```

**Test Updates**:

All test files need to use new function names:
- `tests/test-push.sh`
- `tests/test-pull.sh`
- `tests/test-reset.sh`
- Any other test files

**Performance Benchmark**:

```bash
#!/bin/bash
# benchmark.sh

echo "=== Docker Execution Benchmark ==="
time (
    docker run -d --name n8n-bench n8nio/n8n
    sleep 5
    n8n-git push --container n8n-bench --workflows 2 --dry-run
    docker rm -f n8n-bench
)

echo ""
echo "=== Local Execution Benchmark ==="
time (
    n8n-git push --workflows 2 --dry-run
)
```

**Acceptance Criteria**:
- All existing tests pass with docker execution
- New tests pass with local execution
- Embedded container scenario works
- Local execution is 30-50% faster (measured)
- No regression in docker mode performance

---

## 3. Technical Specifications

### 3.1 Function Signatures

**n8n_exec()**:
```bash
n8n_exec() {
    local container_id="$1"      # Optional: Container ID/name, empty for local
    local cmd="$2"               # Required: Command to execute
    local is_dry_run=$3          # Required: true/false for dry-run mode

    # Returns: Exit code of executed command
}
```

**n8n_exec_root()**:
```bash
n8n_exec_root() {
    local container_id="$1"      # Optional: Container ID/name, empty for local
    local cmd="$2"               # Required: Command to execute
    local is_dry_run=$3          # Required: true/false for dry-run mode

    # Returns: Exit code of executed command
    # Note: Uses sudo for local execution, --user root for docker
}
```

**copy_from_n8n()**:
```bash
copy_from_n8n() {
    local source_path="$1"       # Required: Source path (absolute)
    local dest_path="$2"         # Required: Destination path (absolute)
    local container_id="${3:-}"  # Optional: Container ID/name

    # Returns: 0 on success, 1 on failure
}
```

**copy_to_n8n()**:
```bash
copy_to_n8n() {
    local source_path="$1"       # Required: Source path (absolute)
    local dest_path="$2"         # Required: Destination path (absolute)
    local container_id="${3:-}"  # Optional: Container ID/name

    # Returns: 0 on success, 1 on failure
}
```

### 3.2 Container Detection

```bash
# Execution determination logic
determine_execution_context() {
    if [[ -n "${container_id:-}" ]]; then
        # Container explicitly set
        echo "docker"
    elif command -v n8n &>/dev/null; then
        # n8n CLI available locally
        echo "local"
    else
        # Neither available
        echo "unknown"
    fi
}
```

### 3.3 Error Handling

**Missing Prerequisites**:
```bash
if [[ -z "$container_id" ]] && ! command -v n8n &>/dev/null; then
    log ERROR "Cannot execute n8n commands:"
    log ERROR "  - No container specified (--container)"
    log ERROR "  - n8n CLI not available locally"
    log INFO ""
    log INFO "Solutions:"
    log INFO "  1. Install n8n: npm install -g n8n"
    log INFO "  2. Specify container: --container <id|name>"
    exit 1
fi
```

**Invalid Container**:
```bash
if [[ -n "$container_id" ]]; then
    if ! docker ps -q --filter "id=$container_id" | grep -q .; then
        log ERROR "Container not found or not running: $container_id"
        log INFO "Use 'docker ps' to see available containers"
        exit 1
    fi
fi
```

### 3.4 Logging

**Debug logging for execution context**:
```bash
if [[ "$verbose" == "true" ]]; then
    if [[ -z "$container_id" ]]; then
        log DEBUG "Execution: Local (n8n CLI)"
        log DEBUG "n8n version: $(n8n --version 2>/dev/null || echo 'unknown')"
    else
        log DEBUG "Execution: Docker (container: $container_id)"
        log DEBUG "n8n version: $(docker exec "$container_id" n8n --version 2>/dev/null || echo 'unknown')"
    fi
fi
```

---

## 4. Testing Strategy

### 4.1 Test Matrix

| Scenario | Container Param | n8n CLI | Expected Behavior |
|----------|----------------|---------|-------------------|
| Docker (explicit) | Set (valid) | N/A | Use docker exec |
| Docker (invalid) | Set (invalid) | N/A | Error: container not found |
| Local (auto) | Not set | Available | Use local n8n CLI |
| Interactive fallback | Not set | Not available | Prompt for container |
| Non-interactive error | Not set (--defaults) | Not available | Error with instructions |
| Embedded container | Not set | Available | Use local n8n CLI |

### 4.2 Regression Tests

**Ensure existing behavior unchanged**:
- Push with container specified
- Pull with container specified
- Reset with container specified
- All folder structure operations
- All authentication methods
- Dry-run mode in all operations

### 4.3 New Tests

**Local execution scenarios**:
- Push without container (local n8n)
- Pull without container (local n8n)
- Folder structure sync (local n8n)
- Session authentication (local n8n)
- Embedded container workflow backup

---

## 5. Documentation Updates

### 5.1 README.md Changes

**Add to Prerequisites section**:
- Clarify that n8n can be local OR in docker
- Add npm install instructions for local n8n
- Add Dockerfile example for embedded n8n-git

**Add to Troubleshooting section**:
- "n8n command not found" → install n8n or specify container
- "Neither container nor n8n CLI available" → solutions

### 5.2 Architecture Documentation

**Update ARCHITECTURE.md**:
- Rename references from `dockExec()` to `n8n_exec()`
- Explain execution path selection logic
- Document file operation abstractions

### 5.3 Examples Directory

**Update examples/README.md**:
- Add embedded container use case
- Add workflow-triggered backup example
- Add Kubernetes deployment example

**Enhance examples/Dockerfile.n8n-with-git**:
- Ensure it builds and works
- Add comments explaining usage
- Add run instructions

---

## 6. Migration Guide

### 6.1 For Existing Users

**No action required!** Existing configurations continue to work:

```bash
# Before (still works exactly the same)
N8N_CONTAINER="n8n-prod"
n8n-git push --workflows 2

# Or with CLI argument
n8n-git push --container n8n-prod --workflows 2
```

### 6.2 For New Local Installations

**Install n8n locally**:
```bash
npm install -g n8n
n8n start &
```

**Use n8n-git without container parameter**:
```bash
n8n-git push --workflows 2
# Automatically detects and uses local n8n CLI
```

### 6.3 For Embedded Container Usage

**Build custom n8n image**:
```dockerfile
FROM n8nio/n8n:latest
RUN apk add --no-cache bash git curl jq
RUN curl -sSL https://raw.githubusercontent.com/tcoretech/n8n-git/main/install.sh | bash
```

**Run and use**:
```bash
docker build -t n8n-with-git .
docker run -d --name n8n -p 5678:5678 n8n-with-git

# Execute from inside container
docker exec n8n n8n-git push --workflows 2

# Or create workflow with Execute Command node calling n8n-git
```

---

## 7. Success Criteria

### 7.1 Functional Requirements

- [ ] All 33 `dockExec()` calls renamed to `n8n_exec()`
- [ ] All 16 `docker cp` operations work with helper functions
- [ ] Container parameter optional (validated only when set)
- [ ] Local n8n CLI execution works when container not specified
- [ ] Interactive container selection still works
- [ ] All existing tests pass (0% regression)
- [ ] New local execution tests pass

### 7.2 Performance Requirements

- [ ] Local execution 30-50% faster than docker execution
- [ ] No performance regression in docker mode
- [ ] File operations complete in similar time

### 7.3 Documentation Requirements

- [ ] README updated with local execution instructions
- [ ] ARCHITECTURE.md updated with n8n_exec() design
- [ ] Examples directory updated with embedded scenario
- [ ] Troubleshooting guide includes local execution issues

### 7.4 Code Quality Requirements

- [ ] All functions renamed consistently
- [ ] No breaking changes to existing behavior
- [ ] Clear error messages for all failure scenarios
- [ ] Debug logging helpful for troubleshooting

---

## Appendix A: File Change Summary

### Files Modified (8 files)

1. **`lib/utils/common.sh`**
   - Rename `dockExec()` → `n8n_exec()`
   - Rename `dockExecAsRoot()` → `n8n_exec_root()`
   - Add `copy_from_n8n()` helper
   - Add `copy_to_n8n()` helper
   - Update logic to check container_id emptiness

2. **`n8n-git.sh`**
   - Update container validation logic
   - Make container parameter optional
   - Add n8n CLI detection
   - Update error messages

3. **`lib/push/export.sh`**
   - Update 7 `dockExec` calls → `n8n_exec`
   - Update 7 `docker cp` calls → helper functions

4. **`lib/push/container_io.sh`**
   - Update 2 `dockExec` calls → `n8n_exec`
   - Update 1 `docker cp` call → helper function

5. **`lib/pull/import.sh`**
   - Update 12 `dockExec` calls → `n8n_exec`
   - Update 3 `docker cp` calls → helper functions

6. **`lib/pull/staging.sh`**
   - Update 2 `dockExec` calls → `n8n_exec`
   - Update 1 `docker cp` call → helper function

7. **`lib/n8n/auth.sh`**
   - Update 4 `dockExec` calls → `n8n_exec`
   - Update 2 `docker cp` calls → helper functions

8. **`lib/n8n/snapshot.sh`** (if separate)
   - Update `dockExec` calls → `n8n_exec`
   - Update `docker cp` calls → helper functions

### Documentation Updates (3 files)

1. **`README.md`**
   - Add local execution explanation
   - Update prerequisites
   - Add troubleshooting

2. **`docs/ARCHITECTURE.md`**
   - Document n8n_exec() design
   - Explain execution path selection

3. **`examples/README.md`**
   - Add embedded container examples
   - Add workflow examples

---

## Appendix B: Implementation Checklist

### Phase 1: Core Functions (Week 1)
- [ ] Rename `dockExec()` to `n8n_exec()` in common.sh
- [ ] Rename `dockExecAsRoot()` to `n8n_exec_root()` in common.sh
- [ ] Add container_id emptiness check in n8n_exec()
- [ ] Add local execution path in n8n_exec()
- [ ] Create `copy_from_n8n()` helper
- [ ] Create `copy_to_n8n()` helper
- [ ] Update lib/push/export.sh calls (7 sites)
- [ ] Update lib/push/container_io.sh calls (2 sites)
- [ ] Update lib/pull/import.sh calls (12 sites)
- [ ] Update lib/pull/staging.sh calls (2 sites)
- [ ] Update lib/n8n/auth.sh calls (4 sites)
- [ ] Update lib/n8n/snapshot.sh calls (if separate)
- [ ] Test: Existing docker usage still works
- [ ] Test: Local execution works

### Phase 2: Container Detection (Week 2)
- [ ] Update n8n-git.sh container validation
- [ ] Make container parameter optional
- [ ] Add n8n CLI availability check
- [ ] Update interactive selection with warning
- [ ] Add helpful error messages
- [ ] Test: Explicit container works
- [ ] Test: Local CLI auto-detected
- [ ] Test: Interactive fallback works
- [ ] Test: Non-interactive error clear

### Phase 3: File Operations (Week 2-3)
- [ ] Update lib/push/export.sh docker cp (7 sites)
- [ ] Update lib/push/container_io.sh docker cp (1 site)
- [ ] Update lib/pull/import.sh docker cp (3 sites)
- [ ] Update lib/pull/staging.sh docker cp (1 site)
- [ ] Update lib/n8n/auth.sh docker cp (2 sites)
- [ ] Update lib/n8n/snapshot.sh docker cp (if separate)
- [ ] Test: Push with local execution
- [ ] Test: Pull with local execution
- [ ] Test: File permissions preserved

### Phase 4: Documentation (Week 3)
- [ ] Update README.md prerequisites
- [ ] Update README.md installation
- [ ] Update README.md troubleshooting
- [ ] Update docs/ARCHITECTURE.md
- [ ] Update examples/README.md
- [ ] Verify examples/Dockerfile.n8n-with-git works
- [ ] Add workflow examples
- [ ] Review all documentation for accuracy

### Phase 5: Testing (Week 3-4)
- [ ] Update test scripts with new function names
- [ ] Test docker execution (regression)
- [ ] Test local execution
- [ ] Test embedded container
- [ ] Test interactive fallback
- [ ] Run performance benchmark
- [ ] Test all workflows modes (0/1/2)
- [ ] Test folder structure sync
- [ ] Test authentication methods
- [ ] Verify no breaking changes

---

## Timeline

**Total Duration**: 3-4 weeks
**Total Effort**: 20-30 hours

```
Week 1: Core Functions
├─ Day 1-2: Rename functions, add local execution
├─ Day 3-4: Update all call sites (33 calls)
└─ Day 5: Initial testing

Week 2: Detection & File Ops
├─ Day 1-2: Container detection logic
├─ Day 3-4: Update docker cp operations (16 calls)
└─ Day 5: Integration testing

Week 3: Documentation & Testing
├─ Day 1-2: Documentation updates
├─ Day 3-4: Comprehensive testing
└─ Day 5: Final review

Week 4: Polish & Release (if needed)
└─ Buffer for issues and refinements
```

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2024-12-24 | Claude | Initial comprehensive plan |
| 1.0 | 2024-12-24 | Claude | Simplified based on stakeholder feedback - APPROVED |

---

**End of Implementation Plan**
