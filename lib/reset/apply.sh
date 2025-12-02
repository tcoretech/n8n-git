#!/usr/bin/env bash
# =========================================================
# lib/reset/apply.sh - Reset execution pipeline
# =========================================================
# Executes the reset plan by delegating content import to the
# pull pipeline and then applying workflow/folder removal operations.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------
# Dependency loading
# ---------------------------------------------------------
if [[ -z "${PROJECT_NAME:-}" ]]; then
    RESET_APPLY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/utils/common.sh
    [[ -f "$RESET_APPLY_DIR/utils/common.sh" ]] && source "$RESET_APPLY_DIR/utils/common.sh"
    # shellcheck source=lib/n8n/endpoints.sh
    [[ -f "$RESET_APPLY_DIR/n8n/endpoints.sh" ]] && source "$RESET_APPLY_DIR/n8n/endpoints.sh"
    # shellcheck source=lib/reset/plan.sh
    [[ -f "$RESET_APPLY_DIR/reset/plan.sh" ]] && source "$RESET_APPLY_DIR/reset/plan.sh"
    # shellcheck source=lib/pull/import.sh
    [[ -f "$RESET_APPLY_DIR/pull/import.sh" ]] && source "$RESET_APPLY_DIR/pull/import.sh"
fi

# ---------------------------------------------------------
# Folder ordering helper
# ---------------------------------------------------------
reset_apply_order_folders_for_removal() {
    if ((${#RESET_PLAN_REMOVE_FOLDERS[@]} == 0)); then
        return 0
    fi

    local folder_id
    for folder_id in "${RESET_PLAN_REMOVE_FOLDERS[@]}"; do
        local depth="${RESET_PLAN_FOLDER_DEPTH[$folder_id]:-0}"
        printf '%08d:%s\n' "$depth" "$folder_id"
    done | sort -r | cut -d':' -f2
}

# ---------------------------------------------------------
# Pull delegation
# ---------------------------------------------------------
perform_reset_pull() {
    local target_sha="$1"
    local dry_run="${2:-false}"
    local short_target=""

    if [[ -n "$target_sha" ]]; then
        short_target="${target_sha:0:12}"
    fi

    local pull_label="current checkout"
    if [[ -n "$short_target" ]]; then
        pull_label="$short_target"
    fi

    if [[ "$dry_run" == "true" ]]; then
        log DRYRUN "Would run pull pipeline for reset target ${pull_label}"
        return 0
    fi

    local workflows_mode="2" # Always use git repo source for reset
    # local workflows_mode="${restore_workflows_mode:-}"
    # if [[ -z "$workflows_mode" ]]; then
    #     workflows_mode="${workflows:-}"
    # fi
    # if [[ -z "$workflows_mode" ]]; then
    #     workflows_mode="2"
    # fi

    local folder_mode="${restore_folder_structure_preference:-auto}"
    if [[ "$folder_mode" == "auto" && "${folder_structure:-false}" == "true" ]]; then
        folder_mode="true"
    fi

    local preserve_ids_flag="${restore_preserve_ids:-false}"
    local no_overwrite_flag="${restore_no_overwrite:-false}"

    local pull_scope="/"
    local repo_scope="/"
    if [[ -n "$RESET_PLAN_PLAN_JSON" ]]; then
        pull_scope=$(jq -r '.pull.n8nPath // "/"' <<<"$RESET_PLAN_PLAN_JSON" 2>/dev/null || echo "/")
        repo_scope=$(jq -r '.pull.githubPath // "/"' <<<"$RESET_PLAN_PLAN_JSON" 2>/dev/null || echo "/")
        preserve_ids_flag=$(jq -r '.pull.preserveIds // false' <<<"$RESET_PLAN_PLAN_JSON" 2>/dev/null || echo "false")
        no_overwrite_flag=$(jq -r '.pull.noOverwrite // false' <<<"$RESET_PLAN_PLAN_JSON" 2>/dev/null || echo "false")
    fi

    log HEADER "Performing pull"
    log INFO "Reset target: ${pull_label}"
    log INFO "Pull scope: n8n-path='${pull_scope}' github-path='${repo_scope}'"

    # Deactivate reset git environment to prevent interference with pull operations
    deactivate_reset_git_env

    if ! pull_import "${container:-}" "${github_token:-}" "${github_repo:-}" "${github_branch:-}" \
        "$workflows_mode" "0" "$folder_mode" "$dry_run" "${credentials_folder_name:-.credentials}" "false" \
        "$preserve_ids_flag" "$no_overwrite_flag" "${RESET_REPO_PATH:-}"; then
        activate_reset_git_env
        log ERROR "Pull pipeline import failed"
        return 1
    fi

    activate_reset_git_env

    log SUCCESS "Pull pipeline import completed"
    return 0
}

# ---------------------------------------------------------
# Removal execution
# ---------------------------------------------------------
execute_reset_actions() {
    local dry_run="${1:-false}"
    local mode="${RESET_PLAN_MODE:-soft}"

    log HEADER "Removing Workflows and Folders"

    if [[ "$dry_run" == "true" ]]; then
        local workflow_id
        for workflow_id in "${RESET_PLAN_REMOVE_WORKFLOWS[@]}"; do
            local display="${RESET_PLAN_WORKFLOW_DISPLAY[$workflow_id]:-}"
            local action_label="archive"
            [[ "$mode" == "hard" ]] && action_label="delete"
            log DRYRUN "Would ${action_label} workflow ${workflow_id} (${display:-no display path})"
        done

        local folder_id
        for folder_id in "${RESET_PLAN_REMOVE_FOLDERS[@]}"; do
            local display="${RESET_PLAN_FOLDER_DISPLAY[$folder_id]:-}"
            log DRYRUN "Would delete folder ${folder_id} (${display:-no display path})"
        done
        return 0
    fi

    if ! prepare_n8n_api_auth "${container:-}"; then
        log ERROR "Failed to authenticate with n8n API"
        return 1
    fi

    local errors=0
    local workflows_processed=0
    local folders_processed=0

    local workflow_id
    for workflow_id in "${RESET_PLAN_REMOVE_WORKFLOWS[@]}"; do
        local display="${RESET_PLAN_WORKFLOW_DISPLAY[$workflow_id]:-}"
        local log_prefix="Workflow ${workflow_id}"
        [[ -n "$display" ]] && log_prefix="${display} (${workflow_id})"

        local match_type="${RESET_PLAN_REMOVAL_MATCH_TYPES[$workflow_id]:-remove}"
        local should_archive="false"
        if [[ "$mode" == "soft" && "$match_type" == "replace" ]]; then
            should_archive="true"
        fi

        if [[ "$should_archive" == "true" ]]; then
            log DEBUG "Archiving workflow: ${log_prefix}"
            if archive_workflow "$workflow_id" false; then
                ((workflows_processed++))
            else
                log ERROR "Failed to archive workflow ${workflow_id}"
                ((errors++))
            fi
        else
            log DEBUG "Deleting workflow: ${log_prefix}"
            if delete_workflow "$workflow_id" false false; then
                ((workflows_processed++))
            else
                log ERROR "Failed to delete workflow ${workflow_id}"
                ((errors++))
            fi
        fi
    done

    mapfile -t __reset_sorted_folders < <(reset_apply_order_folders_for_removal)
    local folder_id
    for folder_id in "${__reset_sorted_folders[@]}"; do
        [[ -z "$folder_id" ]] && continue
        local display="${RESET_PLAN_FOLDER_DISPLAY[$folder_id]:-}"
        local project_id="${RESET_PLAN_FOLDER_PROJECT_ID[$folder_id]:-}"
        local log_prefix="Folder ${folder_id}"
        [[ -n "$display" ]] && log_prefix="${display} (${folder_id})"

        log DEBUG "Deleting ${log_prefix}"
        if [[ -n "$project_id" && "$project_id" != "null" ]]; then
            if delete_folder "$folder_id" "$project_id"; then
                ((folders_processed++))
            else
                log ERROR "Failed to delete folder ${folder_id}"
                ((errors++))
            fi
        else
            if delete_folder "$folder_id"; then
                ((folders_processed++))
            else
                log ERROR "Failed to delete folder ${folder_id}"
                ((errors++))
            fi
        fi
    done

    finalize_n8n_api_auth

    RESET_PLAN_REMOVAL_COUNT_WORKFLOWS=$workflows_processed
    RESET_PLAN_REMOVAL_COUNT_FOLDERS=$folders_processed

    if ((errors > 0)); then
        log ERROR "Removals encountered ${errors} failure(s)"
        return 1
    fi

    log SUCCESS "Removals completed (${workflows_processed} workflow(s), ${folders_processed} folder(s))"
    return 0
}
