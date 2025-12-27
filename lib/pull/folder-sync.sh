#!/usr/bin/env bash
# Synchronize directory-based folder structure to n8n

# Extract folder path from workflow file location
# Args: repo_root, workflow_file_path
# Returns: folder_path (relative to repo root, excluding filename)
get_workflow_folder_path() {
    local repo_root="$1"
    local workflow_file="$2"
    
    # Get directory containing the workflow
    local workflow_dir
    workflow_dir=$(dirname "$workflow_file")
    
    # Make relative to repo root
    local relative_path="${workflow_dir#"${repo_root}/"}"
    
    # Handle case where file is at repo root
    if [[ "$relative_path" == "$workflow_dir" ]] || [[ "$relative_path" == "." ]]; then
        printf ''
        return 0
    fi
    
    printf '%s' "$relative_path"
}

# Extract project name from folder path (first component)
# Args: folder_path
# Returns: project_name
get_project_from_path() {
    local folder_path="$1"
    
    # Extract first path component
    local project_name="${folder_path%%/*}"
    
    # If no slash, the entire path is the project
    if [[ "$project_name" == "$folder_path" ]]; then
        printf '%s' "$project_name"
        return 0
    fi
    
    printf '%s' "$project_name"
}

# Extract folder path within project (everything after project name)
# Args: folder_path
# Returns: folder_path_in_project or empty if at project root
get_folder_in_project() {
    local folder_path="$1"
    
    # Remove first component (project name)
    local folder_in_project="${folder_path#*/}"
    
    # If nothing after first slash, workflow is at project root
    if [[ "$folder_in_project" == "$folder_path" ]]; then
        printf ''
        return 0
    fi
    
    printf '%s' "$folder_in_project"
}

# Create a folder in n8n (recursively creates parents if needed)
# Args: project_id, folder_path, is_dry_run
# Returns: folder_id of created/existing folder
declare -g CREATE_FOLDER_LAST_ID=""
declare -g CREATE_FOLDER_LAST_CREATED_SEGMENTS=0
declare -g RESTORE_PROJECTS_CREATED=${RESTORE_PROJECTS_CREATED:-0}
declare -g RESTORE_FOLDERS_CREATED=${RESTORE_FOLDERS_CREATED:-0}
declare -g RESTORE_FOLDERS_MOVED=${RESTORE_FOLDERS_MOVED:-0}
declare -g RESTORE_WORKFLOWS_REASSIGNED=${RESTORE_WORKFLOWS_REASSIGNED:-0}
declare -g RESTORE_FOLDER_SYNC_RAN=${RESTORE_FOLDER_SYNC_RAN:-false}

create_folder_path() {
    local project_id="$1"
    local folder_path="$2"
    local is_dry_run="${3:-false}"

    CREATE_FOLDER_LAST_ID=""
    CREATE_FOLDER_LAST_CREATED_SEGMENTS=0
    
    # Check if already exists
    local existing_id
    existing_id=$(get_folder_id "$project_id" "$folder_path")
    
    # Debug: Show cache lookup details
    if [[ -n "$existing_id" ]]; then
        log DEBUG "Folder '$folder_path' already exists (ID: $existing_id), reusing"
        CREATE_FOLDER_LAST_ID="$existing_id"
        return 0
    fi
    
    log DEBUG "Folder '$folder_path' not found in cache, will create"
    
    # Split path into components
    IFS='/' read -ra path_parts <<< "$folder_path"
    
    local current_path=""
    local parent_id=""
    local folder_id=""
    
    # Create each level of the hierarchy
    for folder_name in "${path_parts[@]}"; do
        [[ -z "$folder_name" ]] && continue
        
        # Build cumulative path
        if [[ -z "$current_path" ]]; then
            current_path="$folder_name"
        else
            current_path="$current_path/$folder_name"
        fi
        
        # Check if this level exists
        folder_id=$(get_folder_id "$project_id" "$current_path")
        
        log DEBUG "Checking level '$folder_name' (full path: '$current_path'): ${folder_id:-NOT FOUND}"
        
        if [[ -z "$folder_id" ]]; then
            # Need to create this folder
            if [[ "$is_dry_run" == "true" ]]; then
                log DRYRUN "Would create folder: $current_path (project: $project_id, parent: ${parent_id:-root})"
                folder_id="dry-run-folder-$$-$RANDOM"
            else
                # Call n8n API to create folder
                local created_folder_json
                if created_folder_json=$(n8n_api_create_folder "$folder_name" "$project_id" "$parent_id"); then
                    folder_id=$(printf '%s' "$created_folder_json" | jq -r '.data.id // .id // empty' 2>/dev/null)
                    
                    if [[ -z "$folder_id" ]]; then
                        log ERROR "Failed to create folder '$folder_name': no ID returned"
                        return 1
                    fi
                    
                    log SUCCESS "Created folder: $current_path (ID: $folder_id)" >&2
                    RESTORE_FOLDERS_CREATED=$((RESTORE_FOLDERS_CREATED + 1))
                else
                    log ERROR "Failed to create folder: $current_path"
                    return 1
                fi
            fi
            
            # Update our state map
            set_folder_cache_entry "$project_id" "$current_path" "$folder_id"
            if [[ "$is_dry_run" != "true" ]]; then
                CREATE_FOLDER_LAST_CREATED_SEGMENTS=$((CREATE_FOLDER_LAST_CREATED_SEGMENTS + 1))
            fi
            log DEBUG "Cache now tracks ${#N8N_FOLDERS[@]} folder path(s)"
            if [[ -n "$parent_id" ]]; then
                # shellcheck disable=SC2034 # Maintain parent relationships for state module consumers
                N8N_FOLDER_PARENTS["$folder_id"]="$parent_id"
            fi
        else
            log DEBUG "Level '$current_path' already exists (ID: $folder_id), reusing"
        fi
        
        # This folder becomes parent for next level
        parent_id="$folder_id"
    done
    
    CREATE_FOLDER_LAST_ID="$folder_id"
    return 0
}

# Assign workflow to folder in n8n
# Args: workflow_id, project_id, folder_id, is_dry_run, [workflow_name], [folder_path]
# Returns: 0 on success, 1 on failure
assign_workflow_to_folder() {
    local workflow_id="$1"
    local project_id="$2"
    local folder_id="$3"
    local is_dry_run="$4"
    local workflow_name="${5:-}"
    local folder_path="${6:-}"
    
    # Check current assignment
    local current_assignment
    current_assignment=$(get_workflow_assignment "$workflow_id")
    
    local current_folder_id=""
    local current_project_id=""
    local current_version_id=""
    
    if [[ -n "$current_assignment" ]]; then
        IFS='|' read -r current_folder_id current_project_id current_version_id <<< "$current_assignment"
    fi
    
    # Skip if already assigned correctly
    if [[ "$current_folder_id" == "$folder_id" && "$current_project_id" == "$project_id" ]]; then
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Workflow $workflow_id already assigned correctly"
        fi
        if [[ -z "$current_version_id" && "$is_dry_run" != "true" ]]; then
            local workflow_details
            if workflow_details=$(n8n_api_get_workflow "$workflow_id" 2>/dev/null); then
                local fetched_version
                fetched_version=$(printf '%s' "$workflow_details" | jq -r '.data.versionId // .data.version.id // .versionId // .version.id // empty' 2>/dev/null)
                set_workflow_assignment_state "$workflow_id" "$current_folder_id" "$current_project_id" "$fetched_version"
            fi
        fi
        return 0
    fi
    
    if [[ "$is_dry_run" == "true" ]]; then
        local display_name="${workflow_name:-workflow $workflow_id}"
        local display_path="${folder_path:-folder $folder_id}"
        log DRYRUN "Would assign '$display_name' to $display_path (project: $project_id)"
        return 0
    fi
    
    # Call n8n API to update assignment
    if [[ -z "$current_version_id" ]]; then
        local workflow_details
        if workflow_details=$(n8n_api_get_workflow "$workflow_id" 2>/dev/null); then
            current_version_id=$(printf '%s' "$workflow_details" | jq -r '.data.versionId // .data.version.id // .versionId // .version.id // empty' 2>/dev/null)
            set_workflow_assignment_state "$workflow_id" "$current_folder_id" "${current_project_id:-$project_id}" "$current_version_id"
        fi
    fi

    if n8n_api_update_workflow_assignment "$workflow_id" "$project_id" "$folder_id" "$current_version_id"; then
        # Build friendly log message
        local msg="Assigned"
        if [[ -n "$workflow_name" ]]; then
            msg="$msg workflow '$workflow_name' (ID: $workflow_id)"
        else
            msg="$msg workflow $workflow_id"
        fi
        
        if [[ -n "$folder_path" ]]; then
            msg="$msg to folder '$folder_path' (ID: $folder_id)"
        else
            msg="$msg to folder $folder_id"
        fi
        
        log SUCCESS "$msg"
        
        # Update our state
        local updated_version_id="$current_version_id"
        if [[ -n "${N8N_API_LAST_BODY:-}" ]]; then
            local parsed_version
            parsed_version=$(printf '%s' "${N8N_API_LAST_BODY}" | jq -r '.data.versionId // .data.version.id // .versionId // .version.id // empty' 2>/dev/null)
            if [[ -n "$parsed_version" && "$parsed_version" != "null" ]]; then
                updated_version_id=$(_sanitize_cache_text "$parsed_version")
            fi
        fi

        set_workflow_assignment_state "$workflow_id" "$folder_id" "$project_id" "$updated_version_id"
        if [[ "$is_dry_run" != "true" ]]; then
            RESTORE_WORKFLOWS_REASSIGNED=$((RESTORE_WORKFLOWS_REASSIGNED + 1))
        fi
        return 0
    else
        local display_name="${workflow_name:-workflow $workflow_id}"
        local display_path="${folder_path:-folder $folder_id}"
        if [[ -n "${N8N_API_LAST_STATUS:-}" && "${N8N_API_LAST_STATUS}" == "400" ]]; then
            log WARN "n8n API rejected assignment for '$display_name' due to version conflict; refreshing version metadata may resolve this."
        fi
        log ERROR "Failed to assign '$display_name' to $display_path"
        return 1
    fi
}

# Process directory structure and sync folders to n8n
# Args: source_dir, manifest_path, is_dry_run, audit_log_path
# Returns: 0 on success, 1 on failure
sync_directory_structure() {
    local source_dir="$1"
    local manifest_path="$2"
    local is_dry_run="$3"
    local audit_log_path="${4:-}"
    
    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Invalid source directory: ${source_dir:-<empty>}"
        return 1
    fi
    
    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        log ERROR "Manifest file required but not found: ${manifest_path:-<empty>}"
        return 1
    fi
    
    log INFO "Syncing folder structure from $source_dir"
    RESTORE_FOLDER_SYNC_RAN="true"
    
    local processed=0
    local assigned=0
    local skipped=0
    local failed=0

    declare -A root_preservation_processed=()
    
    # Process each workflow from manifest (NDJSON format)
    while IFS= read -r manifest_line; do
        [[ -z "$manifest_line" ]] && continue
        
        # Parse manifest entry
        local workflow_id workflow_name workflow_path
        
        # Try actualImportedId first (post-reconciliation), fallback to id (pre-reconciliation)
        workflow_id=$(printf '%s' "$manifest_line" | jq -r '.actualImportedId // .id // ""' 2>/dev/null)
        workflow_name=$(printf '%s' "$manifest_line" | jq -r '.name // "Workflow"' 2>/dev/null)
        workflow_path=$(printf '%s' "$manifest_line" | jq -r '.storagePath // .path // ""' 2>/dev/null)
        
        if [[ -z "$workflow_id" ]]; then
            log WARN "Skipping manifest entry without workflow ID (name: $workflow_name)"
            skipped=$((skipped + 1))
            continue
        fi
        
        if [[ -z "$workflow_path" ]]; then
            log WARN "Skipping workflow '$workflow_name' (no storage path in manifest)"
            skipped=$((skipped + 1))
            continue
        fi
        
        processed=$((processed + 1))
        
        # Ensure conflicting existing workflow stays at root if specified
        local out_of_scope_existing_id
        out_of_scope_existing_id=$(printf '%s' "$manifest_line" | jq -r '.outOfScopeExistingId // ""' 2>/dev/null)
        if [[ -n "$out_of_scope_existing_id" && -z "${root_preservation_processed[$out_of_scope_existing_id]:-}" ]]; then
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Preserving existing workflow $out_of_scope_existing_id outside scoped folder adjustments"
            fi
            root_preservation_processed[$out_of_scope_existing_id]=1
        fi

        # Extract folder path from storage path
        local folder_path
        folder_path=$(get_workflow_folder_path "$source_dir" "$source_dir/$workflow_path")
        
        # Use configured target project (not derived from folder structure)
        local project_id="${N8N_DEFAULT_PROJECT_ID}"
        
        # If target_folder is specified, prepend it to the folder path
        if [[ -n "$target_folder" ]]; then
            if [[ -n "$folder_path" ]]; then
                folder_path="$target_folder/$folder_path"
            else
                folder_path="$target_folder"
            fi
        fi
        
        # Check if we need folder assignment
        if [[ -z "$folder_path" ]]; then
            # Workflow at repo root with no target folder - assign to project root
            if [[ -n "$audit_log_path" ]]; then
                log_folder_assignment "$audit_log_path" "$workflow_id" "$workflow_name" \
                    "$project_id" "" "root" "success" "at repository root"
            fi
            
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Workflow '$workflow_name' at root (no folder assignment needed)"
            fi
            assigned=$((assigned + 1))
            continue
        fi
        
        # Create folder structure in the configured project
        local folder_id=""
        if ! create_folder_path "$project_id" "$folder_path" "$is_dry_run"; then
            log ERROR "Failed to create folder path: $folder_path"
            failed=$((failed + 1))
            
            if [[ -n "$audit_log_path" ]]; then
                log_folder_assignment "$audit_log_path" "$workflow_id" "$workflow_name" \
                    "$project_id" "" "$folder_path" "failed" "folder creation failed"
            fi
            continue
        fi

        folder_id="$CREATE_FOLDER_LAST_ID"

        if [[ -z "$folder_id" ]]; then
            log ERROR "Folder creation succeeded but no folder ID captured for path: $folder_path"
            failed=$((failed + 1))

            if [[ -n "$audit_log_path" ]]; then
                log_folder_assignment "$audit_log_path" "$workflow_id" "$workflow_name" \
                    "$project_id" "" "$folder_path" "failed" "missing folder id"
            fi
            continue
        fi
        
        # Assign workflow to folder
        if assign_workflow_to_folder "$workflow_id" "$project_id" "$folder_id" "$is_dry_run" "$workflow_name" "$folder_path"; then
            assigned=$((assigned + 1))
            
            if [[ -n "$audit_log_path" ]]; then
                log_folder_assignment "$audit_log_path" "$workflow_id" "$workflow_name" \
                    "$project_id" "$folder_id" "$folder_path" "success" ""
            fi
        else
            failed=$((failed + 1))
            
            if [[ -n "$audit_log_path" ]]; then
                log_folder_assignment "$audit_log_path" "$workflow_id" "$workflow_name" \
                    "$project_id" "$folder_id" "$folder_path" "failed" "assignment API call failed"
            fi
        fi
        
    done < "$manifest_path"
    
    # Summary
    log INFO "Folder sync complete: processed=$processed, assigned=$assigned, skipped=$skipped, failed=$failed"
    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "Folder metrics — created: $RESTORE_FOLDERS_CREATED, moved: $RESTORE_FOLDERS_MOVED, workflows reassigned: $RESTORE_WORKFLOWS_REASSIGNED"
    fi

    export RESTORE_FOLDERS_CREATED
    export RESTORE_FOLDERS_MOVED
    export RESTORE_WORKFLOWS_REASSIGNED
    export RESTORE_FOLDER_SYNC_RAN
    export RESTORE_PROJECTS_CREATED
    
    if [[ "$failed" -gt 0 ]]; then
        log WARN "Some folder assignments failed (see logs above)"
        return 1
    fi
    
    return 0
}

# Apply folder structure from directory to n8n
# Args: source_dir, container_id, is_dry_run, unused, manifest_path, target_folder
# Returns: 0 on success, 1 on failure
apply_folder_structure_from_directory() {
    local source_dir="$1"
    local container_id="$2"
    local is_dry_run="$3"
    local container_credentials_path="${4:-}"
    local manifest_path="$5"
    local target_folder="${6:-}"  # n8n_path - target folder in n8n
    local force_refresh="${7:-false}"

    if [[ "$force_refresh" == "true" ]]; then
        invalidate_n8n_state_cache
    fi
    
    if [[ -n "$target_folder" ]]; then
        log INFO "Applying folder structure to n8n (target folder: '$target_folder')..."
    else
        log INFO "Applying folder structure to n8n..."
    fi

    if [[ "$is_dry_run" != "true" ]]; then
        if ! prepare_n8n_api_auth "$container_id" "$container_credentials_path"; then
            log ERROR "Unable to initialize n8n API session for folder structure sync"
            return 1
        fi
    fi
    
    # Step 1: Load current n8n state
    if [[ "$is_dry_run" == "true" ]]; then
        log DRYRUN "Would fetch current n8n state (projects, folders, workflows)"
        local projects_json='[{"id":"dry-run-project","name":"Dry Run","type":"personal"}]'
        local folders_json='[]'
        local workflows_json='[]'

        if ! load_n8n_state "$projects_json" "$folders_json" "$workflows_json" "$force_refresh"; then
            log ERROR "Failed to load n8n state"
            return 1
        fi

        # Do not treat synthetic dry-run data as initialized state for future real operations
        RESTORE_N8N_STATE_INITIALIZED="false"
    elif [[ "${RESTORE_N8N_STATE_INITIALIZED:-false}" == "true" ]]; then
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Reusing cached n8n state (projects: ${#N8N_PROJECTS[@]}, folders: ${#N8N_FOLDERS[@]}, workflows: ${#N8N_WORKFLOWS[@]})"
        else
            log DEBUG "Reusing cached n8n state"
        fi
    else
        log DEBUG "Fetching current n8n state..."

        local projects_json
        local folders_json
        local workflows_json

        if ! projects_json=$(n8n_api_get_projects 2>/dev/null); then
            local status="${N8N_API_LAST_STATUS:-unknown}"
            local category="${N8N_API_LAST_ERROR_CATEGORY:-none}"
            local preview=""
            if [[ -n "${N8N_API_LAST_BODY:-}" ]]; then
                preview=$(printf '%s' "${N8N_API_LAST_BODY}" | tr '\n' ' ' | head -c 140)
                if [[ ${#N8N_API_LAST_BODY} -gt 140 ]]; then
                    preview+="…"
                fi
            fi
            if [[ -n "$preview" ]]; then
                log ERROR "Failed to fetch projects from n8n (HTTP ${status}, category=${category}, body='${preview}')"
            else
                log ERROR "Failed to fetch projects from n8n (HTTP ${status}, category=${category})"
            fi
            return 1
        fi

        if ! folders_json=$(n8n_api_get_folders 2>/dev/null); then
            log WARN "Failed to fetch folders from n8n (starting with empty folder state)"
            folders_json='[]'
        fi

        if ! workflows_json=$(n8n_api_get_workflows 2>/dev/null); then
            log WARN "Failed to fetch workflows from n8n (starting with empty workflow state)"
            workflows_json='[]'
        fi

        if ! load_n8n_state "$projects_json" "$folders_json" "$workflows_json"; then
            log ERROR "Failed to load n8n state"
            return 1
        fi
    fi
    
    # Step 2: Generate/validate manifest
    local working_manifest="$manifest_path"
    
    if [[ -z "$working_manifest" || ! -f "$working_manifest" ]]; then
        log DEBUG "Generating manifest from directory structure..."
        working_manifest=$(mktemp /tmp/n8n-folder-manifest-XXXXXX)
        
        if ! generate_workflow_manifest "$source_dir" "$working_manifest"; then
            log ERROR "Failed to generate workflow manifest"
            cleanup_temp_path "$working_manifest"
            return 1
        fi
    fi
    
    # Step 3: Sync directory structure to n8n
    local audit_log
    audit_log=$(mktemp /tmp/n8n-folder-audit-XXXXXX)
    
    if ! sync_directory_structure "$source_dir" "$working_manifest" "$is_dry_run" "$audit_log"; then
        log WARN "Folder structure sync completed with errors"
        summarize_folder_assignments "$audit_log"
        cleanup_temp_path "$audit_log"
        [[ "$working_manifest" != "$manifest_path" ]] && cleanup_temp_path "$working_manifest"
        return 1
    fi
    
    # Step 4: Show summary
    summarize_folder_assignments "$audit_log"
    
    # Cleanup
    cleanup_temp_path "$audit_log"
    [[ "$working_manifest" != "$manifest_path" ]] && cleanup_temp_path "$working_manifest"
    
    log SUCCESS "Folder structure applied successfully"
    return 0
}

