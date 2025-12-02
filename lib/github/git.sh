#!/bin/bash

# Git operations module for n8n-git
# Centralizes all Git-related functionality

# Source common utilities
# shellcheck disable=SC1091  # common helpers live one level up
source "$(dirname "${BASH_SOURCE[0]}")/../utils/common.sh"

GIT_LAST_STDERR=""

git_run_capture_stderr() {
    local stderr_file
    stderr_file="$(mktemp -t n8n-git-stderr-XXXXXXXX)"
    if "$@" 2>"$stderr_file"; then
        GIT_LAST_STDERR=""
        rm -f "$stderr_file"
        return 0
    fi

    if [[ -f "$stderr_file" ]]; then
        GIT_LAST_STDERR="$(<"$stderr_file")"
        GIT_LAST_STDERR="${GIT_LAST_STDERR%$'\n'}"
        GIT_LAST_STDERR="${GIT_LAST_STDERR%$'\r'}"
        GIT_LAST_STDERR="${GIT_LAST_STDERR//$'\r'/ }"
        GIT_LAST_STDERR="${GIT_LAST_STDERR//$'\n'/ ' | '}"
        rm -f "$stderr_file"
    else
        GIT_LAST_STDERR=""
    fi

    return 1
}

git_list_tree_paths() {
    local git_dir="$1"
    local commit_ref="$2"
    local scope_path="${3:-}"
    local __result_ref="${4:-}"

    if [[ -z "$git_dir" || ! -d "$git_dir/.git" ]]; then
        log ERROR "Missing Git directory for tree listing"
        return 1
    fi

    local target_ref="$commit_ref"
    if [[ -z "$target_ref" ]]; then
        target_ref="HEAD"
    fi

    local normalized_scope="${scope_path#/}"
    normalized_scope="${normalized_scope%/}"

    local stdout_file stderr_file
    stdout_file="$(mktemp -t n8n-git-tree-XXXXXXXX)"
    stderr_file="$(mktemp -t n8n-git-tree-err-XXXXXXXX)"

    local -a cmd=(git -C "$git_dir" ls-tree --full-tree -r --name-only "$target_ref")
    if [[ -n "$normalized_scope" ]]; then
        cmd+=(-- "$normalized_scope")
    fi

    if "${cmd[@]}" >"$stdout_file" 2>"$stderr_file"; then
        local listing
        listing="$(<"$stdout_file")"
        rm -f "$stdout_file" "$stderr_file"
        GIT_LAST_STDERR=""
        if [[ -n "$__result_ref" ]]; then
            printf -v "$__result_ref" '%s' "$listing"
        else
            printf '%s' "$listing"
        fi
        return 0
    fi

    if [[ -f "$stderr_file" ]]; then
        GIT_LAST_STDERR="$(<"$stderr_file")"
        GIT_LAST_STDERR="${GIT_LAST_STDERR%$'\n'}"
        GIT_LAST_STDERR="${GIT_LAST_STDERR%$'\r'}"
        GIT_LAST_STDERR="${GIT_LAST_STDERR//$'\r'/ }"
        GIT_LAST_STDERR="${GIT_LAST_STDERR//$'\n'/ ' | '}"
        rm -f "$stderr_file"
    else
        GIT_LAST_STDERR=""
    fi

    rm -f "$stdout_file"
    return 1
}

git_format_literal_pathspec() {
    local raw_path="$1"
    if [[ -z "$raw_path" ]]; then
        printf ':(literal)'
        return
    fi

    local normalized="$raw_path"
    normalized="${normalized#./}"
    printf ':(literal)%s' "$normalized"
}

git_stage_path_literal() {
    local git_dir="$1"
    local path="$2"

    if [[ -z "$git_dir" || -z "$path" ]]; then
        log ERROR "Missing parameters for git staging"
        return 1
    fi

    local pathspec
    pathspec="$(git_format_literal_pathspec "$path")"

    if git_run_capture_stderr git -C "$git_dir" add -- "$pathspec"; then
        return 0
    fi

    local add_error="$GIT_LAST_STDERR"
    local retry_performed=false

    if [[ "$add_error" == *"outside of your sparse-checkout definition"* ]]; then
        local parent_dir
        parent_dir="${path%/*}"
        
        if [[ "$parent_dir" == "$path" ]]; then
            parent_dir=""
        fi

        if [[ -z "$parent_dir" && "$path" == */* ]]; then
            parent_dir="${path%/*}"
        fi

        if [[ -n "$parent_dir" ]]; then
            if git_sparse_checkout_include_path "$git_dir" "$parent_dir"; then
                retry_performed=true
                if git_run_capture_stderr git -C "$git_dir" add -- "$pathspec"; then
                    return 0
                fi
                add_error="$GIT_LAST_STDERR"
            fi
        fi
    fi

    if [[ -n "$add_error" ]]; then
        if $retry_performed; then
            log DEBUG "git add stderr after retry: $add_error"
        else
            log DEBUG "git add stderr: $add_error"
        fi
    fi

    return 1
}

git_path_tracked_literal() {
    local git_dir="$1"
    local path="$2"

    if [[ -z "$git_dir" || -z "$path" ]]; then
        return 1
    fi

    local pathspec
    pathspec="$(git_format_literal_pathspec "$path")"

    if git_run_capture_stderr git -C "$git_dir" ls-files --error-unmatch -- "$pathspec" >/dev/null; then
        return 0
    fi

    return 1
}

git_sparse_checkout_include_path() {
    local git_dir="$1"
    local target_path="$2"

    if [[ -z "$git_dir" || -z "$target_path" ]]; then
        return 1
    fi

    local normalized="$target_path"
    normalized="${normalized#./}"
    normalized="${normalized%/}"

    if [[ -z "$normalized" ]]; then
        return 1
    fi

    if git_run_capture_stderr git -C "$git_dir" sparse-checkout add --skip-checks "$normalized" >/dev/null; then
        return 0
    fi

    if [[ -n "$GIT_LAST_STDERR" ]]; then
        log DEBUG "git sparse-checkout add stderr: $GIT_LAST_STDERR"
    fi

    if git_run_capture_stderr git -C "$git_dir" sparse-checkout set --skip-checks --add "$normalized" >/dev/null; then
        return 0
    fi

    if [[ -n "$GIT_LAST_STDERR" ]]; then
        log DEBUG "git sparse-checkout set --add stderr: $GIT_LAST_STDERR"
    fi

    local temp_file
    temp_file="$(mktemp -t n8n-git-sparse-XXXXXXXX)"
    if git -C "$git_dir" sparse-checkout list >"$temp_file" 2>/dev/null; then
        if ! grep -Fxq "$normalized" "$temp_file"; then
            printf '%s\n' "$normalized" >>"$temp_file"
        fi
        if git_run_capture_stderr git -C "$git_dir" sparse-checkout set --skip-checks --stdin <"$temp_file" >/dev/null; then
            rm -f "$temp_file"
            return 0
        fi
        if [[ -n "$GIT_LAST_STDERR" ]]; then
            log DEBUG "git sparse-checkout set --stdin stderr: $GIT_LAST_STDERR"
        fi
    fi
    rm -f "$temp_file" 2>/dev/null || true

    return 1
}

git_configure_sparse_checkout() {
    local git_dir="$1"
    local target_path="$2"
    local checkout_branch="$3"

    if [[ -z "$git_dir" || -z "$target_path" ]]; then
        log ERROR "Missing parameters for sparse checkout configuration"
        return 1
    fi

    local init_args=(git -C "$git_dir" sparse-checkout init --cone)
    if ! git_run_capture_stderr "${init_args[@]}" >/dev/null; then
        if [[ -n "$GIT_LAST_STDERR" ]]; then
            log DEBUG "git sparse-checkout init stderr: $GIT_LAST_STDERR"
        fi
        if ! git_run_capture_stderr git -C "$git_dir" config core.sparseCheckout true; then
            if [[ -n "$GIT_LAST_STDERR" ]]; then
                log WARN "Unable to enable sparse checkout: $GIT_LAST_STDERR"
            else
                log WARN "Unable to enable sparse checkout via core.sparseCheckout"
            fi
            return 1
        fi
    fi

    local normalized_target="$target_path"
    normalized_target="${normalized_target#./}"
    normalized_target="${normalized_target%/}"
    if [[ -z "$normalized_target" ]]; then
        normalized_target="."
    fi

    local set_success=false
    if git_run_capture_stderr git -C "$git_dir" sparse-checkout set --skip-checks "$normalized_target" >/dev/null; then
        set_success=true
    else
        if [[ -n "$GIT_LAST_STDERR" ]]; then
            log DEBUG "git sparse-checkout set (skip-checks) stderr: $GIT_LAST_STDERR"
        fi

        if git_run_capture_stderr git -C "$git_dir" sparse-checkout set "$normalized_target" >/dev/null; then
            set_success=true
        fi
    fi

    if ! $set_success; then
        if [[ -n "$GIT_LAST_STDERR" ]]; then
            log WARN "Sparse checkout configuration failed: $GIT_LAST_STDERR"
        else
            log WARN "Sparse checkout configuration failed for target: $target_path"
        fi
        return 1
    fi

    if [[ -n "$checkout_branch" ]]; then
        if ! git_run_capture_stderr git -C "$git_dir" checkout "$checkout_branch" >/dev/null; then
            if [[ -n "$GIT_LAST_STDERR" ]]; then
                log WARN "Sparse checkout branch checkout failed: $GIT_LAST_STDERR"
            else
                log WARN "Sparse checkout branch checkout failed for $checkout_branch"
            fi
            return 1
        fi
    fi

    log SUCCESS "Sparse checkout active for $target_path"
    return 0
}

# Initialize Git repository for push storage
init_git_repo() {
    local backup_dir="$1"
    
    if [[ -z "$backup_dir" ]]; then
        log "ERROR" "Push directory not specified for Git initialization"
        return 1
    fi
    
    cd "$backup_dir" || {
        log "ERROR" "Failed to change to push directory: $backup_dir"
        return 1
    }
    
    if [[ ! -d ".git" ]]; then
        log "INFO" "Initializing Git repository in $backup_dir"
        git init || {
            log "ERROR" "Failed to initialize Git repository"
            return 1
        }
        
        # Create initial commit
        {
            printf '# n8n Push Repository\n\n'
            printf 'This repository contains automated push exports of n8n workflows and credentials.\n'
            printf 'Generated by n8n-git on %s\n' "$(date)"
        } > README.md
        
        git add README.md
        git commit -m "Initial commit - n8n push repository" || {
            log "ERROR" "Failed to create initial commit"
            return 1
        }
        
        log "SUCCESS" "Git repository initialized successfully"
    else
        log "DEBUG" "Git repository already exists"
    fi
    
    return 0
}

# Commit individual workflow file
commit_individual_workflow() {
    local file_path="$1"
    local commit_message="$2"
    local git_dir="$3"

    if [[ -z "$file_path" || -z "$git_dir" ]]; then
        log "ERROR" "Missing required parameters for individual workflow commit"
        return 1
    fi

    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }

    if ! git_stage_path_literal "$git_dir" "$file_path"; then
        log "ERROR" "Failed to stage file: $file_path"
        return 1
    fi

    local display_path="${file_path#./}"
    if git diff --cached --quiet; then
        log "DEBUG" "No changes to commit for workflow: ${display_path:-$file_path}"
        return 2
    fi

    if [[ -z "$commit_message" ]]; then
        commit_message="Workflow update"
    fi

    local commit_output=""
    if ! commit_output=$(git commit -m "$commit_message" 2>&1); then
        log "ERROR" "Failed to commit workflow changes"
        if [[ -n "$commit_output" ]]; then
            while IFS= read -r commit_line; do
                [[ -z "$commit_line" ]] && continue
                log "ERROR" "git commit: $commit_line"
            done <<< "$commit_output"
        fi
        return 1
    fi

    if [[ "$verbose" == "true" && -n "$commit_output" ]]; then
        while IFS= read -r commit_line; do
            [[ -z "$commit_line" ]] && continue
            log "DEBUG" "git commit: $commit_line"
        done <<< "$commit_output"
    fi

    log "SUCCESS" "Committed workflow change: $commit_message"
    return 0
}

commit_individual_credential() {
    local file_path="$1"
    local commit_message="$2"
    local git_dir="$3"
    local additional_path="${4:-}"

    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Missing Git directory for credential commit"
        return 1
    fi

    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }

    if [[ -n "$additional_path" ]]; then
        if ! git_stage_path_literal "$git_dir" "$additional_path"; then
            log "ERROR" "Failed to stage credential path: $additional_path"
            return 1
        fi
    fi

    if [[ -n "$file_path" ]]; then
        if ! git_stage_path_literal "$git_dir" "$file_path"; then
            log "ERROR" "Failed to stage credential path: $file_path"
            return 1
        fi
    fi

    local target_display="${file_path:-$additional_path}"
    if git diff --cached --quiet; then
        log "DEBUG" "No changes to commit for credential: ${target_display:-<unknown>}"
        return 2
    fi

    if [[ -z "$commit_message" ]]; then
        commit_message="Credential update"
    fi

    local commit_output=""
    if ! commit_output=$(git commit -m "$commit_message" 2>&1); then
        log "ERROR" "Failed to commit credential changes"
        if [[ -n "$commit_output" ]]; then
            while IFS= read -r commit_line; do
                [[ -z "$commit_line" ]] && continue
                log "ERROR" "git commit: $commit_line"
            done <<< "$commit_output"
        fi
        return 1
    fi

    if [[ "$verbose" == "true" && -n "$commit_output" ]]; then
        while IFS= read -r commit_line; do
            [[ -z "$commit_line" ]] && continue
            log "DEBUG" "git commit: $commit_line"
        done <<< "$commit_output"
    fi

    log "SUCCESS" "Committed credential change: $commit_message"
    return 0
}

commit_deleted_workflow() {
    local file_path="$1"
    local workflow_name="$2"
    local git_dir="$3"

    if [[ -z "$file_path" || -z "$workflow_name" || -z "$git_dir" ]]; then
        log "ERROR" "Missing required parameters for deleted workflow commit"
        return 1
    fi

    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }

    if ! git_stage_path_literal "$git_dir" "$file_path"; then
        log "ERROR" "Failed to stage workflow deletion: $file_path"
        return 1
    fi

    if git diff --cached --quiet; then
        log "DEBUG" "No deletion changes to commit for workflow: $workflow_name"
        return 0
    fi

    local timestamp_label
    timestamp_label="$(date '+%H:%M %d/%m/%y')"

    local commit_subject="$workflow_name"

    # Derive folder-aware subject from relative path when available
    if [[ -n "$file_path" ]]; then
        local normalized_path="${file_path#./}"
        local path_dir="${normalized_path%/*}"
        local path_file="${normalized_path##*/}"
        local base_name="${path_file%.json}"

        if [[ -n "$path_dir" && "$path_dir" != "$normalized_path" ]]; then
            commit_subject="$path_dir/$base_name"
        elif [[ -n "$base_name" ]]; then
            commit_subject="$base_name"
        fi
    fi

    local commit_msg="[Deleted] (${timestamp_label}) - ${commit_subject}"
    if ! git commit -m "$commit_msg" >/dev/null 2>&1; then
        log "ERROR" "Failed to commit workflow deletion: $workflow_name"
        return 1
    fi

    log "SUCCESS" "Committed workflow deletion: ${commit_subject}"
    return 0
}

# Commit credentials file
commit_credentials() {
    local git_dir="$1"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for credentials commit"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    local -a credential_targets=()
    while IFS= read -r dir; do
        credential_targets+=("${dir#./}")
    done < <(find . -type d -name '.credentials' -print 2>/dev/null | sort)

    if [[ -f "credentials.json" ]]; then
        credential_targets+=("credentials.json")
    fi

    if ((${#credential_targets[@]} == 0)); then
        log "DEBUG" "No credential artifacts found to commit"
        return 0
    fi

    if ! git add "${credential_targets[@]}"; then
        log "ERROR" "Failed to stage credential artifacts"
        return 1
    fi

    if ! git diff --cached --quiet; then
        git commit -m "[updated] credentials" || {
            log "ERROR" "Failed to commit credentials"
            return 1
        }
        log "SUCCESS" "Committed credentials"
    else
        log "DEBUG" "No changes to commit for credentials"
    fi
    
    return 0
}

# Commit all changes at once (bulk commit)
commit_bulk_changes() {
    local git_dir="$1"
    local commit_message="$2"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for bulk commit"
        return 1
    fi
    
    if [[ -z "$commit_message" ]]; then
        commit_message="Backup update - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    # Stage all changes
    git add . || {
        log "ERROR" "Failed to stage changes"
        return 1
    }
    
    # Check if there are changes to commit
    if git diff --cached --quiet; then
        log "INFO" "No changes to commit"
        return 0
    fi
    
    # Commit changes
    git commit -m "$commit_message" || {
        log "ERROR" "Failed to commit changes"
        return 1
    }
    
    log "SUCCESS" "Committed all changes: $commit_message"
    return 0
}

# Create Git tag for push point
create_backup_tag() {
    local git_dir="$1"
    local tag_name="$2"
    local tag_message="$3"
    
    if [[ -z "$git_dir" || -z "$tag_name" ]]; then
        log "ERROR" "Missing required parameters for Git tag creation"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    if [[ -z "$tag_message" ]]; then
        tag_message="Backup point created on $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Create annotated tag
    git tag -a "$tag_name" -m "$tag_message" || {
        log "ERROR" "Failed to create Git tag: $tag_name"
        return 1
    }
    
    log "SUCCESS" "Created Git tag: $tag_name"
    return 0
}

# List available push tags
list_backup_tags() {
    local git_dir="$1"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for listing tags"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    log "INFO" "Available push tags:"
    git tag -l --sort=-version:refname || {
        log "ERROR" "Failed to list Git tags"
        return 1
    }
    
    return 0
}

# Checkout specific push tag
checkout_backup_tag() {
    local git_dir="$1"
    local tag_name="$2"
    
    if [[ -z "$git_dir" || -z "$tag_name" ]]; then
        log "ERROR" "Missing required parameters for Git tag checkout"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    # Verify tag exists
    if ! git tag -l | grep -q "^$tag_name$"; then
        log "ERROR" "Git tag does not exist: $tag_name"
        return 1
    fi
    
    # Checkout the tag
    git checkout "$tag_name" || {
        log "ERROR" "Failed to checkout Git tag: $tag_name"
        return 1
    }
    
    log "SUCCESS" "Checked out Git tag: $tag_name"
    return 0
}

# Return to main branch
checkout_main_branch() {
    local git_dir="$1"
    local branch_name="${2:-main}"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for branch checkout"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    # Checkout main branch
    git checkout "$branch_name" || {
        log "ERROR" "Failed to checkout branch: $branch_name"
        return 1
    }
    
    log "SUCCESS" "Checked out branch: $branch_name"
    return 0
}

# Get Git repository status
get_git_status() {
    local git_dir="$1"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for status check"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    log "INFO" "Git repository status:"
    git status --porcelain || {
        log "ERROR" "Failed to get Git status"
        return 1
    }
    
    return 0
}

# Show Git log
show_git_log() {
    local git_dir="$1"
    local limit="${2:-10}"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for log display"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    log "INFO" "Recent Git commits (last $limit):"
    git log --oneline -n "$limit" || {
        log "ERROR" "Failed to show Git log"
        return 1
    }
    
    return 0
}

# Verify Git repository integrity
verify_git_repo() {
    local git_dir="$1"
    
    if [[ -z "$git_dir" ]]; then
        log "ERROR" "Git directory not specified for verification"
        return 1
    fi
    
    cd "$git_dir" || {
        log "ERROR" "Failed to change to git directory: $git_dir"
        return 1
    }
    
    # Check if it's a Git repository
    if [[ ! -d ".git" ]]; then
        log "ERROR" "Not a Git repository: $git_dir"
        return 1
    fi
    
    # Verify repository integrity
    git fsck --full --strict || {
        log "ERROR" "Git repository integrity check failed"
        return 1
    }
    
    log "SUCCESS" "Git repository verification passed"
    return 0
}
