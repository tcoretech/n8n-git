#!/usr/bin/env bash
# =========================================================
# lib/reset/common.sh - Shared helpers for reset operations
# =========================================================
# Common utilities and validation functions for reset feature

set -Eeuo pipefail
IFS=$'\n\t'

declare RESET_REPO_PATH=""
declare RESET_REPO_CLEANUP_DIR=""
declare RESET_GIT_ENV_ACTIVE=""
declare RESET_PREV_GIT_DIR=""
declare RESET_PREV_GIT_WORK_TREE=""

activate_reset_git_env() {
    if [[ -z "$RESET_REPO_PATH" ]]; then
        return 0
    fi

    if [[ -z "$RESET_GIT_ENV_ACTIVE" ]]; then
        RESET_PREV_GIT_DIR="${GIT_DIR:-}"
        RESET_PREV_GIT_WORK_TREE="${GIT_WORK_TREE:-}"
        RESET_GIT_ENV_ACTIVE=1
    fi

    export GIT_DIR="$RESET_REPO_PATH/.git"
    export GIT_WORK_TREE="$RESET_REPO_PATH"
}

deactivate_reset_git_env() {
    if [[ -z "$RESET_GIT_ENV_ACTIVE" ]]; then
        return 0
    fi

    if [[ -n "$RESET_PREV_GIT_DIR" ]]; then
        export GIT_DIR="$RESET_PREV_GIT_DIR"
    else
        unset GIT_DIR
    fi

    if [[ -n "$RESET_PREV_GIT_WORK_TREE" ]]; then
        export GIT_WORK_TREE="$RESET_PREV_GIT_WORK_TREE"
    else
        unset GIT_WORK_TREE
    fi

    RESET_GIT_ENV_ACTIVE=""
    RESET_PREV_GIT_DIR=""
    RESET_PREV_GIT_WORK_TREE=""
}

build_reset_clone_url() {
    local repo_value="$1"

    if [[ "$repo_value" =~ ^(https?://|git@) ]]; then
        printf '%s\n' "$repo_value"
        return 0
    fi

    if [[ -n "$github_token" ]]; then
        printf 'https://%s@github.com/%s.git\n' "$github_token" "$repo_value"
    else
        printf 'https://github.com/%s.git\n' "$repo_value"
    fi
}

prepare_reset_repository() {
    if [[ -n "$RESET_REPO_PATH" ]]; then
        activate_reset_git_env
        export RESET_REPO_PATH
        return 0
    fi

    if [[ "${workflows:-2}" == "2" ]]; then
        if [[ -z "$github_repo" ]]; then
            log ERROR "Remote workflows require --repo or GITHUB_REPO configuration."
            return 2
        fi

        local clone_dir
        clone_dir=$(mktemp -d -t n8n-reset-repo-XXXXXXXX)
        if [[ -z "$clone_dir" || ! -d "$clone_dir" ]]; then
            log ERROR "Unable to allocate temporary directory for reset repository clone."
            return 2
        fi

        local clone_url
        clone_url=$(build_reset_clone_url "$github_repo")
        local branch="${github_branch:-main}"
        log INFO "Cloning workflows repository ($github_repo:$branch) for reset"
        if ! git clone --filter=blob:none --branch "$branch" "$clone_url" "$clone_dir" >/dev/null 2>&1; then
            log ERROR "Failed to clone $github_repo (branch $branch)."
            rm -rf "$clone_dir"
            return 2
        fi

        RESET_REPO_PATH="$clone_dir"
        RESET_REPO_CLEANUP_DIR="$clone_dir"
    else
        local repo_path="${local_backup_path:-}"
        if [[ -z "$repo_path" ]]; then
            log ERROR "Local workflows mode requires --local-path or LOCAL_BACKUP_PATH pointing to your Git repository."
            return 2
        fi
        if [[ ! -d "$repo_path/.git" ]]; then
            log ERROR "Local path '$repo_path' is not a Git repository."
            return 2
        fi
        RESET_REPO_PATH="$(cd "$repo_path" && pwd)"
    fi

    activate_reset_git_env
    export RESET_REPO_PATH
    log DEBUG "Using workflow Git repository at $RESET_REPO_PATH"
    return 0
}

cleanup_reset_repository() {
    deactivate_reset_git_env
    if [[ -n "$RESET_REPO_CLEANUP_DIR" && -d "$RESET_REPO_CLEANUP_DIR" ]]; then
        rm -rf "$RESET_REPO_CLEANUP_DIR"
    fi
    RESET_REPO_CLEANUP_DIR=""
    RESET_REPO_PATH=""
    unset RESET_REPO_PATH
}

# Source shared utilities if not already loaded
if [[ -z "${PROJECT_NAME:-}" ]]; then
    # Determine lib directory relative to this script
    RESET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    
    # shellcheck source=lib/utils/common.sh
    if [[ -f "$RESET_LIB_DIR/utils/common.sh" ]]; then
        source "$RESET_LIB_DIR/utils/common.sh"
    else
        echo "ERROR: Cannot find lib/utils/common.sh" >&2
        exit 1
    fi
fi

# Source pull validation utilities
# shellcheck source=lib/pull/validate.sh
if [[ -f "${BASH_SOURCE[0]%/*}/../pull/validate.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/../pull/validate.sh"
fi

# shellcheck source=lib/n8n/endpoints.sh
if [[ -f "${BASH_SOURCE[0]%/*}/../n8n/endpoints.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/../n8n/endpoints.sh"
fi

# --- Reset-specific validation functions ---

# Validate reset configuration
# Checks that required configuration is present and valid
# Returns: 0 on success, 2 on validation failure
validate_reset_config() {
    local validation_errors=0
    
    log DEBUG "Validating reset configuration..."
    
    # Check that we have a valid Git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log ERROR "Unable to access workflow repository at ${RESET_REPO_PATH:-<unset>}"
        validation_errors=$((validation_errors + 1))
    fi
    
    # Check that we have Git remote configured if needed
    if [[ -z "${github_repo:-}" ]]; then
        if ! git remote get-url origin >/dev/null 2>&1; then
            log WARN "No Git remote configured. Some reset features may be limited."
        fi
    fi
    
    # Validate mode is either soft or hard
    if [[ -n "${reset_mode:-}" ]]; then
        case "${reset_mode}" in
            soft|hard) ;; # Valid
            *)
                log ERROR "Invalid reset mode: $reset_mode (must be 'soft' or 'hard')"
                validation_errors=$((validation_errors + 1))
                ;;
        esac
    fi
    
    # Check mutual exclusivity of target selection methods
    local target_methods=0
    [[ -n "${reset_target:-}" ]] && target_methods=$((target_methods + 1))
    [[ -n "${reset_since:-}" ]] && target_methods=$((target_methods + 1))
    [[ "${reset_interactive:-false}" == "true" ]] && target_methods=$((target_methods + 1))
    
    if [[ $target_methods -gt 1 ]]; then
        log ERROR "Only one target selection method allowed: --to, --since/--until, or --interactive"
        validation_errors=$((validation_errors + 1))
    fi

    if [[ -n "${reset_until:-}" && -z "${reset_since:-}" ]]; then
        log ERROR "--until requires --since to define the lower bound of the window."
        validation_errors=$((validation_errors + 1))
    fi
    
    if [[ $validation_errors -gt 0 ]]; then
        log ERROR "Configuration validation failed with $validation_errors error(s)"
        return 2
    fi
    
    log DEBUG "Configuration validation passed"
    return 0
}

# Validate n8n workspace connectivity
# Checks that n8n API is accessible
# Returns: 0 on success, 2 on connectivity failure
validate_n8n_connectivity() {
    log DEBUG "Validating n8n workspace connectivity..."
    
    # Check that container exists if specified
    if [[ -n "${container:-}" ]]; then
        local container_identifier="$container"
        local resolved_id=""
        local resolved_name=""

        resolved_id=$(docker ps -q --filter "id=${container_identifier}" | head -n 1)
        if [[ -z "$resolved_id" ]]; then
            resolved_id=$(docker ps -q --filter "name=${container_identifier}" | head -n 1)
            if [[ -n "$resolved_id" ]]; then
                resolved_name="$container_identifier"
            fi
        else
            resolved_name=$(docker ps --filter "id=${resolved_id}" --format '{{.Names}}' | head -n 1)
        fi

        if [[ -z "$resolved_id" ]]; then
            log ERROR "Container '$container_identifier' not found or not running"
            return 2
        fi

        if [[ -z "$resolved_name" ]]; then
            resolved_name=$(docker ps --filter "id=${resolved_id}" --format '{{.Names}}' | head -n 1)
        fi

        if [[ -n "$resolved_name" ]]; then
            log DEBUG "Container '$container_identifier' is running (ID=$resolved_id, Name=$resolved_name)"
        else
            log DEBUG "Container '$container_identifier' is running (ID=$resolved_id)"
        fi
    fi
    
    # Check n8n API accessibility (reuse existing functions from n8n-api.sh)
    # This will be enhanced when we integrate with n8n-api.sh functions
    if ! prepare_n8n_api_auth "${container:-}" "${container_credentials_path:-}"; then
        log ERROR "Failed to authenticate with n8n API"
        return 2
    fi
    
    log DEBUG "n8n connectivity validation passed"
    return 0
}

# Validate Git repository state
# Checks for uncommitted changes, detached HEAD, etc.
# Returns: 0 on success, 2 on validation failure
validate_git_state() {
    log DEBUG "Validating Git repository state..."
    
    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log WARN "Working directory has uncommitted changes"
        log WARN "Reset will apply Git changes. Consider committing or stashing first."
        # Not a hard error - user may want to reset anyway
    fi
    
    # Check if in detached HEAD state
    if ! git symbolic-ref -q HEAD >/dev/null; then
        log WARN "Repository is in detached HEAD state"
        # Not a hard error but worth noting
    fi
    
    # Verify Git is functional
    if ! git status >/dev/null 2>&1; then
        log ERROR "Git repository appears corrupted or inaccessible"
        return 2
    fi
    
    log DEBUG "Git repository state validation passed"
    return 0
}

# Run all prerequisite validations
# Convenience wrapper that runs all validation checks
# Returns: 0 if all pass, 2 if any fail
validate_reset_prerequisites() {
    local exit_code=0
    
    log INFO "Validating reset prerequisites..."

    if ! check_host_dependencies; then
        return 2
    fi

    if ! prepare_reset_repository; then
        return 2
    fi
    
    # Validate reset configuration
    if ! validate_reset_config; then
        exit_code=2
    fi
    
    # Validate Git repository state
    if ! validate_git_state; then
        exit_code=2
    fi
    
    # Validate n8n connectivity
    if ! validate_n8n_connectivity; then
        exit_code=2
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log SUCCESS "All prerequisites validated successfully"
    else
        log ERROR "Prerequisite validation failed"
    fi
    
    return $exit_code
}

# Get current Git branch name
# Returns: branch name on stdout, empty if detached HEAD
get_current_branch() {
    git symbolic-ref --short HEAD 2>/dev/null || echo ""
}

# Check if commit exists and is reachable
# Args: commit_ref
# Returns: 0 if valid, 1 if invalid
is_valid_commit() {
    local commit_ref="$1"
    
    if [[ -z "$commit_ref" ]]; then
        return 1
    fi
    
    git rev-parse --verify "${commit_ref}^{commit}" >/dev/null 2>&1
}

# Resolve commit reference to full SHA
# Args: commit_ref (tag, branch, SHA, etc.)
# Returns: full 40-char SHA on stdout, empty on error
resolve_commit_sha() {
    local commit_ref="$1"
    
    if [[ -z "$commit_ref" ]]; then
        return 1
    fi
    
    git rev-parse --verify "${commit_ref}^{commit}" 2>/dev/null || echo ""
}

# Get commit metadata
# Args: commit_sha
# Returns: JSON object with commit details on stdout
get_commit_metadata() {
    local commit_sha="$1"
    
    if [[ -z "$commit_sha" ]]; then
        echo "{}"
        return 1
    fi
    
    # Extract commit information as JSON
    git show --no-patch --format='{"sha":"%H","short_sha":"%h","subject":"%s","author":"%an","email":"%ae","date":"%aI","timestamp":"%at"}' "$commit_sha" 2>/dev/null || echo "{}"
}

# Export functions for use in other modules
export -f validate_reset_config
export -f validate_n8n_connectivity
export -f validate_git_state
export -f validate_reset_prerequisites
export -f get_current_branch
export -f is_valid_commit
export -f resolve_commit_sha
export -f get_commit_metadata
