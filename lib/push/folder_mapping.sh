#!/usr/bin/env bash
# =========================================================
# lib/push/folder_mapping.sh - Workflow folder organization helpers
# =========================================================
# Hosts folder mapping metadata utilities, flat fallback logic, and
# organization routines used by the push export flow.

push_apply_mapping_metadata() {
    local mapping_json="$1"

    if [[ -z "$mapping_json" ]]; then
        return 1
    fi

    local mapping_selected_name
    mapping_selected_name=$(jq -r '.selectedProject.name // empty' <<<"$mapping_json" 2>/dev/null || true)
    if [[ -n "$mapping_selected_name" && "$mapping_selected_name" != "null" ]]; then
        set_project_from_path "$mapping_selected_name"
    fi

    return 0
}

push_print_folder_structure_preview() {
    local base_dir="$1"
    local max_files=${2:-5}

    if [[ ! -d "$base_dir" ]]; then
        log WARN "Folder structure preview skipped - directory missing: $base_dir"
        return
    fi

    log INFO "Workflow folder structure created:"

    local base_prefix="${base_dir%/}/"

    local root_files=()
    while IFS= read -r file; do
        root_files+=("$file")
    done < <(find "$base_dir" -maxdepth 1 -type f -name '*.json' | sort | head -n "$max_files")
    if ((${#root_files[@]} > 0)); then
        log INFO "(root)"
        for file in "${root_files[@]}"; do
            log INFO "- $(basename "$file")"
        done
        local total_root
        total_root=$(find "$base_dir" -maxdepth 1 -type f -name '*.json' | wc -l)
        if (( total_root > ${#root_files[@]} )); then
            log INFO "- < + $((total_root - ${#root_files[@]})) more >"
        fi
    fi

    while IFS= read -r dir; do
        local relative="${dir#"$base_prefix"}"
        if [[ "$relative" == "$dir" ]]; then
            relative=$(basename "$dir")
        fi

        # Skip credentials directory from workflow preview
        if [[ -n "${credentials_folder_name:-}" ]]; then
            if [[ "$relative" == "${credentials_folder_name}" || "$relative" == *"/${credentials_folder_name}" ]]; then
                continue
            fi
            if [[ "$relative" == "${credentials_folder_name}/"* || "$relative" == *"/${credentials_folder_name}/"* ]]; then
                continue
            fi
        fi

        IFS='/' read -r -a parts <<< "$relative"
        local depth=${#parts[@]}
        local name_index=$((depth - 1))
        local name="${parts[$name_index]}"
        local prefix=""
        if (( depth > 1 )); then
            for ((i=1; i<depth; i++)); do
                prefix+="-"
            done
            prefix+=" "
        fi

        log INFO "${prefix}${name}"

        local files=()
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$dir" -maxdepth 1 -type f -name '*.json' | sort | head -n "$max_files")
        if ((${#files[@]} > 0)); then
            local file_prefix=""
            for ((i=0; i<depth; i++)); do
                file_prefix+="-"
            done
            file_prefix+=" "

            for file in "${files[@]}"; do
                log INFO "${file_prefix}$(basename "$file")"
            done

            local total_count
            total_count=$(find "$dir" -maxdepth 1 -type f -name '*.json' | wc -l)
            if (( total_count > ${#files[@]} )); then
                log INFO "${file_prefix}< + $((total_count - ${#files[@]})) more >"
            fi
        fi
    done < <(find "$base_dir" -mindepth 1 -type d -not -path '*/.git*' | sort)
}

push_copy_workflows_flat_with_names() {
    local source_dir="$1"
    local target_dir="$2"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log WARN "Fallback copy skipped - source directory missing: $source_dir"
        return 1
    fi

    local root_dir="$target_dir"
    local repo_prefix
    repo_prefix="$(resolve_repo_base_prefix)"
    if [[ -n "$repo_prefix" ]]; then
        root_dir="$target_dir/$repo_prefix"
    fi

    if ! mkdir -p "$root_dir"; then
        log WARN "Fallback copy failed - could not ensure target directory: $root_dir"
        return 1
    fi

    local -A registry=()
    local success=true

    while IFS= read -r -d '' workflow_file; do
        local workflow_id
        workflow_id=$(jq -r '.id // empty' "$workflow_file" 2>/dev/null)
        local workflow_name
        workflow_name=$(jq -r '.name // "Unnamed Workflow"' "$workflow_file" 2>/dev/null)

        local filename
        filename=$(push_generate_unique_workflow_filename "$root_dir" "$workflow_id" "$workflow_name" registry)

        if [[ -z "$filename" ]]; then
            log WARN "Skipped workflow during fallback - could not derive filename"
            success=false
            continue
        fi

        if ! cp "$workflow_file" "$root_dir/$filename"; then
            log WARN "Failed to copy workflow to fallback target: $filename"
            success=false
            continue
        fi

        if ! push_prettify_json_file "$root_dir/$filename"; then
            log WARN "Failed to prettify workflow JSON: $filename"
            success=false
            continue
        fi
    done < <(find "$source_dir" -type f -name "*.json" -print0)

    if [[ "$success" == "true" ]]; then
        log SUCCESS "Workflows copied to Git repository (flat structure fallback)"
        return 0
    fi

    return 1
}

push_organize_workflows_by_folders() {
    local source_dir="$1"
    local target_dir="$2"
    local mapping_json="$3"
    local git_dir="$4"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Workflow export directory missing: $source_dir"
        return 1
    fi

    if [[ -z "$target_dir" ]]; then
        log ERROR "Target directory not specified for workflow organization"
        return 1
    fi

    if [[ -z "$git_dir" || ! -d "$git_dir" ]]; then
        log ERROR "Git directory not accessible: $git_dir"
        return 1
    fi

    if ! mkdir -p "$target_dir"; then
        log ERROR "Failed to ensure target directory exists: $target_dir"
        return 1
    fi

    local mapping_file
    mapping_file=$(mktemp /tmp/n8n-workflow-mapping-XXXXXXXX)
    printf '%s' "$mapping_json" > "$mapping_file"

    if ! jq -e '.workflowsById | type == "object"' "$mapping_file" >/dev/null 2>&1; then
        log ERROR "Workflow mapping JSON missing workflowsById object"
        local debug_preview
        debug_preview=$(head -c 500 "$mapping_file" 2>/dev/null || echo "<unavailable>")
        local mapping_size
        mapping_size=$(wc -c < "$mapping_file" 2>/dev/null || echo 0)
        log DEBUG "Mapping JSON preview (first 500 chars): ${debug_preview}$( [ "$mapping_size" -gt 500 ] && echo '…')"
        log DEBUG "Full mapping saved for inspection at: $mapping_file"
        return 1
    fi

    local new_count=0
    local updated_count=0
    local unchanged_count=0
    local deleted_count=0
    local commit_fail=false

    local git_prefix="${git_dir%/}/"
    local -A expected_files=()
    local -A filename_registry=()

    local effective_project_id
    effective_project_id=$(jq -r '.selectedProject.id // empty' "$mapping_file" 2>/dev/null || true)
    local effective_project_name
    effective_project_name=$(jq -r '.selectedProject.name // empty' "$mapping_file" 2>/dev/null || true)
    local default_project_name_meta
    default_project_name_meta=$(jq -r '.defaultProject.name // empty' "$mapping_file" 2>/dev/null || true)
    local path_filter_display
    path_filter_display=$(jq -r '.filters.n8nPath // empty' "$mapping_file" 2>/dev/null || true)
    if [[ -z "$effective_project_name" ]]; then
        effective_project_name="$default_project_name_meta"
    fi

    local project_filter_label="$effective_project_name"
    [[ -z "$project_filter_label" ]] && project_filter_label="$PERSONAL_PROJECT_TOKEN"

    local path_filter_label="$path_filter_display"
    if [[ -z "$path_filter_label" && -n "${n8n_path:-}" ]]; then
        path_filter_label="$n8n_path"
    fi

    while IFS= read -r -d '' workflow_file; do
        local workflow_id
        workflow_id=$(jq -r '.id // empty' "$workflow_file" 2>/dev/null)

        if [[ -z "$workflow_id" ]]; then
            log WARN "Skipping workflow file without ID: $workflow_file"
            continue
        fi

        local workflow_name
        workflow_name=$(jq -r '.name // "Unnamed Workflow"' "$workflow_file" 2>/dev/null)

        local relative_path
        relative_path=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].relativePath // empty' "$mapping_file" 2>/dev/null)
        local display_path
        display_path=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].displayPath // empty' "$mapping_file" 2>/dev/null)
        local project_id
        project_id=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].project.id // empty' "$mapping_file" 2>/dev/null)
        local workflow_project_name
        workflow_project_name=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].project.name // empty' "$mapping_file" 2>/dev/null)
        local folder_segments_json
        folder_segments_json=$(jq -c --arg id "$workflow_id" '.workflowsById[$id].folders // []' "$mapping_file" 2>/dev/null)
        if [[ -z "$folder_segments_json" || "$folder_segments_json" == "null" ]]; then
            folder_segments_json="[]"
        fi
        local folder_path_from_segments=""
        if [[ "$folder_segments_json" != "[]" ]]; then
            folder_path_from_segments=$(jq -r '[.[].name // "" | select(length>0)] | join("/")' <<<"$folder_segments_json" 2>/dev/null || echo "")
        fi
        folder_path_from_segments="${folder_path_from_segments#/}"
        folder_path_from_segments="${folder_path_from_segments%/}"
        relative_path="$folder_path_from_segments"
        local workflow_project_identifier="${workflow_project_name:-}"
        if [[ -z "$workflow_project_identifier" || "$workflow_project_identifier" == "null" ]]; then
            workflow_project_identifier="$effective_project_name"
        fi

        local matches_project="true"
        if [[ -n "$effective_project_id" ]]; then
            if [[ -z "$project_id" || "$project_id" != "$effective_project_id" ]]; then
                matches_project="false"
            fi
        fi

        if [[ "$matches_project" != "true" && -n "$effective_project_name" && -n "$workflow_project_identifier" ]]; then
            if [[ "${workflow_project_identifier,,}" == "${effective_project_name,,}" ]]; then
                matches_project="true"
            fi
        fi

        if [[ "$matches_project" != "true" ]]; then
            log DEBUG "Skipping workflow $workflow_id (project '$workflow_project_identifier') due to project filter '${project_filter_label:-$effective_project_name}'"
            continue
        fi

        if [[ -z "$display_path" || "$display_path" == "null" ]]; then
            if [[ -n "$workflow_project_identifier" ]]; then
                display_path="$workflow_project_identifier"
            elif [[ -n "$effective_project_name" ]]; then
                display_path="$effective_project_name"
            else
                display_path="$relative_path"
            fi
        fi

        local matches_path="true"
        if [[ -n "$path_filter_label" ]]; then
            case "$relative_path" in
                "$path_filter_label"|"$path_filter_label"/*) ;;
                *) matches_path="false" ;;
            esac
        fi

        if [[ "$matches_path" != "true" ]]; then
            local display_filter="$path_filter_label"
            if [[ -z "$display_filter" ]]; then
                if [[ -n "${n8n_path:-}" ]]; then
                    display_filter="$n8n_path"
                else
                    display_filter="<project root>"
                fi
            fi
            log DEBUG "Skipping workflow $workflow_id (path '$display_path') due to n8n path filter '$display_filter'"
            continue
        fi

        relative_path="${relative_path#/}"
        relative_path="${relative_path%/}"

        local storage_relative_path
        storage_relative_path="$(compose_repo_storage_path "$relative_path")"

        local destination_dir="$target_dir"
        if [[ -n "$storage_relative_path" ]]; then
            destination_dir="$target_dir/$storage_relative_path"
        fi
        if ! mkdir -p "$destination_dir"; then
            log WARN "Failed to create destination directory: $destination_dir"
            commit_fail=true
            continue
        fi

        local generated_filename
        generated_filename=$(push_generate_unique_workflow_filename "$destination_dir" "$workflow_id" "$workflow_name" filename_registry)

        if [[ -z "$generated_filename" ]]; then
            log WARN "Skipping workflow ${workflow_id:-unknown} - unable to determine filename"
            commit_fail=true
            continue
        fi

        local target_file="$destination_dir/$generated_filename"
        expected_files["$target_file"]=1

        if [[ -f "$target_file" ]] && cmp -s "$workflow_file" "$target_file" 2>/dev/null; then
            unchanged_count=$((unchanged_count + 1))
            continue
        fi

        if ! cp "$workflow_file" "$target_file"; then
            log WARN "Failed to copy workflow ${workflow_id:-unknown} to $target_file"
            commit_fail=true
            continue
        fi

        if ! push_prettify_json_file "$target_file"; then
            log WARN "Failed to prettify workflow JSON: $target_file"
            commit_fail=true
        fi

        local relative_git_path=""
        if [[ "$target_file" == "$git_prefix"* ]]; then
            relative_git_path="${target_file#"$git_prefix"}"
        else
            log WARN "Workflow file resides outside Git directory: $target_file"
            commit_fail=true
            continue
        fi

        local is_new="true"
        if git_path_tracked_literal "$git_dir" "$relative_git_path"; then
            is_new="false"
        fi

        if [[ "$is_new" == "true" ]]; then
            new_count=$((new_count + 1))
        else
            updated_count=$((updated_count + 1))
        fi

        local commit_subject="$workflow_name"
        if [[ -n "$relative_path" ]]; then
            commit_subject="${relative_path}/${workflow_name}"
        fi

        local active_flag
        active_flag=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].active // false' "$mapping_file" 2>/dev/null || echo "false")
        local active_state="[inactive]"
        if [[ "${active_flag,,}" == "true" ]]; then
            active_state="[active]"
        fi

        local status_label="Updated"
        if [[ "$is_new" == "true" ]]; then
            status_label="New"
        fi

        local updated_at_raw
        updated_at_raw=$(jq -r '.updatedAt // .createdAt // empty' "$target_file" 2>/dev/null || echo "")
        if [[ -z "$updated_at_raw" || "$updated_at_raw" == "null" ]]; then
            updated_at_raw=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].updatedAt // .workflowsById[$id].createdAt // empty' "$mapping_file" 2>/dev/null || echo "")
        fi

        local timestamp_display
        if [[ -n "$updated_at_raw" && "$updated_at_raw" != "null" ]]; then
            timestamp_display="$(date -d "$updated_at_raw" '+%H:%M %d/%m/%y' 2>/dev/null || date '+%H:%M %d/%m/%y')"
        else
            timestamp_display="$(date '+%H:%M %d/%m/%y')"
        fi

        local commit_message="[${status_label}] (${timestamp_display}) - ${commit_subject} ${active_state}"
        commit_message="${commit_message%% }"

        local workflow_commit_status=0
        commit_individual_workflow "$relative_git_path" "$commit_message" "$git_dir"
        workflow_commit_status=$?
        if [[ $workflow_commit_status -eq 1 ]]; then
            commit_fail=true
        fi
    done < <(find "$source_dir" -type f -name "*.json" -not -path "*/.git/*" -print0)

    local storage_base_prefix
    storage_base_prefix="$(resolve_repo_base_prefix)"
    storage_base_prefix="${storage_base_prefix#/}"
    storage_base_prefix="${storage_base_prefix%/}"

    local cleanup_root="$target_dir"
    if [[ -n "$storage_base_prefix" ]]; then
        cleanup_root="$target_dir/$storage_base_prefix"
    fi

    local cleanup_root_exists=true
    if [[ ! -d "$cleanup_root" ]]; then
        cleanup_root_exists=false
    fi

    local credentials_cleanup_root=""
    local credentials_cleanup_prefix=""
    if [[ -n "${credentials_folder_name:-}" ]]; then
        local credentials_relative_path
        credentials_relative_path="$(compose_repo_storage_path "$credentials_folder_name")"
        if [[ -z "$credentials_relative_path" ]]; then
            credentials_relative_path="$credentials_folder_name"
        fi
        credentials_relative_path="${credentials_relative_path#/}"
        credentials_relative_path="${credentials_relative_path%/}"
        if [[ -n "$credentials_relative_path" ]]; then
            credentials_cleanup_root="${git_prefix}${credentials_relative_path}"
            credentials_cleanup_root="${credentials_cleanup_root%/}"
            credentials_cleanup_prefix="${credentials_cleanup_root}/"
        fi
    fi
    
    if $cleanup_root_exists; then
        while IFS= read -r -d '' existing_file; do
            if [[ -n "$credentials_cleanup_prefix" ]]; then
                # Quote the prefix to handle special characters like [ ] in paths
                if [[ "$existing_file" == "${credentials_cleanup_prefix}"* ]]; then
                    continue
                fi
            fi
            if [[ -z "${expected_files[$existing_file]+set}" ]]; then
                local workflow_name
                workflow_name=$(jq -r '.name // empty' "$existing_file" 2>/dev/null)
                if [[ -z "$workflow_name" || "$workflow_name" == "null" ]]; then
                    workflow_name=$(basename "$existing_file" ".json")
                fi

                local relative_git_path=""
                if [[ "$existing_file" == "$git_prefix"* ]]; then
                    relative_git_path="${existing_file#"$git_prefix"}"
                else
                    log WARN "Workflow deletion outside Git directory: $existing_file"
                    commit_fail=true
                    continue
                fi

                if ! rm -f "$existing_file"; then
                    log WARN "Failed to remove obsolete workflow file: $existing_file"
                    commit_fail=true
                    continue
                fi

                if commit_deleted_workflow "$relative_git_path" "$workflow_name" "$git_dir"; then
                    deleted_count=$((deleted_count + 1))
                else
                    commit_fail=true
                fi
            fi
        done < <(find "$cleanup_root" -type f -name "*.json" -not -path "*/.git/*" -print0)

        while IFS= read -r -d '' empty_dir; do
            if [[ -n "$credentials_cleanup_prefix" ]]; then
                case "$empty_dir" in
                    "$credentials_cleanup_root"|${credentials_cleanup_prefix}*)
                        continue
                        ;;
                esac
            fi
            [[ "$empty_dir" == "$cleanup_root" ]] && continue
            rmdir "$empty_dir" 2>/dev/null || true
        done < <(find "$cleanup_root" -type d -empty -not -path "*/.git/*" -print0)
    fi

    log INFO "Workflow organization summary:"
    log INFO "  • New workflows: $new_count"
    log INFO "  • Updated workflows: $updated_count"
    log INFO "  • Unchanged workflows: $unchanged_count"
    log INFO "  • Deleted workflows: $deleted_count"

    rm -f "$mapping_file"

    push_print_folder_structure_preview "$target_dir"

    if $commit_fail; then
        log WARN "Completed with some issues during workflow organization"
        return 1
    fi

    return 0
}
