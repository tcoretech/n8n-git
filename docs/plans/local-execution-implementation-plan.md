# Implementation Plan: Local Host Execution Mode

**Status**: Draft - Pending Stakeholder Review
**Created**: 2024-12-24
**Target Version**: 2.0.0
**Estimated Effort**: 40-60 hours (with comprehensive testing)

---

## Executive Summary

This plan details the implementation of local execution mode for n8n-git, enabling it to run directly on the same host as n8n (or inside the n8n container) without requiring Docker operations. This eliminates `docker exec` and `docker cp` overhead, enables workflow-triggered git operations, and improves cloud-native compatibility.

### Key Metrics
- **Files Modified**: 12-15 core files
- **Functions Affected**: 33 `dockExec()` calls, 16 `docker cp` operations
- **New Config Variables**: 3-5 (execution mode, data directory, etc.)
- **Backward Compatibility**: 100% (docker mode remains default)
- **Performance Gain**: 30-50% faster push/pull operations (estimated)

---

## Table of Contents

1. [Current State Analysis](#1-current-state-analysis)
2. [Requirements & Scope](#2-requirements--scope)
3. [Architecture & Design](#3-architecture--design)
4. [Implementation Phases](#4-implementation-phases)
5. [Technical Specifications](#5-technical-specifications)
6. [Testing Strategy](#6-testing-strategy)
7. [Migration Guide](#7-migration-guide)
8. [Risk Assessment](#8-risk-assessment)
9. [Open Questions](#9-open-questions)
10. [Success Criteria](#10-success-criteria)

---

## 1. Current State Analysis

### 1.1 Docker Dependencies

**33 `dockExec()` function calls** across 6 files:
- `lib/pull/import.sh` - 12 calls (workflow/credential imports)
- `lib/push/export.sh` - 7 calls (exports, cleanup)
- `lib/n8n/auth.sh` - 4 calls (credential lookup, session auth)
- `lib/pull/staging.sh` - 2 calls (workflow snapshots)
- `lib/push/container_io.sh` - 2 calls (workflow collection)
- `lib/utils/common.sh` - 2 definitions (`dockExec`, `dockExecAsRoot`)

**16 `docker cp` operations** across 7 files:
- `lib/push/export.sh` - 7 operations (workflows, credentials, env to host)
- `lib/pull/import.sh` - 3 operations (workflows, credentials to container)
- `lib/push/container_io.sh` - 1 operation (workflow exports collection)
- `lib/pull/staging.sh` - 1 operation (staging to container)
- `lib/n8n/snapshot.sh` - 1 operation (snapshot export)
- `lib/n8n/auth.sh` - 2 operations (credential lookups)
- `tests/test-push.sh` - 1 operation (test setup)

### 1.2 Configuration System

**Current container configuration:**
- Variable: `N8N_CONTAINER` (defaults to "n8n")
- CLI argument: `--container <id|name>`
- Validation: Required in non-interactive mode
- Detection: Auto-select from running containers in interactive mode

**Current precedence chain:**
```
CLI Arguments > Config File > Interactive Prompts > Built-in Defaults
```

### 1.3 Critical Code Paths

**Push Flow:**
```
push_export()
  → push_collect_workflow_exports()     [uses dockExec 2x, docker cp 1x]
  → push_render_*()                     [uses dockExec 7x, docker cp 7x]
  → git operations
```

**Pull Flow:**
```
pull_import()
  → pull_stage_*()                      [uses dockExec 2x, docker cp 1x]
  → pull_import_*()                     [uses dockExec 12x, docker cp 3x]
  → validation
```

**Authentication Flow:**
```
validate_n8n_api_access()
  → ensure_n8n_session_credentials()    [uses dockExec 4x, docker cp 2x]
  → test_n8n_session_auth()
```

---

## 2. Requirements & Scope

### 2.1 Functional Requirements

**FR-1: Execution Mode Detection**
- System SHALL auto-detect if `n8n` command is available
- System SHALL support explicit mode override via environment variable
- System SHALL default to docker mode for backward compatibility

**FR-2: Local Command Execution**
- System SHALL execute n8n commands directly when in local mode
- System SHALL maintain identical command syntax between modes
- System SHALL preserve all existing command flags and options

**FR-3: File System Access**
- System SHALL use direct file access in local mode (no `docker cp`)
- System SHALL maintain same directory structure semantics
- System SHALL preserve file permissions and ownership

**FR-4: Configuration**
- System SHALL add `N8N_GIT_EXECUTION_MODE` configuration variable
- System SHALL accept values: `auto`, `local`, `docker`
- System SHALL validate prerequisites for each mode

**FR-5: Credential Decryption**
- System SHALL access n8n encryption key in local mode
- System SHALL support multiple key access methods (file, env var)
- System SHALL fail gracefully if key is inaccessible

**FR-6: Backward Compatibility**
- System SHALL NOT break existing docker-based deployments
- System SHALL NOT require config file changes for existing users
- System SHALL maintain identical CLI interface

### 2.2 Non-Functional Requirements

**NFR-1: Performance**
- Local mode SHOULD be 30-50% faster than docker mode
- File operations SHOULD avoid unnecessary copying

**NFR-2: Security**
- Local mode SHALL maintain same security posture as docker mode
- Credential files SHALL have appropriate permissions (600/700)
- Decrypted credentials SHALL NOT be logged

**NFR-3: Usability**
- Mode detection SHOULD be transparent to users
- Error messages SHOULD guide users to resolution
- Documentation SHOULD include migration examples

**NFR-4: Maintainability**
- Code changes SHOULD minimize duplication
- Abstraction layer SHOULD isolate mode-specific logic
- Tests SHOULD cover both execution modes

### 2.3 Out of Scope (v1)

- Remote n8n instances (not localhost)
- Multi-instance n8n coordination
- Windows native execution (WSL remains supported)
- n8n version compatibility detection
- Automatic mode migration/upgrade

---

## 3. Architecture & Design

### 3.1 Execution Mode State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                    INITIALIZATION                            │
│  Read N8N_GIT_EXECUTION_MODE from env/config               │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
        ┌────────────────────────┐
        │ MODE = "auto"?         │
        └────┬──────────────┬────┘
             │ No           │ Yes
             │              │
             │              ▼
             │    ┌──────────────────────┐
             │    │ command -v n8n       │
             │    │ available?           │
             │    └───┬──────────────┬───┘
             │        │ Yes          │ No
             │        │              │
             │        ▼              ▼
             │   ┌─────────┐   ┌─────────┐
             │   │  LOCAL  │   │ DOCKER  │
             │   │  MODE   │   │  MODE   │
             │   └─────────┘   └─────────┘
             │        ▲              ▲
             ▼        │              │
     ┌───────────┐   │              │
     │ MODE =    │───┼──────────────┘
     │ "local"   │   │
     │ or        │   │
     │ "docker"  │───┘
     └───────────┘

        EXECUTION PHASE
             │
             ▼
┌────────────────────────────────────────────┐
│  Execute operations based on mode:        │
│                                            │
│  LOCAL MODE:                               │
│   - Direct command execution               │
│   - Direct file system access              │
│   - No docker operations                   │
│                                            │
│  DOCKER MODE:                              │
│   - docker exec for commands               │
│   - docker cp for file transfers           │
│   - Container validation required          │
└────────────────────────────────────────────┘
```

### 3.2 Core Abstraction Layer

**New Module**: `lib/utils/execution.sh` (or enhance `common.sh`)

```bash
# Execution mode detection
detect_execution_mode() {
    # Returns: "local" | "docker"
}

# Unified command execution
execute_n8n_command() {
    local cmd="$1"
    local mode="${N8N_EXECUTION_MODE:-auto}"

    case "$mode" in
        local)  eval "$cmd" ;;
        docker) docker exec "$container_id" sh -c "$cmd" ;;
        *)      log ERROR "Invalid mode: $mode" ;;
    esac
}

# Unified file operations
copy_file_from_n8n() {
    local source="$1"
    local dest="$2"
    local mode="${N8N_EXECUTION_MODE:-auto}"

    case "$mode" in
        local)  cp "$source" "$dest" ;;
        docker) docker cp "$container_id:$source" "$dest" ;;
    esac
}

copy_file_to_n8n() {
    local source="$1"
    local dest="$2"
    local mode="${N8N_EXECUTION_MODE:-auto}"

    case "$mode" in
        local)  cp "$source" "$dest" ;;
        docker) docker cp "$source" "$container_id:$dest" ;;
    esac
}
```

### 3.3 Configuration Schema

**New Configuration Variables:**

```bash
# Execution mode: auto (detect), local (direct), docker (container)
N8N_GIT_EXECUTION_MODE="auto"

# n8n data directory (for local mode, optional - auto-detected)
N8N_DATA_DIR=""

# n8n encryption key (for local mode credential decryption)
N8N_ENCRYPTION_KEY=""

# n8n encryption key file path (alternative to env var)
N8N_ENCRYPTION_KEY_FILE=""
```

**CLI Arguments:**

```bash
--execution-mode <auto|local|docker>
--n8n-data-dir <path>
--n8n-encryption-key <key>
```

### 3.4 Path Resolution Strategy

**Docker Mode (Current):**
```
Container Path: /tmp/workflows.json
Host Path:      ~/n8n-backup/workflows.json
Operation:      docker cp container:/tmp/workflows.json ~/n8n-backup/workflows.json
```

**Local Mode (New):**
```
Direct Path:    ~/n8n-backup/workflows.json  (or temp directory)
Operation:      n8n export:workflow --output=~/n8n-backup/workflows.json
```

**Path Resolution Rules:**

1. **Export Operations (n8n → filesystem)**:
   - Docker: Export to `/tmp/` inside container, then `docker cp` to host
   - Local: Export directly to target path on host

2. **Import Operations (filesystem → n8n)**:
   - Docker: `docker cp` to `/tmp/` inside container, then import
   - Local: Import directly from host filesystem path

3. **Temporary Files**:
   - Docker: Use `/tmp/` inside container + host temp directory
   - Local: Use only host temp directory (via `mktemp`)

---

## 4. Implementation Phases

### Phase 1: Foundation & Detection (Week 1)

**Estimated Effort**: 12-16 hours

**Deliverables:**
- [ ] Add execution mode detection function
- [ ] Add configuration variables to `.config.example`
- [ ] Update config loading in `lib/utils/common.sh`
- [ ] Add CLI argument parsing for execution mode
- [ ] Add validation logic for mode-specific prerequisites
- [ ] Write unit tests for detection logic

**Files Modified:**
- `lib/utils/common.sh` - Add `detect_execution_mode()`
- `n8n-git.sh` - Add CLI argument parsing
- `.config.example` - Document new variables
- `tests/test-syntax.sh` - Add detection tests

**Acceptance Criteria:**
- Detection correctly identifies local vs docker environments
- Explicit mode override works via env var and CLI
- Config validation passes for both modes
- Tests pass in CI

---

### Phase 2: Core Execution Abstraction (Week 2)

**Estimated Effort**: 16-20 hours

**Deliverables:**
- [ ] Refactor `dockExec()` to support both modes
- [ ] Add `dockExecAsRoot()` support for local mode
- [ ] Create file copy abstraction (`copy_from_n8n`, `copy_to_n8n`)
- [ ] Update all `dockExec()` callers to use mode-aware execution
- [ ] Handle privilege escalation in local mode (if needed)
- [ ] Add comprehensive logging for mode selection

**Files Modified:**
- `lib/utils/common.sh` - Refactor `dockExec()`, add file copy helpers
- All files calling `dockExec()` (6 files, 33 call sites)

**Implementation Strategy:**

```bash
# Option A: Modify dockExec() directly (backward compatible)
dockExec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local mode="${N8N_EXECUTION_MODE:-docker}"

    if $is_dry_run; then
        log DRYRUN "Would execute ($mode): $cmd"
        return 0
    fi

    if [[ "$mode" == "local" ]]; then
        log DEBUG "Executing locally: $cmd"
        eval "$cmd"
    else
        log DEBUG "Executing in container $container_id: $cmd"
        docker exec "$container_id" sh -c "$cmd"
    fi
}

# Option B: Create new abstraction, deprecate dockExec()
executeCommand() {
    # New function with clearer naming
}
```

**Acceptance Criteria:**
- All existing dockExec() calls work in both modes
- Dry-run mode functions correctly in both modes
- Error handling preserves exit codes
- Logging clearly indicates execution mode

---

### Phase 3: Push Operations (Week 3)

**Estimated Effort**: 12-16 hours

**Deliverables:**
- [ ] Update `push_collect_workflow_exports()` for local mode
- [ ] Update `push_render_*()` functions to eliminate docker cp
- [ ] Handle direct export to Git repo in local mode
- [ ] Update credential export logic
- [ ] Update environment variable export
- [ ] Optimize temporary directory usage

**Files Modified:**
- `lib/push/container_io.sh`
- `lib/push/export.sh`
- `lib/push/folder_mapping.sh` (if path changes needed)

**Implementation Details:**

**Current (Docker Mode):**
```bash
# Export inside container
dockExec "$container_id" "n8n export:workflow --all --output=/tmp/workflows.json"
# Copy to host
docker cp "$container_id:/tmp/workflows.json" "$host_path"
```

**New (Local Mode):**
```bash
# Export directly to host path
n8n export:workflow --all --output="$host_path"
```

**Acceptance Criteria:**
- Push to Git works in local mode
- Push to local storage works in local mode
- Folder structure preserved correctly
- Credentials handled securely
- Performance improvement measurable (30%+ faster)

---

### Phase 4: Pull Operations (Week 4)

**Estimated Effort**: 12-16 hours

**Deliverables:**
- [ ] Update `pull_import_*()` functions for local mode
- [ ] Update staging logic to use direct paths
- [ ] Handle workflow ID preservation in local mode
- [ ] Update credential import logic
- [ ] Update validation and post-import checks

**Files Modified:**
- `lib/pull/import.sh`
- `lib/pull/staging.sh`
- `lib/pull/validate.sh` (if needed)

**Implementation Details:**

**Current (Docker Mode):**
```bash
# Copy to container
docker cp "$host_path" "$container_id:/tmp/workflows.json"
# Import inside container
dockExec "$container_id" "n8n import:workflow --input=/tmp/workflows.json"
```

**New (Local Mode):**
```bash
# Import directly from host path
n8n import:workflow --input="$host_path"
```

**Acceptance Criteria:**
- Pull from Git works in local mode
- Pull from local storage works in local mode
- Workflow IDs preserved correctly
- Folder structure recreated properly
- Duplicate detection functions correctly

---

### Phase 5: Authentication & Credentials (Week 5)

**Estimated Effort**: 8-12 hours

**Deliverables:**
- [ ] Update credential lookup in `lib/n8n/auth.sh`
- [ ] Implement local encryption key access
- [ ] Update session credential retrieval
- [ ] Handle credential decryption in local mode
- [ ] Update snapshot operations

**Files Modified:**
- `lib/n8n/auth.sh`
- `lib/n8n/snapshot.sh`
- `lib/n8n/decrypt.sh` (if applicable)

**Encryption Key Access Strategy:**

```bash
get_n8n_encryption_key() {
    local mode="${N8N_EXECUTION_MODE:-docker}"

    # Priority 1: Explicit environment variable
    if [[ -n "${N8N_ENCRYPTION_KEY:-}" ]]; then
        echo "$N8N_ENCRYPTION_KEY"
        return 0
    fi

    # Priority 2: Key file
    if [[ -n "${N8N_ENCRYPTION_KEY_FILE:-}" ]] && [[ -f "$N8N_ENCRYPTION_KEY_FILE" ]]; then
        cat "$N8N_ENCRYPTION_KEY_FILE"
        return 0
    fi

    # Priority 3: Read from n8n config (local mode only)
    if [[ "$mode" == "local" ]]; then
        local n8n_config="${N8N_DATA_DIR:-$HOME/.n8n}/config"
        if [[ -f "$n8n_config" ]]; then
            jq -r '.encryptionKey // empty' "$n8n_config" 2>/dev/null
            return 0
        fi
    fi

    # Priority 4: Read from environment variable inside container (docker mode)
    if [[ "$mode" == "docker" ]]; then
        docker exec "$container_id" printenv N8N_ENCRYPTION_KEY
        return 0
    fi

    log ERROR "Could not determine n8n encryption key"
    return 1
}
```

**Acceptance Criteria:**
- Session authentication works in local mode
- Credential decryption functions correctly
- API access validation passes
- Security maintained (no key leakage in logs)

---

### Phase 6: Documentation & Examples (Week 6)

**Estimated Effort**: 8-12 hours

**Deliverables:**
- [ ] Update README.md with execution modes section
- [ ] Create `docs/execution-modes.md` guide
- [ ] Update `docs/ARCHITECTURE.md`
- [ ] Enhance examples in `examples/` directory
- [ ] Create troubleshooting guide
- [ ] Add inline code comments
- [ ] Create video demo or animated GIFs

**Files Modified/Created:**
- `README.md`
- `docs/execution-modes.md` (new)
- `docs/ARCHITECTURE.md`
- `docs/troubleshooting.md`
- `examples/README.md`
- `examples/Dockerfile.n8n-with-git`
- `examples/kubernetes/` (new directory)

**Documentation Structure:**

```markdown
# Execution Modes Guide

## Overview
- What are execution modes?
- When to use each mode
- Performance characteristics

## Docker Mode (Default)
- How it works
- Prerequisites
- Configuration
- Troubleshooting

## Local Mode
- How it works
- Prerequisites
- Configuration
- Troubleshooting
- Migration from Docker mode

## Auto-Detection
- How detection works
- Override behavior
- Edge cases

## Examples
- Dockerfile for embedded n8n-git
- Kubernetes deployment
- Workflow-triggered backups
- CI/CD integration
```

**Acceptance Criteria:**
- All execution modes documented
- Migration guide clear and tested
- Examples work as documented
- Troubleshooting covers common issues

---

### Phase 7: Testing & Validation (Week 7)

**Estimated Effort**: 16-20 hours

**Deliverables:**
- [ ] Unit tests for mode detection
- [ ] Integration tests for local mode push
- [ ] Integration tests for local mode pull
- [ ] Integration tests for authentication
- [ ] Docker-compose test environment
- [ ] CI pipeline updates
- [ ] Performance benchmarks
- [ ] Security audit

**Test Coverage:**

```bash
# Unit Tests
tests/unit/test-execution-mode-detection.sh
tests/unit/test-path-resolution.sh
tests/unit/test-config-validation.sh

# Integration Tests
tests/integration/test-local-push.sh
tests/integration/test-local-pull.sh
tests/integration/test-local-auth.sh
tests/integration/test-docker-mode-regression.sh

# End-to-End Tests
tests/e2e/test-workflow-backup-local.sh
tests/e2e/test-workflow-backup-docker.sh
tests/e2e/test-mode-switching.sh
```

**Test Environments:**

1. **Local Mode Test Setup:**
   ```bash
   # Install n8n locally
   npm install -g n8n
   # Install n8n-git
   make install
   # Run tests
   N8N_GIT_EXECUTION_MODE=local ./tests/test-push.sh
   ```

2. **Docker Mode Test Setup:**
   ```bash
   # Start n8n container
   docker run -d --name n8n -p 5678:5678 n8nio/n8n
   # Run tests
   N8N_GIT_EXECUTION_MODE=docker ./tests/test-push.sh
   ```

3. **Embedded Mode Test Setup:**
   ```bash
   # Build custom image
   docker build -f examples/Dockerfile.n8n-with-git -t n8n-with-git .
   # Run container
   docker run -d --name n8n-embedded n8n-with-git
   # Test from inside container
   docker exec n8n-embedded n8n-git push --workflows 2
   ```

**Performance Benchmarks:**

```bash
# Benchmark script
#!/bin/bash
measure_operation() {
    local mode="$1"
    local operation="$2"

    start_time=$(date +%s.%N)
    N8N_GIT_EXECUTION_MODE="$mode" n8n-git "$operation" --defaults
    end_time=$(date +%s.%N)

    elapsed=$(echo "$end_time - $start_time" | bc)
    echo "$mode $operation: ${elapsed}s"
}

# Compare modes
measure_operation docker push
measure_operation local push
measure_operation docker pull
measure_operation local pull
```

**Acceptance Criteria:**
- All existing tests pass in docker mode
- New tests pass in local mode
- No regression in docker mode performance
- Local mode shows 30%+ performance improvement
- CI pipeline runs both modes
- Security audit passes

---

## 5. Technical Specifications

### 5.1 Execution Mode Detection Algorithm

```bash
detect_execution_mode() {
    # Check for explicit override
    if [[ -n "${N8N_GIT_EXECUTION_MODE:-}" ]]; then
        case "${N8N_GIT_EXECUTION_MODE,,}" in
            local|docker)
                echo "${N8N_GIT_EXECUTION_MODE,,}"
                return 0
                ;;
            auto)
                # Continue to auto-detection
                ;;
            *)
                log ERROR "Invalid N8N_GIT_EXECUTION_MODE: $N8N_GIT_EXECUTION_MODE"
                log INFO "Valid values: auto, local, docker"
                return 1
                ;;
        esac
    fi

    # Auto-detection: Check if n8n command is available
    if command -v n8n &>/dev/null; then
        # Verify n8n is actually functional
        if n8n --version &>/dev/null; then
            log INFO "Detected n8n command available - using local execution mode"
            echo "local"
            return 0
        else
            log WARN "n8n command found but not functional - using docker mode"
            echo "docker"
            return 0
        fi
    fi

    # Default to docker mode
    log DEBUG "n8n command not found - using docker execution mode"
    echo "docker"
    return 0
}
```

### 5.2 Container Parameter Handling

**Approach**: Make container parameter optional in local mode

```bash
# In n8n-git.sh main script
N8N_EXECUTION_MODE=$(detect_execution_mode)

# Validate container only if needed
if [[ "$N8N_EXECUTION_MODE" == "docker" ]]; then
    if [[ -z "$container" ]]; then
        if [[ "$stdin_is_tty" == "true" && "$assume_defaults" != "true" ]]; then
            # Interactive selection
            select_container
            container="$SELECTED_CONTAINER_ID"
        else
            log ERROR "Container is required in docker mode"
            log INFO "Specify with --container <id|name>"
            exit 1
        fi
    fi

    # Validate container exists and is running
    validate_container "$container"
else
    # Local mode - container parameter not needed
    if [[ -n "$container" ]]; then
        log DEBUG "Container parameter ignored in local mode"
    fi
fi
```

### 5.3 Path Resolution Matrix

| Operation | Docker Mode | Local Mode |
|-----------|-------------|------------|
| **Workflow Export** | `/tmp/workflows.json` → `docker cp` → host | Direct export to host path |
| **Workflow Import** | Host → `docker cp` → `/tmp/workflows.json` | Direct import from host path |
| **Credential Export** | `/tmp/credentials.json` → `docker cp` → host | Direct export to host path |
| **Credential Import** | Host → `docker cp` → `/tmp/credentials.json` | Direct import from host path |
| **Environment Export** | `/tmp/.env` → `docker cp` → host | Direct export to host path |
| **Snapshot** | `/tmp/snapshot.json` → `docker cp` → host | Direct export to temp file |
| **Temp Directory** | Container `/tmp/` + Host temp | Host temp only |

### 5.4 Error Handling Strategy

**Principle**: Fail fast with clear error messages guiding users to resolution

```bash
# Example: Encryption key not found
if [[ -z "$encryption_key" ]]; then
    log ERROR "Could not access n8n encryption key in local mode"
    log INFO "Please set one of the following:"
    log INFO "  1. N8N_ENCRYPTION_KEY environment variable"
    log INFO "  2. N8N_ENCRYPTION_KEY_FILE pointing to key file"
    log INFO "  3. Ensure ~/.n8n/config exists with encryptionKey"
    exit 1
fi

# Example: n8n command not found when mode=local
if [[ "$N8N_EXECUTION_MODE" == "local" ]] && ! command -v n8n &>/dev/null; then
    log ERROR "Execution mode set to 'local' but n8n command not found"
    log INFO "Please install n8n: npm install -g n8n"
    log INFO "Or switch to docker mode: --execution-mode docker"
    exit 1
fi

# Example: Docker not available when mode=docker
if [[ "$N8N_EXECUTION_MODE" == "docker" ]] && ! command -v docker &>/dev/null; then
    log ERROR "Execution mode set to 'docker' but Docker not found"
    log INFO "Please install Docker or switch to local mode"
    exit 1
fi
```

### 5.5 Logging & Debugging

**Add execution mode to log header:**

```bash
log_execution_mode_info() {
    log INFO "Execution Mode: $N8N_EXECUTION_MODE"

    if [[ "$N8N_EXECUTION_MODE" == "local" ]]; then
        log DEBUG "n8n version: $(n8n --version 2>/dev/null || echo 'unknown')"
        log DEBUG "n8n data dir: ${N8N_DATA_DIR:-auto-detect}"
    else
        log DEBUG "Container: $container"
        log DEBUG "Container n8n version: $(docker exec "$container" n8n --version 2>/dev/null || echo 'unknown')"
    fi
}
```

**Verbose mode enhancements:**

```bash
if [[ "$verbose" == "true" ]]; then
    log DEBUG "=== Execution Environment ==="
    log DEBUG "Mode: $N8N_EXECUTION_MODE"
    log DEBUG "Mode Source: ${N8N_GIT_EXECUTION_MODE:-(auto-detected)}"
    log DEBUG "n8n available: $(command -v n8n &>/dev/null && echo yes || echo no)"
    log DEBUG "Docker available: $(command -v docker &>/dev/null && echo yes || echo no)"
    log DEBUG "Container specified: ${container:-(none)}"
    log DEBUG "============================"
fi
```

---

## 6. Testing Strategy

### 6.1 Test Pyramid

```
                    /\
                   /  \
                  / E2E \          (5 tests - workflow scenarios)
                 /______\
                /        \
               / Integration \     (15 tests - push/pull/auth)
              /______________\
             /                \
            /  Unit Tests       \   (30 tests - detection, config, paths)
           /____________________\
```

### 6.2 Test Scenarios

**Unit Tests (30 tests):**
1. Mode detection with `n8n` available
2. Mode detection without `n8n`
3. Mode detection with explicit override
4. Mode detection with invalid mode value
5. Config loading with execution mode
6. CLI argument parsing for execution mode
7. Container validation in docker mode
8. Container skip in local mode
9. Path resolution in docker mode
10. Path resolution in local mode
11. Encryption key access from env var
12. Encryption key access from file
13. Encryption key access from n8n config
14. Encryption key fallback chain
15. Command construction in local mode
16. Command construction in docker mode
17. Dry-run behavior in local mode
18. Dry-run behavior in docker mode
19. Error messages for missing prerequisites
20. Logging format for each mode
21-30. (Path handling, temp directories, etc.)

**Integration Tests (15 tests):**
1. Push workflows to Git (local mode)
2. Push workflows to Git (docker mode)
3. Push credentials to local storage (local mode)
4. Push credentials to local storage (docker mode)
5. Pull workflows from Git (local mode)
6. Pull workflows from Git (docker mode)
7. Folder structure sync (local mode)
8. Folder structure sync (docker mode)
9. Session authentication (local mode)
10. Session authentication (docker mode)
11. Credential decryption (local mode)
12. Workflow snapshot (local mode)
13. Mode switching between operations
14. Dry-run end-to-end (both modes)
15. Error recovery and rollback

**End-to-End Tests (5 tests):**
1. Complete workflow lifecycle (push → modify → pull) in local mode
2. Complete workflow lifecycle in docker mode
3. Embedded container mode (n8n-git inside n8n container)
4. Automated workflow-triggered backup
5. Migration scenario (docker → local mode)

### 6.3 CI/CD Pipeline

**GitHub Actions Workflow:**

```yaml
name: Test Local Execution Mode

on: [push, pull_request]

jobs:
  test-docker-mode:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Start n8n container
        run: docker run -d --name n8n -p 5678:5678 n8nio/n8n
      - name: Install n8n-git
        run: make install
      - name: Run tests (docker mode)
        run: N8N_GIT_EXECUTION_MODE=docker make test

  test-local-mode:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
      - name: Install n8n
        run: npm install -g n8n
      - name: Install n8n-git
        run: make install
      - name: Run tests (local mode)
        run: N8N_GIT_EXECUTION_MODE=local make test

  test-embedded-mode:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build embedded image
        run: docker build -f examples/Dockerfile.n8n-with-git -t n8n-with-git .
      - name: Test from inside container
        run: |
          docker run --rm n8n-with-git n8n-git --help
          docker run --rm -e N8N_GIT_EXECUTION_MODE=local n8n-with-git bash -c "n8n-git push --dry-run --workflows 2"
```

---

## 7. Migration Guide

### 7.1 For Existing Docker Mode Users

**No action required** - docker mode remains the default. Existing configurations work unchanged.

### 7.2 Migrating to Local Mode

**Scenario 1: Host Installation**

```bash
# Before (Docker mode)
docker run -d --name n8n -p 5678:5678 n8nio/n8n
n8n-git push --container n8n --workflows 2

# After (Local mode)
npm install -g n8n
n8n start &
n8n-git push --workflows 2  # Auto-detects local mode
```

**Scenario 2: Embedded Container**

```bash
# Build custom image
docker build -f examples/Dockerfile.n8n-with-git -t n8n-with-git .

# Run with local mode enabled
docker run -d \
  --name n8n \
  -p 5678:5678 \
  -e N8N_GIT_EXECUTION_MODE=local \
  -e GITHUB_TOKEN=your_token \
  n8n-with-git

# Test
docker exec n8n n8n-git push --workflows 2 --defaults
```

### 7.3 Configuration File Updates

**Before (docker-only config):**
```bash
N8N_CONTAINER="n8n-prod"
WORKFLOWS=2
CREDENTIALS=1
```

**After (local mode config):**
```bash
N8N_GIT_EXECUTION_MODE=local
WORKFLOWS=2
CREDENTIALS=1
# N8N_CONTAINER not needed in local mode
```

**After (explicit docker mode):**
```bash
N8N_GIT_EXECUTION_MODE=docker
N8N_CONTAINER="n8n-prod"
WORKFLOWS=2
CREDENTIALS=1
```

### 7.4 Troubleshooting Migration

**Issue 1: "n8n command not found" in local mode**

```bash
# Check if n8n is installed
which n8n

# If not, install it
npm install -g n8n

# Or switch back to docker mode
N8N_GIT_EXECUTION_MODE=docker n8n-git push
```

**Issue 2: "Encryption key not accessible" in local mode**

```bash
# Option 1: Set environment variable
export N8N_ENCRYPTION_KEY="your_key_here"

# Option 2: Ensure n8n config exists
cat ~/.n8n/config  # Should contain encryptionKey

# Option 3: Point to key file
export N8N_ENCRYPTION_KEY_FILE=/path/to/key
```

**Issue 3: Permission denied accessing n8n data**

```bash
# Check n8n data directory permissions
ls -la ~/.n8n

# Fix ownership if needed
chown -R $USER:$USER ~/.n8n
```

---

## 8. Risk Assessment

### 8.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **Regression in Docker Mode** | Medium | High | Comprehensive regression testing, feature flags |
| **Path Resolution Bugs** | Medium | Medium | Extensive unit tests, validation functions |
| **Permission Issues (Local)** | High | Medium | Clear error messages, permission checks |
| **Encryption Key Access** | Medium | High | Multiple fallback methods, validation |
| **Performance Degradation** | Low | Medium | Benchmarking, performance tests |
| **Cross-Platform Issues** | Medium | Medium | Test on Linux, macOS, WSL |
| **Breaking Config Changes** | Low | High | Maintain backward compatibility |

### 8.2 Operational Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **User Confusion** | High | Low | Clear documentation, auto-detection |
| **Support Burden** | Medium | Medium | Troubleshooting guide, diagnostics |
| **Migration Complexity** | Low | Medium | No-op migration for docker users |
| **Security Regression** | Low | High | Security audit, key handling review |

### 8.3 Mitigation Strategies

1. **Feature Flags**: Add `N8N_GIT_DISABLE_LOCAL_MODE=true` escape hatch
2. **Gradual Rollout**: Release as opt-in beta first
3. **Comprehensive Testing**: 50+ tests covering both modes
4. **Documentation**: Migration guides, troubleshooting, examples
5. **Community Feedback**: Beta testing with early adopters
6. **Rollback Plan**: Keep docker mode as default, easy revert

---

## 9. Open Questions

### 9.1 Questions Requiring Stakeholder Decision

**Q1: Default Execution Mode**
- **Option A**: Auto-detect (recommended) - Transparent to users
- **Option B**: Explicit opt-in - Safer, requires user action
- **Option C**: Docker mode default - Most conservative

**Q2: Container Parameter in Local Mode**
- **Option A**: Optional (validate only if mode=docker)
- **Option B**: Ignored (accept but don't use)
- **Option C**: Error if provided in local mode

**Q3: Encryption Key Access Priority**
- **Option A**: Env var > File > n8n config
- **Option B**: n8n config > Env var > File
- **Option C**: Require explicit configuration

**Q4: n8n Data Directory Detection**
- **Option A**: Auto-detect from `N8N_USER_FOLDER` env var or `~/.n8n`
- **Option B**: Require explicit `N8N_DATA_DIR` configuration
- **Option C**: Not needed (let n8n CLI handle it)

**Q5: Function Naming**
- **Option A**: Keep `dockExec()` name (backward compatible)
- **Option B**: Rename to `executeCommand()` (clearer intent)
- **Option C**: Create new function, deprecate old

**Q6: Testing Priority**
- **Option A**: Unit tests first (fastest feedback)
- **Option B**: Integration tests first (real-world scenarios)
- **Option C**: All in parallel (comprehensive but time-consuming)

**Q7: Documentation Format**
- **Option A**: Update README + inline comments
- **Option B**: Separate guide (`docs/execution-modes.md`)
- **Option C**: Both + video demos

**Q8: Performance Optimization**
- **Option A**: Direct export to final destination (fastest)
- **Option B**: Keep staging pattern (safer, consistent)
- **Option C**: Hybrid (optimize based on operation)

**Q9: Error Message Verbosity**
- **Option A**: Minimal (INFO level only when mode detected)
- **Option B**: Verbose (always show mode selection)
- **Option C**: Interactive prompt when ambiguous

**Q10: Release Strategy**
- **Option A**: Major version bump (2.0.0) - signals breaking changes
- **Option B**: Minor version (1.x.0) - backward compatible
- **Option C**: Beta tag first (2.0.0-beta.1)

### 9.2 Technical Clarifications Needed

1. Should we validate n8n version compatibility in local mode?
2. How should we handle n8n upgrades (detect breaking CLI changes)?
3. Should local mode support remote n8n instances (not localhost)?
4. How should we handle multiple n8n instances on same host?
5. Should we add a `n8n-git doctor` diagnostic command?
6. Should we cache execution mode detection result?
7. How should we handle n8n running as different user (permissions)?
8. Should we support Windows native (not WSL) in local mode?
9. Should we add telemetry to measure mode adoption?
10. How should we handle container name conflicts in mixed mode environments?

---

## 10. Success Criteria

### 10.1 Functional Success

- [ ] Auto-detection works correctly in 100% of test cases
- [ ] All 33 `dockExec()` calls work in both modes
- [ ] All 16 `docker cp` operations eliminated in local mode
- [ ] Push operations complete successfully in both modes
- [ ] Pull operations complete successfully in both modes
- [ ] Authentication works in both modes
- [ ] Folder structure sync works in both modes
- [ ] Credential decryption works in local mode
- [ ] All existing tests pass in docker mode (0% regression)
- [ ] New tests pass in local mode (100% coverage)

### 10.2 Non-Functional Success

- [ ] Local mode is 30-50% faster than docker mode (benchmarked)
- [ ] Documentation is comprehensive and accurate
- [ ] Migration requires zero config changes for docker users
- [ ] Error messages guide users to resolution
- [ ] Code coverage >80% for new code
- [ ] Security audit passes with no critical issues
- [ ] CI pipeline runs both modes successfully
- [ ] Community feedback is positive (>80% satisfaction)

### 10.3 Adoption Metrics (Post-Release)

- [ ] 20% of users try local mode within 3 months
- [ ] <5% of users report issues/bugs
- [ ] 0 critical security issues reported
- [ ] Docker mode performance unchanged (±5%)
- [ ] Support ticket volume does not increase significantly

---

## Appendix A: File Change Summary

### Files Modified (12-15 files)

1. **`n8n-git.sh`** - Main script
   - Add execution mode CLI argument
   - Add mode detection call
   - Update container validation logic
   - Add mode-specific error handling

2. **`lib/utils/common.sh`** - Core utilities
   - Add `detect_execution_mode()`
   - Refactor `dockExec()` for both modes
   - Refactor `dockExecAsRoot()` for both modes
   - Add file copy abstractions
   - Add encryption key access helpers
   - Update config loading

3. **`lib/push/export.sh`** - Push operations
   - Update workflow export (7 `dockExec` calls, 7 `docker cp` calls)
   - Update credential export
   - Update environment export
   - Optimize temp directory usage

4. **`lib/push/container_io.sh`** - Container I/O
   - Update `push_collect_workflow_exports()` (2 `dockExec`, 1 `docker cp`)

5. **`lib/pull/import.sh`** - Pull operations
   - Update workflow import (12 `dockExec` calls, 3 `docker cp` calls)
   - Update credential import
   - Update staging logic

6. **`lib/pull/staging.sh`** - Staging
   - Update staging operations (2 `dockExec`, 1 `docker cp`)

7. **`lib/n8n/auth.sh`** - Authentication
   - Update credential lookup (4 `dockExec`, 2 `docker cp`)
   - Add encryption key access
   - Update session auth

8. **`lib/n8n/snapshot.sh`** - Snapshots
   - Update snapshot operations (1 `docker cp`)

9. **`.config.example`** - Configuration template
   - Add `N8N_GIT_EXECUTION_MODE`
   - Add `N8N_DATA_DIR` (optional)
   - Add `N8N_ENCRYPTION_KEY_FILE` (optional)

10. **`README.md`** - Main documentation
    - Add execution modes section
    - Update installation instructions
    - Add troubleshooting

11. **`docs/ARCHITECTURE.md`** - Architecture docs
    - Document execution mode design
    - Update module descriptions

12. **`examples/Dockerfile.n8n-with-git`** - Docker example
    - Already created, may need updates

13. **`examples/README.md`** - Examples guide
    - Already created, may need updates

14. **Tests** (multiple files)
    - Add unit tests for mode detection
    - Add integration tests for local mode
    - Update existing tests for both modes

15. **CI/CD** (`.github/workflows/`)
    - Add local mode test job
    - Add embedded mode test job

### Files Created (5-8 files)

1. **`docs/execution-modes.md`** - Execution modes guide
2. **`docs/troubleshooting.md`** - Troubleshooting guide (if separate)
3. **`tests/unit/test-execution-mode.sh`** - Unit tests
4. **`tests/integration/test-local-mode.sh`** - Integration tests
5. **`examples/kubernetes/deployment.yaml`** - K8s example (optional)
6. **`.github/workflows/test-local-mode.yml`** - CI workflow
7. **`docs/migration-guide.md`** - Migration guide (optional, could be in execution-modes.md)
8. **`docs/plans/local-execution-implementation-plan.md`** - This file

---

## Appendix B: Code Examples

### Example 1: Enhanced dockExec()

```bash
dockExec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local output=""
    local exit_code=0
    local mode="${N8N_EXECUTION_MODE:-docker}"

    # Dry-run mode
    if $is_dry_run; then
        if [[ "$mode" == "local" ]]; then
            log DRYRUN "Would execute locally: $cmd"
        else
            log DRYRUN "Would execute in container $container_id: $cmd"
        fi
        return 0
    fi

    # Execute based on mode
    if [[ "$mode" == "local" ]]; then
        log DEBUG "Executing locally: $cmd"
        if output=$(eval "$cmd" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        log DEBUG "Executing in container $container_id: $cmd"
        local -a exec_cmd=("docker" "exec")
        if [[ -n "${DOCKER_EXEC_USER:-}" ]]; then
            exec_cmd+=("--user" "$DOCKER_EXEC_USER")
        fi
        exec_cmd+=("$container_id" "sh" "-c" "$cmd")

        if output=$("${exec_cmd[@]}" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    # Handle output and errors
    if [ $exit_code -ne 0 ]; then
        log DEBUG "Command failed with exit code $exit_code"
        if [ -n "$output" ]; then
            log DEBUG "Output: $output"
        fi
        return $exit_code
    fi

    if [ -n "$output" ]; then
        printf '%s\n' "$output"
    fi

    return 0
}
```

### Example 2: File Copy Abstraction

```bash
copy_from_n8n() {
    local source_path="$1"
    local dest_path="$2"
    local container_id="${3:-}"
    local mode="${N8N_EXECUTION_MODE:-docker}"

    if [[ "$mode" == "local" ]]; then
        log DEBUG "Copying file locally: $source_path → $dest_path"
        if ! cp "$source_path" "$dest_path" 2>/dev/null; then
            log ERROR "Failed to copy file: $source_path"
            return 1
        fi
    else
        log DEBUG "Copying file from container: $container_id:$source_path → $dest_path"
        local docker_cp_dest
        docker_cp_dest=$(convert_path_for_docker_cp "$dest_path")
        [[ -z "$docker_cp_dest" ]] && docker_cp_dest="$dest_path"

        if ! docker cp "${container_id}:${source_path}" "$docker_cp_dest" 2>/dev/null; then
            log ERROR "Failed to copy file from container"
            return 1
        fi
    fi

    return 0
}

copy_to_n8n() {
    local source_path="$1"
    local dest_path="$2"
    local container_id="${3:-}"
    local mode="${N8N_EXECUTION_MODE:-docker}"

    if [[ "$mode" == "local" ]]; then
        log DEBUG "Copying file locally: $source_path → $dest_path"
        if ! cp "$source_path" "$dest_path" 2>/dev/null; then
            log ERROR "Failed to copy file: $source_path"
            return 1
        fi
    else
        log DEBUG "Copying file to container: $source_path → $container_id:$dest_path"
        local docker_cp_source
        docker_cp_source=$(convert_path_for_docker_cp "$source_path")
        [[ -z "$docker_cp_source" ]] && docker_cp_source="$source_path"

        if ! docker cp "$docker_cp_source" "${container_id}:${dest_path}" 2>/dev/null; then
            log ERROR "Failed to copy file to container"
            return 1
        fi
    fi

    return 0
}
```

### Example 3: Encryption Key Access

```bash
get_n8n_encryption_key() {
    local mode="${N8N_EXECUTION_MODE:-docker}"
    local key=""

    # Priority 1: Explicit environment variable
    if [[ -n "${N8N_ENCRYPTION_KEY:-}" ]]; then
        log DEBUG "Using encryption key from N8N_ENCRYPTION_KEY env var"
        echo "$N8N_ENCRYPTION_KEY"
        return 0
    fi

    # Priority 2: Key file
    if [[ -n "${N8N_ENCRYPTION_KEY_FILE:-}" ]]; then
        if [[ -f "$N8N_ENCRYPTION_KEY_FILE" ]]; then
            log DEBUG "Reading encryption key from file: $N8N_ENCRYPTION_KEY_FILE"
            cat "$N8N_ENCRYPTION_KEY_FILE"
            return 0
        else
            log WARN "N8N_ENCRYPTION_KEY_FILE specified but not found: $N8N_ENCRYPTION_KEY_FILE"
        fi
    fi

    # Priority 3: Read from n8n config (local mode only)
    if [[ "$mode" == "local" ]]; then
        local n8n_data_dir="${N8N_DATA_DIR:-}"

        # Auto-detect n8n data directory
        if [[ -z "$n8n_data_dir" ]]; then
            if [[ -n "${N8N_USER_FOLDER:-}" ]]; then
                n8n_data_dir="$N8N_USER_FOLDER"
            elif [[ -d "$HOME/.n8n" ]]; then
                n8n_data_dir="$HOME/.n8n"
            fi
        fi

        if [[ -n "$n8n_data_dir" ]]; then
            local n8n_config="$n8n_data_dir/config"
            if [[ -f "$n8n_config" ]]; then
                log DEBUG "Reading encryption key from n8n config: $n8n_config"
                key=$(jq -r '.encryptionKey // empty' "$n8n_config" 2>/dev/null)
                if [[ -n "$key" ]]; then
                    echo "$key"
                    return 0
                fi
            fi
        fi
    fi

    # Priority 4: Read from container environment (docker mode)
    if [[ "$mode" == "docker" ]]; then
        log DEBUG "Reading encryption key from container environment"
        key=$(docker exec "$container_id" printenv N8N_ENCRYPTION_KEY 2>/dev/null || true)
        if [[ -n "$key" ]]; then
            echo "$key"
            return 0
        fi
    fi

    # Failed to get key
    log ERROR "Could not determine n8n encryption key"
    log INFO "Please set one of the following:"
    log INFO "  - N8N_ENCRYPTION_KEY environment variable"
    log INFO "  - N8N_ENCRYPTION_KEY_FILE pointing to key file"
    if [[ "$mode" == "local" ]]; then
        log INFO "  - Ensure ~/.n8n/config exists with encryptionKey"
    fi
    return 1
}
```

---

## Appendix C: Timeline & Milestones

```
Week 1: Foundation & Detection
├─ Day 1-2: Mode detection implementation
├─ Day 3-4: Configuration system updates
└─ Day 5: Unit tests

Week 2: Core Execution Abstraction
├─ Day 1-2: Refactor dockExec()
├─ Day 3-4: File copy abstractions
└─ Day 5: Integration testing

Week 3: Push Operations
├─ Day 1-2: Workflow export
├─ Day 3: Credential export
├─ Day 4: Environment export
└─ Day 5: Testing & optimization

Week 4: Pull Operations
├─ Day 1-2: Workflow import
├─ Day 3: Credential import
├─ Day 4: Staging logic
└─ Day 5: Testing & validation

Week 5: Authentication & Credentials
├─ Day 1-2: Auth updates
├─ Day 3: Encryption key access
├─ Day 4: Snapshot operations
└─ Day 5: Security audit

Week 6: Documentation & Examples
├─ Day 1-2: README & guides
├─ Day 3: Examples & Dockerfile
├─ Day 4: Troubleshooting
└─ Day 5: Review & polish

Week 7: Testing & Validation
├─ Day 1-2: Integration tests
├─ Day 3: Performance benchmarks
├─ Day 4: CI/CD pipeline
└─ Day 5: Final review & release prep
```

**Total Timeline**: 7 weeks (35 days)
**Total Effort**: 40-60 hours (distributed)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2024-12-24 | Claude | Initial draft with comprehensive analysis |
| 0.2 | TBD | Team | Stakeholder review and refinements |
| 1.0 | TBD | Team | Final approved plan |

---

**End of Implementation Plan**
