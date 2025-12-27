#!/usr/bin/env bash
# =========================================================
# lib/reset/resolve.sh - Target commit resolution for reset
# =========================================================
# Functions for resolving target commits from various inputs:
# - Explicit references (--to <sha|tag>)
# - Time windows (--since/--until)
# - Interactive picker (--interactive)

set -Eeuo pipefail
IFS=$'\n\t'

# Source common utilities if not already loaded
if [[ -z "${PROJECT_NAME:-}" ]]; then
    RESET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/utils/common.sh
    if [[ -f "$RESET_LIB_DIR/utils/common.sh" ]]; then
        source "$RESET_LIB_DIR/utils/common.sh"
    fi
fi

# Source reset common helpers
# shellcheck source=lib/reset/common.sh
if [[ -f "${BASH_SOURCE[0]%/*}/common.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/common.sh"
fi

# shellcheck source=lib/reset/time_window.sh
if [[ -f "${BASH_SOURCE[0]%/*}/time_window.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/time_window.sh"
fi

# --- Explicit Reference Resolution ---

# Parse and validate explicit target reference
# Args: target_ref (SHA, tag, branch, etc.)
# Returns: 0 on success, 2 on validation failure
# Sets global: RESOLVED_TARGET_SHA, RESOLVED_TARGET_DISPLAY, RESOLVED_TARGET_SOURCE
parse_explicit_target() {
    local target_ref="$1"
    
    if [[ -z "$target_ref" ]]; then
        log ERROR "No target reference provided"
        return 2
    fi
    
    log DEBUG "Parsing explicit target: $target_ref"
    
    # Validate that the reference exists
    if ! is_valid_commit "$target_ref"; then
        log ERROR "Invalid commit reference: $target_ref"
        log INFO "The reference must be a valid commit SHA, tag, or branch name"
        log INFO "Use 'git log --oneline' to see available commits"
        log INFO "Use 'git tag' to see available tags"
        return 2
    fi
    
    # Resolve to full SHA
    local resolved_sha
    resolved_sha=$(resolve_commit_sha "$target_ref")
    
    if [[ -z "$resolved_sha" ]]; then
        log ERROR "Failed to resolve commit reference: $target_ref"
        return 2
    fi
    
    # Get commit metadata
    local metadata
    metadata=$(get_commit_metadata "$resolved_sha")
    
    if [[ -z "$metadata" || "$metadata" == "{}" ]]; then
        log ERROR "Failed to get metadata for commit: $resolved_sha"
        return 2
    fi
    
    # Extract display information
    local short_sha
    short_sha=$(echo "$metadata" | jq -r '.short_sha // ""')
    local subject
    subject=$(echo "$metadata" | jq -r '.subject // ""')
    
    # Build display name
    local display_name="$target_ref"
    if [[ "$target_ref" == "$resolved_sha" ]]; then
        # User provided full SHA, use short version for display
        display_name="$short_sha"
    fi
    
    # Set global variables for use by caller
    export RESOLVED_TARGET_SHA="$resolved_sha"
    export RESOLVED_TARGET_DISPLAY="$display_name ($short_sha: $subject)"
    export RESOLVED_TARGET_SOURCE="explicit"
    export RESOLVED_TARGET_METADATA="$metadata"
    export RESOLVED_TARGET_CONTEXT=""
    
    log INFO "Resolved target: $RESOLVED_TARGET_DISPLAY"
    log DEBUG "Full SHA: $RESOLVED_TARGET_SHA"
    
    return 0
}

# Get list of decorations (tags, branches) for a commit
# Args: commit_sha
# Returns: JSON array of decorations
get_commit_decorations() {
    local commit_sha="$1"
    
    if [[ -z "$commit_sha" ]]; then
        echo "[]"
        return 0
    fi
    
    # Get tags pointing to this commit
    local tags
    tags=$(git tag --points-at "$commit_sha" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    
    # Get branches containing this commit
    local branches
    branches=$(git branch --contains "$commit_sha" 2>/dev/null | sed 's/^[* ]*//' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    
    # Combine into single JSON object
    jq -n --argjson tags "$tags" --argjson branches "$branches" \
        '{tags: $tags, branches: $branches}'
}

# Check if target commit is ancestor of current HEAD
# Args: commit_sha
# Returns: 0 if ancestor, 1 if not
is_target_ancestor() {
    local commit_sha="$1"
    
    if [[ -z "$commit_sha" ]]; then
        return 1
    fi
    
    # Check if commit is ancestor of HEAD
    if git merge-base --is-ancestor "$commit_sha" HEAD 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Validate target is safe to reset to
# Args: commit_sha
# Returns: 0 if safe, adds warnings if concerns exist
validate_target_safety() {
    local commit_sha="$1"
    
    if [[ -z "$commit_sha" ]]; then
        log ERROR "No commit SHA provided for safety validation"
        return 2
    fi
    
    # Check if target is an ancestor of current HEAD
    if ! is_target_ancestor "$commit_sha"; then
        log WARN "Target commit is not an ancestor of current HEAD"
        log WARN "This reset will rewrite history and may cause divergence"
        
        # Add warning to plan if plan.sh is loaded
        if declare -f add_plan_warning >/dev/null 2>&1; then
            add_plan_warning "Target is not an ancestor of HEAD - history will diverge"
        fi
    fi
    
    # Check if there are uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log WARN "Working directory has uncommitted changes"
        log WARN "These changes may be lost during reset"
        
        if declare -f add_plan_warning >/dev/null 2>&1; then
            add_plan_warning "Uncommitted changes in working directory"
        fi
    fi
    
    # Check if target is very old (more than 30 days)
    local target_timestamp
    target_timestamp=$(git show -s --format=%at "$commit_sha" 2>/dev/null)
    
    if [[ -n "$target_timestamp" ]]; then
        local current_timestamp
        current_timestamp=$(date +%s)
        local age_days=$(( (current_timestamp - target_timestamp) / 86400 ))
        
        if [[ $age_days -gt 30 ]]; then
            log WARN "Target commit is $age_days days old"
            log WARN "Resetting to old commits may result in significant workflow changes"
            
            if declare -f add_plan_warning >/dev/null 2>&1; then
                add_plan_warning "Target commit is $age_days days old"
            fi
        fi
    fi
    
    return 0
}

# --- Time Window Resolution ---

# Parse time window and resolve to latest commit
# Args: since, until
# Returns: 0 on success, 2 on failure
parse_time_window() {
    local since="$1"
    local until="${2:-}"
    local resolved_sha=""
    local metadata=""

    if [[ -z "$since" ]]; then
        log ERROR "The --since flag is required when using time-window resets."
        log INFO "Example: n8n-git reset --since \"last friday 18:00\""
        return 2
    fi

    if ! resolved_sha=$(resolve_time_window_commit "$since" "$until" "HEAD"); then
        log ERROR "Unable to evaluate Git history for the requested time window."
        return 2
    fi

    if [[ -z "$resolved_sha" ]]; then
        log ERROR "No commits found between '${since}' and '${until:-now}'."
        log INFO "Use 'git log --since \"${since}\" --until \"${until:-now}\"' to inspect available commits."
        return 2
    fi

    metadata=$(get_commit_metadata "$resolved_sha")
    if [[ -z "$metadata" || "$metadata" == "{}" ]]; then
        log ERROR "Failed to read metadata for commit $resolved_sha"
        return 2
    fi

    local short_sha subject
    short_sha=$(echo "$metadata" | jq -r '.short_sha // empty')
    subject=$(echo "$metadata" | jq -r '.subject // empty')

    export RESOLVED_TARGET_SHA="$resolved_sha"
    export RESOLVED_TARGET_DISPLAY="${short_sha}: ${subject}"
    export RESOLVED_TARGET_SOURCE="time_window"
    export RESOLVED_TARGET_METADATA="$metadata"
    export RESOLVED_TARGET_CONTEXT
    RESOLVED_TARGET_CONTEXT=$(format_time_window_context "$since" "$until")

    validate_target_safety "$resolved_sha"
    return 0
}

# --- Interactive Resolution ---

# Launch interactive commit picker
# Returns: 0 on success, 130 on user abort, 2 on error
launch_interactive_picker() {
    local picker_output=""
    local picker_exit=0
    local capture_file=""
    local repo_label branch_label head_short

    repo_label="${github_repo:-${RESET_REPO_PATH:-$(pwd)}}"
    branch_label=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
    head_short=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log INFO "Interactive picker inspecting ${repo_label} (branch: ${branch_label}, HEAD: ${head_short})"

    capture_file=$(mktemp /tmp/n8n-reset-picker-XXXXXX)
    if [[ -z "$capture_file" || ! -f "$capture_file" ]]; then
        log ERROR "Unable to allocate capture buffer for interactive picker output."
        return 2
    fi
    : >"$capture_file"

    if RESET_PICKER_RESULT_PATH="$capture_file" interactive_commit_picker; then
        picker_output=$(tail -n 1 "$capture_file" | tr -d '\r')
        rm -f "$capture_file"
    else
        picker_exit=$?
        rm -f "$capture_file"
        return $picker_exit
    fi

    if [[ -z "$picker_output" ]]; then
        log ERROR "Interactive picker did not return a commit selection."
        return 2
    fi

    local commit_sha=""
    commit_sha=$(echo "$picker_output" | jq -r '.sha // empty')
    if [[ -z "$commit_sha" ]]; then
        log ERROR "Interactive picker did not return a commit SHA."
        return 2
    fi

    local short_sha subject display_label selection_label
    short_sha=$(echo "$picker_output" | jq -r '.short // empty')
    subject=$(echo "$picker_output" | jq -r '.subject // empty')
    display_label=$(echo "$picker_output" | jq -r '.display // empty')
    selection_label=$(echo "$picker_output" | jq -r '.selection // empty')

    if [[ -z "$display_label" ]]; then
        display_label="${short_sha}: ${subject}"
    fi

    local metadata
    metadata=$(get_commit_metadata "$commit_sha")

    export RESOLVED_TARGET_SHA="$commit_sha"
    export RESOLVED_TARGET_DISPLAY="$display_label"
    export RESOLVED_TARGET_SOURCE="interactive"
    export RESOLVED_TARGET_METADATA="$metadata"
    export RESOLVED_TARGET_CONTEXT="$selection_label"

    validate_target_safety "$commit_sha"
    return 0
}

# Export functions
export -f parse_explicit_target
export -f get_commit_decorations
export -f is_target_ancestor
export -f validate_target_safety
export -f parse_time_window
export -f launch_interactive_picker
