#!/usr/bin/env bash
# =========================================================
# lib/github/git_ops.sh - Shared Git operations for n8n-git flows
# =========================================================
# Provides sparse-checkout management and workflow commit summarization
# shared between push/pull orchestration modules.

push_refresh_sparse_checkout() {
    local git_dir="$1"
    local initial_prefix="$2"
    local desired_prefix="${3:-}"

    if [[ -z "$git_dir" ]]; then
        return 0
    fi

    local resolved_prefix=""
    if [[ -n "$desired_prefix" ]]; then
        resolved_prefix="${desired_prefix#/}"
        resolved_prefix="${resolved_prefix%/}"
    else
        resolved_prefix="$(resolve_repo_base_prefix)"
        resolved_prefix="${resolved_prefix#/}"
        resolved_prefix="${resolved_prefix%/}"
    fi

    if [[ "$verbose" == "true" ]]; then
        log DEBUG "Resolving repo base prefix for sparse refresh: '${resolved_prefix:-<root>}'"
    fi

    if [[ -z "$resolved_prefix" ]]; then
        return 0
    fi

    local initial_trimmed="${initial_prefix#/}"
    initial_trimmed="${initial_trimmed%/}"

    if [[ "$initial_trimmed" == "$resolved_prefix" ]]; then
        return 0
    fi

    if ! git -C "$git_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi

    log DEBUG "Updating sparse checkout paths to include: $resolved_prefix"

    git -C "$git_dir" sparse-checkout init --cone >/dev/null 2>&1 || true

    if git -C "$git_dir" sparse-checkout -h 2>&1 | grep -q -- '--add'; then
        if git -C "$git_dir" sparse-checkout add "$resolved_prefix" >/dev/null 2>&1; then
            git -C "$git_dir" read-tree -mu HEAD >/dev/null 2>&1 || true
            return 0
        fi
    fi

    if git -C "$git_dir" sparse-checkout set "$resolved_prefix" >/dev/null 2>&1; then
        git -C "$git_dir" read-tree -mu HEAD >/dev/null 2>&1 || true
        return 0
    fi

    if git -C "$git_dir" sparse-checkout disable >/dev/null 2>&1; then
        log WARN "Sparse checkout disabled to allow path: $resolved_prefix"
        return 0
    fi

    log WARN "Failed to adjust sparse checkout for path: $resolved_prefix"
    return 0
}

push_generate_workflow_commit_message() {
    local target_dir="$1"
    local is_dry_run="$2"

    local new_files updated_files deleted_files

    if [[ "$is_dry_run" == true ]]; then
        echo "Push workflow changes (dry run)"
        return 0
    fi

    pushd "$target_dir" >/dev/null || return 1

    local status_output
    status_output=$(git status --porcelain 2>/dev/null || true)

    new_files=$(printf '%s\n' "$status_output" | awk '/^A /{count++} END {print count+0}')
    updated_files=$(printf '%s\n' "$status_output" | awk '/^M /{count++} END {print count+0}')
    deleted_files=$(printf '%s\n' "$status_output" | awk '/^D /{count++} END {print count+0}')

    popd >/dev/null || return 1

    local commit_parts=()
    if [[ $new_files -gt 0 ]]; then
        commit_parts+=("$new_files new")
    fi
    if [[ $updated_files -gt 0 ]]; then
        commit_parts+=("$updated_files updated")
    fi
    if [[ $deleted_files -gt 0 ]]; then
        commit_parts+=("$deleted_files deleted")
    fi

    if [[ ${#commit_parts[@]} -eq 0 ]]; then
        echo "No workflow changes"
        return 0
    fi

    local summary=""
    for i in "${!commit_parts[@]}"; do
        if [[ $i -gt 0 ]]; then
            summary+="; "
        fi
        summary+="${commit_parts[$i]}"
    done

    echo "$summary"
}

