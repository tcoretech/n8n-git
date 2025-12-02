#!/usr/bin/env bash
# =========================================================
# lib/push/export.sh - Push export operations for n8n-git
# =========================================================
# All push-related functions: push export orchestration

PUSH_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Shared dependencies
source "$PUSH_LIB_DIR/../utils/common.sh"
source "$PUSH_LIB_DIR/../n8n/snapshot.sh"
source "$PUSH_LIB_DIR/../github/git.sh"
source "$PUSH_LIB_DIR/../github/git_ops.sh"

# Push-specific modules
source "$PUSH_LIB_DIR/container_io.sh"
source "$PUSH_LIB_DIR/folder_mapping.sh"

push_export_sync_workflows_to_git() {
    local container_id="$1"
    local target_dir="$2"
    local is_dry_run="$3"
    local folder_structure_enabled="$4"
    local container_credentials_decrypted="$5"
    local clone_sparse_target="$6"
    local folder_mapping_json_cached="$7"
    local container_workflows="$8"
    local container_workflows_dir="$9"
    local copy_status_ref="${10}"
    local remote_workflows_ref="${11}"
    local folder_structure_committed_ref="${12}"
    local folder_structure_flat_ref="${13}"

    declare -n ref_copy_status="$copy_status_ref"
    declare -n ref_remote_workflows_saved="$remote_workflows_ref"
    declare -n ref_folder_structure_committed="$folder_structure_committed_ref"
    declare -n ref_folder_structure_flat_ready="$folder_structure_flat_ref"

    if [[ "$folder_structure_enabled" == true ]]; then
        if $is_dry_run; then
            log DRYRUN "Would create n8n folder structure in Git repository"
        else
            log DEBUG "Creating n8n folder structure using API..."
            log DEBUG "n8n URL: $n8n_base_url"
            export container_id="$container_id"
            local folder_structure_status=0
            if push_create_folder_structure "$container_id" "$target_dir" "$target_dir" "$is_dry_run" "$container_credentials_decrypted" "$clone_sparse_target" "$folder_mapping_json_cached"; then
                ref_folder_structure_committed=true
                log SUCCESS "n8n folder structure created in repository"
                ref_remote_workflows_saved=true
            else
                folder_structure_status=$?
                if [[ $folder_structure_status -eq 2 ]]; then
                    log INFO "Folder structure API unavailable; workflows copied in flat layout"
                    ref_remote_workflows_saved=true
                    ref_folder_structure_flat_ready=true
                else
                    log ERROR "Failed to create folder structure, attempting flat structure fallback"
                fi
            fi
        fi
    fi

    if ! $ref_folder_structure_committed && ! $ref_folder_structure_flat_ready; then
        if $is_dry_run; then
            log DRYRUN "Would copy workflows to Git repository: $target_dir/workflows.json"
            return 0
        fi

        if docker exec "$container_id" sh -c "[ -f '$container_workflows' ]"; then
            local cp_workflows_git_output=""
            local docker_cp_git_workflows
            docker_cp_git_workflows=$(convert_path_for_docker_cp "$target_dir/workflows.json")
            [[ -z "$docker_cp_git_workflows" ]] && docker_cp_git_workflows="$target_dir/workflows.json"
            if ! cp_workflows_git_output=$(docker cp "${container_id}:${container_workflows}" "$docker_cp_git_workflows" 2>&1); then
                log ERROR "Failed to copy workflows to Git repository"
                if [[ -n "$cp_workflows_git_output" ]]; then
                    log DEBUG "docker cp error: $cp_workflows_git_output"
                fi
                ref_copy_status="failed"
            else
                if [[ -n "$cp_workflows_git_output" && "$verbose" == "true" ]]; then
                    log DEBUG "docker cp output: $cp_workflows_git_output"
                fi
                if ! push_prettify_json_file "$target_dir/workflows.json" "$is_dry_run"; then
                    log WARN "Failed to prettify workflows JSON in Git repository"
                fi
                log SUCCESS "Workflows copied to Git repository"
                ref_remote_workflows_saved=true
            fi
        elif docker exec "$container_id" sh -c "[ -d '$container_workflows_dir' ]"; then
            local cp_workflows_dir_output=""
            local docker_cp_git_workflows_dir
            docker_cp_git_workflows_dir=$(convert_path_for_docker_cp "$target_dir/")
            [[ -z "$docker_cp_git_workflows_dir" ]] && docker_cp_git_workflows_dir="$target_dir/"
            if ! cp_workflows_dir_output=$(docker cp "${container_id}:${container_workflows_dir}/." "$docker_cp_git_workflows_dir" 2>&1); then
                log ERROR "Failed to copy workflow directory to Git repository"
                if [[ -n "$cp_workflows_dir_output" ]]; then
                    log DEBUG "docker cp error: $cp_workflows_dir_output"
                fi
                ref_copy_status="failed"
            else
                if [[ -n "$cp_workflows_dir_output" && "$verbose" == "true" ]]; then
                    log DEBUG "docker cp output: $cp_workflows_dir_output"
                fi
                push_prettify_json_tree "$target_dir" "$is_dry_run" || log WARN "Completed workflow JSON prettify with warnings in Git repository"
                log SUCCESS "Workflows copied to Git repository from directory export"
                ref_remote_workflows_saved=true
            fi
        else
            log ERROR "No workflow export found in container for flat structure push"
            ref_copy_status="failed"
        fi
    fi
}

push_export_sync_credentials_to_git() {
    local container_id="$1"
    local target_dir="$2"
    local is_dry_run="$3"
    local credentials_mode="$4"
    local credentials_encrypted_flag="$5"
    local container_credentials_backup_path="$6"
    local host_credentials_bundle="$7"
    local credentials_git_relative_dir="$8"
    local credentials_bundle_available_ref="$9"
    local remote_credentials_saved_ref="${10}"
    local copy_status_ref="${11}"

    declare -n ref_credentials_bundle_available="$credentials_bundle_available_ref"
    declare -n ref_remote_credentials_saved="$remote_credentials_saved_ref"
    declare -n ref_copy_status="$copy_status_ref"

    if [[ "$credentials_mode" != "2" ]]; then
        return 0
    fi

    if ! docker exec "$container_id" sh -c "[ -f '$container_credentials_backup_path' ]"; then
        return 0
    fi

    if [[ "$credentials_encrypted_flag" == "false" ]]; then
        log WARN "⚠️  Storing decrypted credentials in Git repository (high risk)."
    else
        log INFO "🔐 Storing encrypted credentials in Git repository."
    fi

    local credentials_git_dir="$target_dir/$credentials_git_relative_dir"
    if $is_dry_run; then
        log DRYRUN "Would render credentials into Git directory: $credentials_git_dir"
        return 0
    fi

    if [[ "$ref_credentials_bundle_available" == false ]]; then
        local cp_credentials_git_output=""
        local docker_cp_git_credentials_bundle
        docker_cp_git_credentials_bundle=$(convert_path_for_docker_cp "$host_credentials_bundle")
        [[ -z "$docker_cp_git_credentials_bundle" ]] && docker_cp_git_credentials_bundle="$host_credentials_bundle"
        if ! cp_credentials_git_output=$(docker cp "${container_id}:${container_credentials_backup_path}" "$docker_cp_git_credentials_bundle" 2>&1); then
            log ERROR "Failed to copy credentials bundle from container"
            if [[ -n "$cp_credentials_git_output" ]]; then
                log DEBUG "docker cp error: $cp_credentials_git_output"
            fi
            ref_copy_status="failed"
            return 1
        fi
        ref_credentials_bundle_available=true
        if [[ -n "$cp_credentials_git_output" && "$verbose" == "true" ]]; then
            log DEBUG "docker cp output: $cp_credentials_git_output"
        fi
    fi

    if [[ "$ref_copy_status" == "failed" ]]; then
        return 1
    fi

    if push_render_credentials_directory "$host_credentials_bundle" "$credentials_git_dir" "$is_dry_run" "Git repository"; then
        ref_remote_credentials_saved=true
    else
        log ERROR "Failed to render credentials into Git repository"
        ref_copy_status="failed"
        rm -f "$host_credentials_bundle"
        return 1
    fi

    # Cleanup the bundle file as it's no longer needed and shouldn't be committed
    rm -f "$host_credentials_bundle"
}

push_export_sync_environment_to_git() {
    local container_id="$1"
    local target_dir="$2"
    local is_dry_run="$3"
    local environment_mode="$4"
    local environment_exported_flag="$5"
    local container_env="$6"
    local copy_status_ref="$7"
    local remote_environment_saved_ref="$8"
    local environment_git_relative_path_ref="$9"

    declare -n ref_copy_status="$copy_status_ref"
    declare -n ref_remote_environment_saved="$remote_environment_saved_ref"
    declare -n ref_environment_git_relative_path="$environment_git_relative_path_ref"

    if [[ "$environment_mode" != "2" ]]; then
        return 0
    fi

    if [[ "$environment_exported_flag" != true ]]; then
        log WARN "Environment push configured for Git, but no variables were captured. Skipping."
        return 0
    fi

    local env_git_path="$target_dir/.env"
    if $is_dry_run; then
        log DRYRUN "Would copy environment variables to Git repository: $env_git_path"
        return 0
    fi

    local cp_env_git_output=""
    if ! mkdir -p "$target_dir" 2>/dev/null; then
        log ERROR "Failed to prepare Git directory for environment variables"
        ref_copy_status="failed"
        return 1
    fi

    local docker_cp_git_env_path
    docker_cp_git_env_path=$(convert_path_for_docker_cp "$env_git_path")
    [[ -z "$docker_cp_git_env_path" ]] && docker_cp_git_env_path="$env_git_path"

    if ! cp_env_git_output=$(docker cp "${container_id}:${container_env}" "$docker_cp_git_env_path" 2>&1); then
        log ERROR "Failed to copy environment variables to Git repository"
        if [[ -n "$cp_env_git_output" ]]; then
            log DEBUG "docker cp error: $cp_env_git_output"
        fi
        ref_copy_status="failed"
        return 1
    fi

    if [[ -n "$cp_env_git_output" && "$verbose" == "true" ]]; then
        log DEBUG "docker cp output: $cp_env_git_output"
    fi
    log WARN "Environment variables stored in Git repository. Review access controls carefully."
    ref_remote_environment_saved=true
    ref_environment_git_relative_path=".env"
}

# Orchestrate folder structure creation with proper separation of concerns
push_create_folder_structure() {
    local container_id="$1"
    local target_dir="$2"
    local git_dir="$3"
    local is_dry_run="$4"
    local container_credentials_path="${5:-/tmp/credentials.json}"
    local initial_sparse_prefix="${6:-}"
    local precomputed_mapping_json="${7:-}"
    
    if [[ -z "$container_id" || -z "$target_dir" || -z "$git_dir" ]]; then
        log "ERROR" "Missing required parameters for folder structure creation"
        return 1
    fi
    
    if $is_dry_run; then
        log "DRYRUN" "Would create n8n folder structure with individual Git commits"
        return 0
    fi
    
    log INFO "Creating n8n folder structure for workflows..."
    
    # Step 1: Export individual workflow files from Docker container
    local temp_export_dir=""
    if ! push_collect_workflow_exports "$container_id" temp_export_dir; then
        return 1
    fi
    
    # Step 2: Get folder organization mapping from n8n API
    local folder_mapping_json=""
    if [[ -n "$precomputed_mapping_json" ]]; then
        folder_mapping_json="$precomputed_mapping_json"
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "Using precomputed folder mapping (length: ${#folder_mapping_json})"
        fi
    else
        log DEBUG "Fetching folder structure mapping from n8n API..."
        if ! get_workflow_folder_mapping "$container_id" "$container_credentials_path" folder_mapping_json; then
            log ERROR "Failed to get folder structure mapping from n8n API"
            log WARN "Falling back to flat file structure"
            # Fallback: copy all files to target directory using sanitized workflow names
            if ! push_copy_workflows_flat_with_names "$temp_export_dir/workflow_exports" "$target_dir"; then
                log ERROR "Failed to copy workflows to Git repository"
                cleanup_temp_path "$temp_export_dir"
                return 1
            fi
            cleanup_temp_path "$temp_export_dir"
            # Signal to caller that flat structure fallback was used
            return 2
        fi
        log SUCCESS "Retrieved folder structure mapping from n8n API"
        push_apply_mapping_metadata "$folder_mapping_json" || true
    fi

    push_apply_mapping_metadata "$folder_mapping_json" || true

    # Step 3: Organize files according to folder structure and commit to Git
    log DEBUG "Organizing workflows into folder structure..."
    if ! push_organize_workflows_by_folders "$temp_export_dir/workflow_exports" "$target_dir" "$folder_mapping_json" "$git_dir"; then
        log ERROR "Failed to organize workflows by folders"
        cleanup_temp_path "$temp_export_dir"
        return 1
    fi

    cleanup_temp_path "$temp_export_dir"
    return 0
}

push_render_credentials_directory() {
    render_credentials_bundle_to_directory "$@"
}

push_export() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local is_dry_run=$5            # Boolean: true/false instead of string  
    local workflows=$6             # Numeric: 0=disabled, 1=local, 2=remote
    local credentials=$7           # Numeric: 0=disabled, 1=local, 2=remote
    local folder_structure_enabled=${8:-false} # Boolean: true if folder structure enabled
    local local_backup_path="${9:-$HOME/n8n-backup}"  # Local push path (default: ~/n8n-backup)
    export credentials_folder_name="${10:-.credentials}"

    credentials_folder_name="${credentials_folder_name%/}"
    if [[ -z "$credentials_folder_name" ]]; then
        credentials_folder_name=".credentials"
    fi
    local credentials_git_relative_dir
    credentials_git_relative_dir="$(compose_repo_storage_path "$credentials_folder_name")"
    if [[ -z "$credentials_git_relative_dir" ]]; then
        credentials_git_relative_dir="$credentials_folder_name"
    fi
    local credentials_git_relative_path="$credentials_git_relative_dir"
    
    # Make container_id globally available for API functions
    export container_id="$container_id"
    
    # Derive storage descriptions for logging
    local workflows_desc="disabled"
    local credentials_desc="disabled"
    local environment_desc="disabled"
    case "$workflows" in
        0) workflows_desc="disabled" ;;
        1) workflows_desc="local" ;;
        2) workflows_desc="remote" ;;
    esac
    case "$credentials" in
        0) credentials_desc="disabled" ;;
        1) credentials_desc="local" ;;
        2) credentials_desc="remote" ;;
    esac
    case "$environment" in
        0) environment_desc="disabled" ;;
        1) environment_desc="local" ;;
        2) environment_desc="remote" ;;
    esac

    local needs_local_path=false
    if [[ "$workflows" == "1" || "$credentials" == "1" || "$environment" == "1" ]]; then
        needs_local_path=true
    fi

    log HEADER "Pushing Workflows: $workflows_desc, Credentials: $credentials_desc, Environment: $environment_desc"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Validate that at least one push type is enabled
    if [[ $workflows == 0 && $credentials == 0 && $environment == 0 ]]; then
        log ERROR "Both workflows and credentials are disabled. Nothing to push!"
        return 1
    fi
    
    # Show security warnings
    if [[ $credentials == 2 ]]; then
        if [[ "${credentials_encrypted:-true}" == "false" ]]; then
            log SECURITY "Decrypted credentials will be pushed to Git repository"
        else
            log INFO "Credentials will be pushed to Git repository encrypted by n8n"
        fi
    fi
    if [[ $environment == 2 ]]; then
        log WARN "[SECURITY] Environment variables will be pushed to Git repository (consider secrets exposure)"
    fi
    if [[ $workflows == 1 && $credentials == 1 && $environment != 2 ]]; then
        log INFO "[SECURITY] Workflows and credentials remain in local storage only"
    fi

    # Setup local push storage directory with optional timestamping
    local base_backup_dir="$local_backup_path"
    local local_backup_dir="$base_backup_dir"
    
    local local_workflows_file="$local_backup_dir/workflows.json"
    local local_credentials_dir="$local_backup_dir/$credentials_folder_name"
    local local_env_file="$local_backup_dir/.env"

    local credentials_repo_relative_path="$credentials_git_relative_path"
    
    if [[ $needs_local_path == true ]]; then
        if ! $is_dry_run; then
            if ! mkdir -p "$local_backup_dir"; then
                log ERROR "Failed to create local push directory: $local_backup_dir"
                return 1
            fi
            chmod 700 "$local_backup_dir" || log WARN "Could not set permissions on local push directory"

            # Also ensure base directory has proper permissions
            if [[ "$local_backup_dir" != "$base_backup_dir" ]]; then
                chmod 700 "$base_backup_dir" || log WARN "Could not set permissions on base push directory"
            fi

            log SUCCESS "Local push directory ready: $local_backup_dir"
        else
            log DRYRUN "Would create local push directory: $local_backup_dir"
        fi
    else
        log DEBUG "No local storage components selected - skipping local directory preparation"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d -t n8n-push-XXXXXXXXXX)
    log DEBUG "Created temporary directory: $tmp_dir"

    local container_workflows="/tmp/workflows.json"
    local container_credentials_encrypted="/tmp/credentials.json"
    local container_credentials_decrypted="/tmp/credentials.decrypted.json"
    local container_env="/tmp/.env"
    local environment_exported=false

    local host_credentials_bundle="$tmp_dir/push-credentials.bundle.json"
    local credentials_bundle_available=false

    local container_credentials_backup_path="$container_credentials_encrypted"
    if [[ "${credentials_encrypted:-true}" == "false" ]]; then
        container_credentials_backup_path="$container_credentials_decrypted"
    fi

    local local_workflows_saved=false
    local local_credentials_saved=false
    local local_env_saved=false
    local remote_workflows_saved=false
    local remote_credentials_saved=false
    local remote_environment_saved=false
    local folder_structure_committed=false
    local folder_structure_flat_ready=false
    local environment_git_relative_path=""
    local folder_mapping_json_cached=""
    local folder_mapping_ready=false
    local clone_sparse_target=""
    local clone_sparse_tokens=false
    local need_decrypted_credentials=false
    local decrypted_export_done=false
    local credentials_available=true

    local git_required=false
    if [[ $workflows == 2 ]] || [[ $credentials == 2 ]] || [[ $environment == 2 ]] || [[ "$folder_structure_enabled" == true ]]; then
        git_required=true
    fi

    if [[ "$folder_structure_enabled" == true ]]; then
        log DEBUG "Precomputing folder structure mapping before Git clone..."
        if get_workflow_folder_mapping "$container_id" "$container_credentials_decrypted" folder_mapping_json_cached; then
            folder_mapping_ready=true
            push_apply_mapping_metadata "$folder_mapping_json_cached" || true
            decrypted_export_done=true
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Precomputed mapping for project: name='$(project_effective_name)'"
            fi
            local resolved_prefix_pre
            resolved_prefix_pre="$(effective_repo_prefix)"
            resolved_prefix_pre="${resolved_prefix_pre#/}"
            resolved_prefix_pre="${resolved_prefix_pre%/}"
            clone_sparse_target="$resolved_prefix_pre"
            if [[ "${clone_sparse_target}" == *%* ]]; then
                clone_sparse_tokens=true
            fi
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Sparse checkout target resolved to '${clone_sparse_target:-<root>}'"
            fi
        else
            log WARN "Unable to precompute folder mapping; folder-structure mirroring disabled for this run"
            folder_structure_enabled=false
            folder_mapping_json_cached=""
        fi
    fi

    credentials_git_relative_dir="$(compose_repo_storage_path "$credentials_folder_name")"
    if [[ -z "$credentials_git_relative_dir" ]]; then
        credentials_git_relative_dir="$credentials_folder_name"
    fi
    credentials_git_relative_path="$credentials_git_relative_dir"
    credentials_repo_relative_path="$credentials_git_relative_path"

    if [[ "$git_required" == true ]]; then
        log INFO "Preparing Git repository for push..."
        local clone_url="https://${github_token}@github.com/${github_repo}.git"
        local -a git_clone_args=("--depth" "1" "-b" "$branch")
        local sparse_requested=false
        local clone_success=false
        local manual_init_performed=false

        if [[ -n "$clone_sparse_target" && $clone_sparse_tokens == false ]]; then
            sparse_requested=true
            log DEBUG "Cloning repository with sparse checkout targeting '$clone_sparse_target'"
            git_clone_args+=("--filter=blob:none" "--no-checkout")
            if git clone -h 2>&1 | grep -q -- '--sparse'; then
                git_clone_args+=("--sparse")
            fi
        fi

        git_clone_args+=("$clone_url" "$tmp_dir")
        local clone_args_display
        clone_args_display=$(printf '%s ' "${git_clone_args[@]}")
        clone_args_display="${clone_args_display% }"
        log DEBUG "Running: git clone ${clone_args_display}"

        if git_run_capture_stderr git clone "${git_clone_args[@]}" >/dev/null; then
            clone_success=true
            if [[ -n "$GIT_LAST_STDERR" ]]; then
                log DEBUG "git clone stderr: $GIT_LAST_STDERR"
            fi
        else
            if [[ -n "$GIT_LAST_STDERR" ]]; then
                log WARN "git clone stderr: $GIT_LAST_STDERR"
            fi
            if $sparse_requested; then
                log WARN "Sparse-aware clone failed; retrying without sparse options"
                rm -rf "$tmp_dir"
                mkdir -p "$tmp_dir"
                if git_run_capture_stderr git clone --depth 1 -b "$branch" "$clone_url" "$tmp_dir" >/dev/null; then
                    clone_success=true
                    sparse_requested=false
                    if [[ -n "$GIT_LAST_STDERR" ]]; then
                        log DEBUG "Retry clone stderr: $GIT_LAST_STDERR"
                    fi
                else
                    if [[ -n "$GIT_LAST_STDERR" ]]; then
                        log WARN "Retry clone stderr: $GIT_LAST_STDERR"
                    fi
                fi
            fi
        fi

        if [[ "$clone_success" == false ]]; then
            log WARN "git clone failed; initializing repository manually"
            if ! git -C "$tmp_dir" init -q; then
                log ERROR "Git init failed."
                rm -rf "$tmp_dir"
                return 1
            fi
            if ! git -C "$tmp_dir" remote add origin "$clone_url"; then
                git -C "$tmp_dir" remote set-url origin "$clone_url" >/dev/null 2>&1 || true
            fi
            if git -C "$tmp_dir" fetch --depth 1 origin "$branch" 2>/dev/null; then
                git -C "$tmp_dir" checkout "$branch" >/dev/null 2>&1 || git -C "$tmp_dir" checkout -b "$branch"
            else
                log WARN "Branch '$branch' not found on remote; creating new branch locally"
                git -C "$tmp_dir" checkout -b "$branch" >/dev/null 2>&1 || true
            fi
            clone_success=true
            manual_init_performed=true
        fi

        if [[ "$clone_success" == true && "$sparse_requested" == true ]]; then
            log INFO "Restricting checkout to configured GitHub path: $clone_sparse_target"
            if git_configure_sparse_checkout "$tmp_dir" "$clone_sparse_target" "$branch"; then
                : # Sparse checkout configured successfully; helper already logged outcome
            else
                log WARN "Sparse checkout configuration failed; using full repository contents."
                git -C "$tmp_dir" sparse-checkout disable >/dev/null 2>&1 || true
                if ! git -C "$tmp_dir" checkout "$branch" >/dev/null 2>&1; then
                    log WARN "Fallback checkout failed; repository may remain partially configured."
                fi
            fi
        elif [[ "$clone_success" == true && "$sparse_requested" == false ]]; then
            git -C "$tmp_dir" checkout "$branch" >/dev/null 2>&1 || true
        fi

        if [[ "$clone_success" == false ]]; then
            log ERROR "Failed to prepare Git repository for push"
            rm -rf "$tmp_dir"
            return 1
        fi

        if [[ "$manual_init_performed" == true ]]; then
            git -C "$tmp_dir" config user.email "${git_commit_email:-n8n-push-script@localhost}" >/dev/null 2>&1 || true
            git -C "$tmp_dir" config user.name "${git_commit_name:-n8n Push Script}" >/dev/null 2>&1 || true
        else
            if ! git -C "$tmp_dir" config user.email >/dev/null 2>&1; then
                git -C "$tmp_dir" config user.email "${git_commit_email:-n8n-push-script@localhost}" || true
            fi
            if ! git -C "$tmp_dir" config user.name >/dev/null 2>&1; then
                git -C "$tmp_dir" config user.name "${git_commit_name:-n8n Push Script}" || true
            fi
        fi
    else
        log DEBUG "Skipping Git repository preparation (local-only push)."
    fi

    # --- Export Data ---
    log INFO "Exporting data from n8n container..."
    local export_failed=false
    local no_data_found=false

    # Export workflows based on storage mode
    local container_workflows_dir="/tmp/workflows"
    if [[ $workflows == 2 ]]; then
        log INFO "Exporting individual workflow files for Git folder structure..."
        if ! dockExec "$container_id" "mkdir -p $container_workflows_dir" false; then
            log ERROR "Failed to create workflows directory in container"
            export_failed=true
        elif ! dockExec "$container_id" "n8n export:workflow --all --separate --output=$container_workflows_dir/" false; then 
            # Check if the error is due to no workflows existing
            if docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                log INFO "No workflows found to push - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export individual workflow files"
                export_failed=true
            fi
        fi
    elif [[ $workflows == 1 ]]; then
        log INFO "Exporting workflows as single file for local storage..."
        if ! dockExec "$container_id" "n8n export:workflow --all --output=$container_workflows" false; then 
            # Check if the error is due to no workflows existing
            if docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                log INFO "No workflows found to push - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export workflows"
                export_failed=true
            fi
        fi
    else
        log INFO "Workflows push disabled - skipping workflow export"
    fi

    # Export credentials based on storage mode and folder structure requirements
    if [[ "$folder_structure_enabled" == true ]]; then
        need_decrypted_credentials=true
    fi
    if [[ "${credentials_encrypted:-true}" == "false" ]]; then
        need_decrypted_credentials=true
    fi

    if [[ $credentials != 0 || $need_decrypted_credentials == true ]]; then
        if [[ $need_decrypted_credentials == true && $decrypted_export_done == false ]]; then
            local decrypted_cmd="n8n export:credentials --all --decrypted --output=$container_credentials_decrypted"
            if [[ "$folder_structure_enabled" == true ]]; then
                log INFO "Temporarily exporting decrypted credentials to locate n8n session authentication for folder structure; the file will be deleted after the push completes"
            fi
            if [[ "${credentials_encrypted:-true}" == "false" ]]; then
                log INFO "Exporting credentials in decrypted form (per configuration)..."
            else
                log DEBUG "Exporting temporary decrypted credentials for folder structure authentication..."
            fi

            if ! dockExec "$container_id" "$decrypted_cmd" false; then
                local credentials_list_output
                credentials_list_output=$(docker exec "$container_id" n8n list credentials 2>&1 || true)
                if printf '%s' "$credentials_list_output" | grep -q "No credentials found"; then
                    log INFO "No credentials found to push - this is a clean installation"
                    no_data_found=true
                    credentials_available=false
                else
                    log ERROR "Failed to export decrypted credentials"
                    export_failed=true
                fi
            else
                decrypted_export_done=true
                log DEBUG "Decrypted credentials export stored at $container_credentials_decrypted"
                log DEBUG "Temporary decrypted credential export scheduled for removal once Git operations finish"
            fi
        fi

        if [[ $credentials != 0 && "${credentials_encrypted:-true}" != "false" && $credentials_available == true ]]; then
            log INFO "Exporting credentials for $credentials_desc storage..."
            log DEBUG "Exporting credentials in encrypted form (default)"
            local cred_export_cmd="n8n export:credentials --all --output=$container_credentials_encrypted"
            if ! dockExec "$container_id" "$cred_export_cmd" false; then
                local credentials_list_output
                credentials_list_output=$(docker exec "$container_id" n8n list credentials 2>&1 || true)
                if printf '%s' "$credentials_list_output" | grep -q "No credentials found"; then
                    log INFO "No credentials found to push - this is a clean installation"
                    no_data_found=true
                    credentials_available=false
                else
                    log ERROR "Failed to export credentials"
                    export_failed=true
                fi
            fi
        fi
    else
        log INFO "Credentials push disabled - skipping credentials export"
    fi

    if $export_failed; then
        log ERROR "Failed to export data from n8n"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Handle environment variables depending on configured storage mode
    if [[ $environment != 0 ]]; then
        local env_scope="local storage"
        if [[ $environment == 2 ]]; then
            env_scope="Git repository push"
        fi
        log INFO "Capturing environment variables for $env_scope..."
        if dockExec "$container_id" "printenv | grep ^N8N_ > $container_env" false; then
            environment_exported=true
        else
            log WARN "Could not capture N8N_ environment variables from container."
        fi
    else
        log DEBUG "Environment push disabled - skipping environment capture"
    fi

    # --- Process Local Storage ---
    local performed_local_storage=false
    if [[ $workflows == 1 || $credentials == 1 || $environment == 1 ]]; then
        performed_local_storage=true
        log HEADER "Storing Data Locally"
    fi
    
    # Handle workflows locally if requested
    if [[ $workflows == 1 ]] && docker exec "$container_id" sh -c "[ -f '$container_workflows' ]"; then
        log INFO "Saving workflows to local storage..."
        if $is_dry_run; then
            log DRYRUN "Would copy workflows from container to local storage: $local_workflows_file"
            log DRYRUN "Would set permissions 600 on workflows file"
        else
            # Copy new workflows from container to local storage
            local cp_local_workflows_output=""
            local docker_cp_local_workflows
            docker_cp_local_workflows=$(convert_path_for_docker_cp "$local_workflows_file")
            [[ -z "$docker_cp_local_workflows" ]] && docker_cp_local_workflows="$local_workflows_file"
            if ! cp_local_workflows_output=$(docker cp "${container_id}:${container_workflows}" "$docker_cp_local_workflows" 2>&1); then
                log ERROR "Failed to copy workflows to local storage"
                if [[ -n "$cp_local_workflows_output" ]]; then
                    log DEBUG "docker cp error: $cp_local_workflows_output"
                fi
                rm -rf "$tmp_dir"
                return 1
            fi

            if ! push_prettify_json_file "$local_workflows_file" "$is_dry_run"; then
                log WARN "Failed to prettify local workflows JSON"
            fi
            chmod 600 "$local_workflows_file" || log WARN "Could not set permissions on workflows file"
            log SUCCESS "Workflows stored securely in local storage: $local_workflows_file"
            local_workflows_saved=true
            if [[ -n "$cp_local_workflows_output" && "$verbose" == "true" ]]; then
                log DEBUG "docker cp output: $cp_local_workflows_output"
            fi
        fi
    elif [[ $workflows == 1 ]]; then
        log INFO "No workflows file found in container"
        if $no_data_found; then
            if ! $is_dry_run; then
                echo "[]" > "$local_workflows_file"
                chmod 600 "$local_workflows_file"
                log INFO "Created empty workflows file in local storage"
                local_workflows_saved=true
            else
                log DRYRUN "Would create empty workflows file in local storage"
            fi
        fi
    fi
    
    # Handle credentials locally  
    if [[ $credentials == 1 ]]; then
        if docker exec "$container_id" sh -c "[ -f '$container_credentials_backup_path' ]"; then
            log INFO "Saving credentials to local secure storage..."
            if $is_dry_run; then
                log DRYRUN "Would synchronise credentials into directory: $local_credentials_dir"
            else
                if [[ "$credentials_bundle_available" == false ]]; then
                    local cp_credentials_bundle_output=""
                    local docker_cp_local_credentials_bundle
                    docker_cp_local_credentials_bundle=$(convert_path_for_docker_cp "$host_credentials_bundle")
                    [[ -z "$docker_cp_local_credentials_bundle" ]] && docker_cp_local_credentials_bundle="$host_credentials_bundle"
                    if ! cp_credentials_bundle_output=$(docker cp "${container_id}:${container_credentials_backup_path}" "$docker_cp_local_credentials_bundle" 2>&1); then
                        log ERROR "Failed to copy credentials bundle from container"
                        if [[ -n "$cp_credentials_bundle_output" ]]; then
                            log DEBUG "docker cp error: $cp_credentials_bundle_output"
                        fi
                        rm -rf "$tmp_dir"
                        return 1
                    fi
                    credentials_bundle_available=true
                    if [[ -n "$cp_credentials_bundle_output" && "$verbose" == "true" ]]; then
                        log DEBUG "docker cp output: $cp_credentials_bundle_output"
                    fi
                fi

                if ! push_render_credentials_directory "$host_credentials_bundle" "$local_credentials_dir" "$is_dry_run" "local secure storage"; then
                    log ERROR "Failed to render credentials into local storage"
                    rm -rf "$tmp_dir"
                    return 1
                fi
                local_credentials_saved=true
            fi
        else
            log INFO "No credentials file found in container"
            if $no_data_found; then
                if $is_dry_run; then
                    log DRYRUN "Would ensure credentials directory exists: $local_credentials_dir"
                else
                    if mkdir -p "$local_credentials_dir"; then
                        chmod 700 "$local_credentials_dir" 2>/dev/null || true
                        find "$local_credentials_dir" -maxdepth 1 -type f -name '*.json' -delete 2>/dev/null || true
                        log INFO "Cleared local credentials directory (no credentials present)"
                        local_credentials_saved=true
                    else
                        log WARN "Unable to prepare local credentials directory"
                    fi
                fi
            fi
        fi
    fi
    
    # Store .env file in local storage (always local for security)
    if [[ $environment == 1 && $environment_exported == true ]]; then
        if docker exec "$container_id" sh -c "[ -f '$container_env' ]"; then
            log INFO "Backing up environment variables to local storage..."
            if $is_dry_run; then
                log DRYRUN "Would copy .env from container to local storage: $local_env_file"
                log DRYRUN "Would set permissions 600 on .env file"
            else
                local cp_env_local_output=""
                local docker_cp_local_env_file
                docker_cp_local_env_file=$(convert_path_for_docker_cp "$local_env_file")
                [[ -z "$docker_cp_local_env_file" ]] && docker_cp_local_env_file="$local_env_file"
                if ! cp_env_local_output=$(docker cp "${container_id}:${container_env}" "$docker_cp_local_env_file" 2>&1); then
                    log ERROR "Failed to copy .env file to local storage"
                    if [[ -n "$cp_env_local_output" ]]; then
                        log DEBUG "docker cp error: $cp_env_local_output"
                    fi
                    rm -rf "$tmp_dir"
                    return 1
                fi
                if [[ -n "$cp_env_local_output" && "$verbose" == "true" ]]; then
                    log DEBUG "docker cp output: $cp_env_local_output"
                fi
                chmod 600 "$local_env_file" || log WARN "Could not set permissions on .env file"
                log SUCCESS ".env file stored securely in local storage: $local_env_file"
                local_env_saved=true
            fi
        else
            log INFO "No .env file found in container"
        fi
    fi

    if [[ $performed_local_storage == true ]]; then
        log SUCCESS "Local push operations completed successfully"
    fi
    
    # --- Git Repository Push (Conditional) ---
    if [[ $workflows == 2 ]] || [[ $credentials == 2 ]]; then
        local target_dir="$tmp_dir"
        local copy_status="success"
        
        # Handle workflows for remote storage
        if [[ $workflows == 2 ]]; then
            if [[ "$folder_structure_enabled" == true ]]; then
                log HEADER "Committing Workflows to Git (Folder Structure)"
            fi
            log INFO "Preparing workflows for Git repository..."
            push_export_sync_workflows_to_git \
                "$container_id" \
                "$target_dir" \
                "$is_dry_run" \
                "$folder_structure_enabled" \
                "$container_credentials_decrypted" \
                "$clone_sparse_target" \
                "$folder_mapping_json_cached" \
                "$container_workflows" \
                "$container_workflows_dir" \
                copy_status \
                remote_workflows_saved \
                folder_structure_committed \
                folder_structure_flat_ready
        fi

        # Handle credentials for remote storage
        push_export_sync_credentials_to_git \
            "$container_id" \
            "$target_dir" \
            "$is_dry_run" \
            "$credentials" \
            "${credentials_encrypted:-true}" \
            "$container_credentials_backup_path" \
            "$host_credentials_bundle" \
            "$credentials_git_relative_dir" \
            credentials_bundle_available \
            remote_credentials_saved \
            copy_status

        # Handle environment variables for remote storage
        push_export_sync_environment_to_git \
            "$container_id" \
            "$target_dir" \
            "$is_dry_run" \
            "$environment" \
            "$environment_exported" \
            "$container_env" \
            copy_status \
            remote_environment_saved \
            environment_git_relative_path

        # Create .gitignore based on what's included
        local gitignore_file="$tmp_dir/.gitignore"
        if $is_dry_run; then
            log DRYRUN "Would create .gitignore file"
        else
            local template_dir
            template_dir="$(dirname "${BASH_SOURCE[0]}")/../utils/templates"
            local gitignore_base_template="$template_dir/gitignore.base"
            local gitignore_credentials_template="$template_dir/gitignore.credentials-secure"
            local gitignore_environment_template="$template_dir/gitignore.environment-allow"

            if [[ -f "$gitignore_base_template" ]]; then
                if ! cp "$gitignore_base_template" "$gitignore_file"; then
                    log ERROR "Failed to copy gitignore base template to $gitignore_file"
                    rm -f "$gitignore_file"
                    return 1
                fi
            else
                log ERROR "Gitignore base template missing ($gitignore_base_template). Cannot create .gitignore."
                rm -f "$gitignore_file"
                return 1
            fi

            local credentials_ignore_path="$credentials_git_relative_dir"
            credentials_ignore_path="${credentials_ignore_path#/}"
            credentials_ignore_path="${credentials_ignore_path%/}"
            if [[ -z "$credentials_ignore_path" ]]; then
                credentials_ignore_path="$credentials_folder_name"
            fi

            if [[ $credentials == 2 ]]; then
                {
                    echo ""
                    echo "# Allow credential directory for remote storage"
                    echo '!'"$credentials_ignore_path/"
                    echo '!'"$credentials_ignore_path"'/**'
                } >> "$gitignore_file"
                log DEBUG "Created .gitignore entries permitting credential directory tracking"
            else
                if [[ -f "$gitignore_credentials_template" ]]; then
                    local escaped_credentials_path="$credentials_ignore_path"
                    escaped_credentials_path="${escaped_credentials_path//\\/\\\\}"
                    escaped_credentials_path="${escaped_credentials_path//&/\\&}"
                    escaped_credentials_path="${escaped_credentials_path//\//\\/}"
                    {
                        echo ""
                        sed "s/\\.credentials/$escaped_credentials_path/g" "$gitignore_credentials_template"
                    } >> "$gitignore_file"
                    log SUCCESS "Created .gitignore to prevent credential directory commits from template"
                else
                    log ERROR "Gitignore credentials template missing ($gitignore_credentials_template). Cannot create .gitignore."
                    rm -f "$gitignore_file"
                    return 1
                fi
            fi

            if [[ $environment == 2 ]]; then
                if [[ -f "$gitignore_environment_template" ]]; then
                    {
                        echo ""
                        cat "$gitignore_environment_template"
                    } >> "$gitignore_file"
                    log WARN "Updated .gitignore to allow environment files for remote push"
                else
                    log ERROR "Gitignore environment template missing ($gitignore_environment_template). Cannot create .gitignore."
                    rm -f "$gitignore_file"
                    return 1
                fi
            fi
        fi

        # Check if workflow copy operations failed
        if [ "$copy_status" = "failed" ]; then 
            log ERROR "File copy operations failed, aborting push"
            rm -rf "$tmp_dir"
            return 1
        fi
        log INFO "Cleaning up temporary files in container..."
        if dockExec "$container_id" "rm -f $container_workflows $container_credentials_encrypted $container_credentials_decrypted $container_env" "$is_dry_run"; then
            if ! $is_dry_run; then
                log DEBUG "Temporary workflow and credential exports removed from container"
            fi
        else
            log WARN "Could not clean up temporary files in container."
        fi

        # Git Commit and Push
        if [[ "$folder_structure_committed" == true ]]; then
            if [[ $credentials == 2 ]]; then
                log HEADER "Committing Credentials to Git"
            fi
        else
            if [[ $credentials == 2 ]]; then
                log HEADER "Committing Workflows and Credentials to Git"
            else
                log HEADER "Committing Workflows to Git (Credentials Excluded)"
            fi
        fi
        log INFO "Adding files to Git repository..."
        
        local credentials_staged=false
        local credentials_summary=""
        local need_remote_push=false

        if $is_dry_run; then
            log DRYRUN "Would add workflow folder structure and files to Git index"
            if [[ $credentials == 2 ]]; then
                log DRYRUN "Would also add credentials file to Git index"
            fi
        else
            # Change to the git directory
            cd "$tmp_dir" || { 
                log ERROR "Failed to change to git directory for add operation"; 
                rm -rf "$tmp_dir"; 
                return 1; 
            }
            
            # Debug: Show what files exist in the target directory
            log DEBUG "Files in target directory before Git add:"
            find . -type f -not -path "./.git/*" | head -20 | while read -r file; do
                log DEBUG "  Found: $file"
            done
            
            # NOTE: .gitignore is created but NOT added to Git repository
            # This prevents sensitive data from being committed while keeping .gitignore local only
            
            # Handle credentials separately if needed
            local credentials_committed_added=0
            local credentials_committed_updated=0
            local credentials_committed_deleted=0
            local credentials_committed_renamed=0
            local credential_commit_count=0
            local first_credential_status=""
            local first_credential_name=""
            local first_credential_type=""
            local first_credential_time=""

            if [[ $credentials == 2 ]]; then
                local staged_credentials_path="$credentials_repo_relative_path"

                if [[ -n "$staged_credentials_path" ]]; then
                    while IFS= read -r -d '' status_entry; do
                        [[ -z "$status_entry" ]] && continue

                        local status_code="${status_entry:0:2}"
                        local path_spec="${status_entry:3}"

                        local primary_path="$path_spec"
                        local secondary_path=""

                        local status_prefix=""
                        if [[ "$status_code" == "??" ]]; then
                            status_prefix="A"
                        else
                            if [[ "${status_code:0:1}" != " " ]]; then
                                status_prefix="${status_code:0:1}"
                            else
                                status_prefix="${status_code:1:1}"
                            fi
                        fi
                        [[ -z "$status_prefix" ]] && status_prefix="M"

                        if [[ "$status_prefix" == "R" || "$status_prefix" == "C" ]]; then
                            if ! IFS= read -r -d '' secondary_path; then
                                secondary_path=""
                            fi
                        fi

                        primary_path="${primary_path#./}"
                        secondary_path="${secondary_path#./}"

                        local effective_path="$primary_path"
                        if [[ -n "$secondary_path" ]]; then
                            effective_path="$secondary_path"
                        fi
                        effective_path="${effective_path#./}"

                        local status_label_record="Updated"
                        case "$status_prefix" in
                            A) status_label_record="New" ;;
                            D) status_label_record="Deleted" ;;
                            R) status_label_record="Renamed" ;;
                            *) status_label_record="Updated" ;;
                        esac

                        local credential_file="$tmp_dir/$effective_path"
                        local credential_name=""
                        local credential_type_label=""
                        local credential_timestamp_display=""

                        if [[ -f "$credential_file" ]]; then
                            credential_name=$(jq -r '.name // .displayName // empty' "$credential_file" 2>/dev/null || echo "")
                            local credential_type_raw
                            credential_type_raw=$(jq -r '.type // empty' "$credential_file" 2>/dev/null || echo "")
                            if [[ -n "$credential_type_raw" && "$credential_type_raw" != "null" ]]; then
                                credential_type_label="${credential_type_raw##*.}"
                                if [[ -z "$credential_type_label" ]]; then
                                    credential_type_label="$credential_type_raw"
                                fi
                            fi
                            local credential_timestamp_raw
                            credential_timestamp_raw=$(jq -r '.updatedAt // .createdAt // empty' "$credential_file" 2>/dev/null || echo "")
                            if [[ -n "$credential_timestamp_raw" && "$credential_timestamp_raw" != "null" ]]; then
                                credential_timestamp_display="$(date -d "$credential_timestamp_raw" '+%H:%M %d/%m/%y' 2>/dev/null || echo "")"
                            fi
                        fi

                        if [[ -z "$credential_name" || "$credential_name" == "null" ]]; then
                            credential_name="$(basename "$effective_path" ".json")"
                        fi
                        if [[ -z "$credential_type_label" || "$credential_type_label" == "null" ]]; then
                            credential_type_label="credential"
                        fi

                        local commit_timestamp="$credential_timestamp_display"
                        if [[ -z "$commit_timestamp" || "$commit_timestamp" == "null" ]]; then
                            commit_timestamp="$(date '+%H:%M %d/%m/%y')"
                        fi

                        local commit_subject="$credential_name"
                        local commit_meta=""
                        if [[ -n "$credential_type_label" ]]; then
                            commit_meta="[$credential_type_label]"
                        fi

                        local commit_message="[${status_label_record}] (${commit_timestamp}) - ${commit_subject}"
                        if [[ -n "$commit_meta" ]]; then
                            commit_message+=" ${commit_meta}"
                        fi

                        local additional_stage_path=""
                        if [[ "$status_prefix" == "R" && -n "$primary_path" ]]; then
                            additional_stage_path="$primary_path"
                        fi

                        local commit_exit_code=0
                        commit_individual_credential "$effective_path" "$commit_message" "$tmp_dir" "$additional_stage_path"
                        commit_exit_code=$?
                        case "$commit_exit_code" in
                            0)
                                credentials_staged=true
                                need_remote_push=true
                                if (( credential_commit_count == 0 )); then
                                    first_credential_status="$status_label_record"
                                    first_credential_name="$credential_name"
                                    first_credential_type="$credential_type_label"
                                    first_credential_time="$commit_timestamp"
                                fi
                                credential_commit_count=$((credential_commit_count + 1))
                                case "$status_label_record" in
                                    New) credentials_committed_added=$((credentials_committed_added + 1)) ;;
                                    Deleted) credentials_committed_deleted=$((credentials_committed_deleted + 1)) ;;
                                    Renamed) credentials_committed_renamed=$((credentials_committed_renamed + 1)) ;;
                                    *) credentials_committed_updated=$((credentials_committed_updated + 1)) ;;
                                esac
                                ;;
                            1)
                                cd - > /dev/null || true
                                rm -rf "$tmp_dir"
                                return 1
                                ;;
                            *)
                                ;;
                        esac
                    done < <(git status --porcelain=1 -z --untracked-files=all -- "$staged_credentials_path" 2>/dev/null || printf '')

                    if $credentials_staged; then
                        local summary_parts=()
                        if (( credentials_committed_added > 0 )); then
                            summary_parts+=("$credentials_committed_added new")
                        fi
                        if (( credentials_committed_updated > 0 )); then
                            summary_parts+=("$credentials_committed_updated updated")
                        fi
                        if (( credentials_committed_deleted > 0 )); then
                            summary_parts+=("$credentials_committed_deleted deleted")
                        fi
                        if (( credentials_committed_renamed > 0 )); then
                            summary_parts+=("$credentials_committed_renamed renamed")
                        fi

                        if ((${#summary_parts[@]} > 0)); then
                            local joined_summary=""
                            IFS=', ' read -r joined_summary <<< "${summary_parts[*]}"
                            credentials_summary="Credentials: $joined_summary"
                            log INFO "Credential changes committed: $credentials_summary"
                        else
                            credentials_summary="Credentials"
                        fi
                    fi
                fi
            fi

            # Stage workflow files after credential commits (if needed)
            if [[ $workflows == 2 && $folder_structure_committed == false ]]; then
                log DEBUG "Adding workflow folder structure to repository root"
                local files_added=0
                while IFS= read -r json_file; do
                    local relative_path="${json_file#./}"
                    if [[ -n "$credentials_repo_relative_path" && ( "$relative_path" == "$credentials_repo_relative_path" || "$relative_path" == "$credentials_repo_relative_path"/* ) ]]; then
                        continue
                    fi
                    log DEBUG "Adding workflow file: $json_file"
                    if git_stage_path_literal "$tmp_dir" "$relative_path"; then
                        files_added=$((files_added + 1))
                    else
                        log WARN "Failed to stage workflow file: $relative_path"
                    fi
                done < <(find . -name "*.json" -type f)

                while IFS= read -r dir; do
                    local keep_file="$dir/.gitkeep"
                    if [[ -f "$keep_file" ]]; then
                        local keep_relative="${keep_file#./}"
                        log DEBUG "Adding directory keep file: $keep_relative"
                        git_stage_path_literal "$tmp_dir" "$keep_relative" || true
                    fi
                done < <(find . -type d -not -path "./.git*" -not -path ".")

                log DEBUG "Workflow JSON files staged: $files_added"

                log DEBUG "Git status before commit:"
                git status --short
            fi

        fi
        local workflow_changes_summary=""
        if [[ $workflows == 2 ]]; then
            workflow_changes_summary=$(push_generate_workflow_commit_message "$target_dir" "$is_dry_run")
            if [[ "$workflow_changes_summary" == "No workflow changes" || "$workflow_changes_summary" == "Push workflow changes (dry run)" ]]; then
                workflow_changes_summary=""
            fi
        fi

        local commit_timestamp_display
        commit_timestamp_display="$(date '+%H:%M %d/%m/%y')"
        local project_label
        project_label="$(project_display_label)"

        local summary_components=()
        if [[ -n "$workflow_changes_summary" ]]; then
            summary_components+=("Workflows: $workflow_changes_summary")
        fi
        if $credentials_staged; then
            if [[ -n "$credentials_summary" ]]; then
                summary_components+=("$credentials_summary")
            else
                summary_components+=("Credentials")
            fi
        fi

        if [[ ${#summary_components[@]} -gt 0 ]]; then
            local joined_components=""
            IFS=' | ' read -r joined_components <<< "${summary_components[*]}"
            log DEBUG "Commit summary components: $joined_components"
        fi

        local commit_status_label="Push"
        local commit_subject="$project_label"
        local commit_meta=""
        local commit_extra=""

        if $credentials_staged && (( credential_commit_count > 0 )); then
            if [[ -n "$first_credential_status" ]]; then
                commit_status_label="$first_credential_status"
            else
                commit_status_label="Updated"
            fi
            if [[ -n "$first_credential_name" ]]; then
                commit_subject="$first_credential_name"
            fi
            if [[ -n "$first_credential_type" && "$first_credential_type" != "null" ]]; then
                commit_meta="[$first_credential_type]"
            else
                commit_meta="[credential]"
            fi
            if [[ -n "$first_credential_time" ]]; then
                commit_timestamp_display="$first_credential_time"
            fi
            if (( credential_commit_count > 1 )); then
                local remaining_credentials=$((credential_commit_count - 1))
                commit_extra=" (+${remaining_credentials} more)"
            fi
        elif [[ -n "$workflow_changes_summary" && "$workflow_changes_summary" != "No workflow changes" ]]; then
            commit_subject="$project_label"
            commit_meta="[$workflow_changes_summary]"
            if [[ "$workflow_changes_summary" =~ ^([0-9]+)[[:space:]]+new$ ]] && (( BASH_REMATCH[1] > 0 )); then
                commit_status_label="New"
            elif [[ "$workflow_changes_summary" =~ [Dd]eleted ]]; then
                commit_status_label="Deleted"
            else
                commit_status_label="Updated"
            fi
        else
            commit_status_label="Updated"
            commit_subject="$project_label"
        fi

        local commit_msg="[${commit_status_label}] (${commit_timestamp_display}) - ${commit_subject}"
        if [[ -n "$commit_meta" ]]; then
            commit_msg+=" ${commit_meta}"
        fi
        commit_msg+="$commit_extra"
        
        # Ensure git identity is configured
        if $is_dry_run; then
            log DRYRUN "Would configure Git identity if needed"
            log DRYRUN "Would commit with message: $commit_msg"
        else
            if [[ -z "$(git config user.email 2>/dev/null)" ]]; then
                local configured_email="${git_commit_email:-n8n-push-script@localhost}"
                log WARN "No Git user.email configured, setting default to $configured_email"
                git config user.email "$configured_email" || true
            fi
            if [[ -z "$(git config user.name 2>/dev/null)" ]]; then
                local configured_name="${git_commit_name:-n8n-push-script}"
                log WARN "No Git user.name configured, setting default to $configured_name"
                git config user.name "$configured_name" || true
            fi
            
            if $folder_structure_committed; then
                if ! git diff --cached --quiet; then
                    if git_run_capture_stderr git commit -m "$commit_msg" >/dev/null; then
                        log SUCCESS "Credentials commit created successfully"
                    else
                        if [[ -n "$GIT_LAST_STDERR" ]]; then
                            log DEBUG "git commit error: $GIT_LAST_STDERR"
                        fi
                        log ERROR "Failed to commit credentials"
                        rm -rf "$tmp_dir"
                        return 1
                    fi
                else
                    log INFO "No staged changes after folder-structure commits"
                fi

                log DEBUG "Pushing any changes to remote repository..."
                if git_run_capture_stderr git push origin "$branch" >/dev/null; then
                    log SUCCESS "Synced to GitHub repository successfully"
                else
                    if [[ -n "$GIT_LAST_STDERR" ]]; then
                        log DEBUG "git push error: $GIT_LAST_STDERR"
                    fi
                    log ERROR "Failed to push workflow commits to remote repository"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                # Commit changes
                if git diff --cached --quiet; then
                    if $need_remote_push; then
                        log INFO "Pushing credential commits to remote repository..."
                        if git_run_capture_stderr git push origin "$branch" >/dev/null; then
                            log SUCCESS "Pushed to GitHub repository successfully"
                        else
                            if [[ -n "$GIT_LAST_STDERR" ]]; then
                                log DEBUG "git push error: $GIT_LAST_STDERR"
                            fi
                            log ERROR "Failed to push changes to remote repository"
                            rm -rf "$tmp_dir"
                            return 1
                        fi
                    else
                        log WARN "No changes detected in Git repository - nothing to commit"
                    fi
                else
                    if git_run_capture_stderr git commit -m "$commit_msg" >/dev/null; then
                        log SUCCESS "Changes committed successfully"
                        
                        # Push to remote repository
                        log INFO "Pushing changes to remote repository..."
                        if git_run_capture_stderr git push origin "$branch" >/dev/null; then
                            log SUCCESS "Pushed to GitHub repository successfully"
                        else
                            if [[ -n "$GIT_LAST_STDERR" ]]; then
                                log DEBUG "git push error: $GIT_LAST_STDERR"
                            fi
                            log ERROR "Failed to push changes to remote repository"
                            rm -rf "$tmp_dir"
                            return 1
                        fi
                    else
                        if [[ -n "$GIT_LAST_STDERR" ]]; then
                            log DEBUG "git commit error: $GIT_LAST_STDERR"
                        fi
                        log ERROR "Failed to commit changes"
                        rm -rf "$tmp_dir"
                        return 1
                    fi
                fi
            fi
        fi

        # Cleanup
        cd - > /dev/null || true
        rm -rf "$tmp_dir"
        log INFO "Git temporary directory cleaned up"
    fi

    # --- Final Summary ---
    log HEADER "Push Summary"

    local summary_failed=false

    # Workflows summary
    if [[ $workflows == 0 ]]; then
        log INFO "📄 Workflows: Push disabled"
    elif [[ $workflows == 1 ]]; then
        if $local_workflows_saved; then
            log SUCCESS "📄 Workflows: Stored securely in local storage ($local_workflows_file)"
        else
            log WARN "📄 Workflows: Local push requested but no file was saved"
            summary_failed=true
        fi
    elif [[ $workflows == 2 ]]; then
        if $remote_workflows_saved; then
            if [[ $folder_structure_committed == true ]]; then
                log SUCCESS "📄 Workflows: Stored in Git repository with folder structure"
            else
                log SUCCESS "📄 Workflows: Stored in Git repository"
            fi
        else
            log WARN "📄 Workflows: Git push requested but no files were committed"
            summary_failed=true
        fi
    fi

    if [[ -f "$container_credentials_decrypted" ]]; then
        rm -f "$container_credentials_decrypted" || true
    fi

    # Credentials summary
    if [[ $credentials == 0 ]]; then
        log INFO "🔒 Credentials: Push disabled"
    elif [[ $credentials == 1 ]]; then
        if $local_credentials_saved; then
            log SUCCESS "🔒 Credentials: Stored securely in local storage ($local_credentials_dir)"
        else
            log WARN "🔒 Credentials: Local push requested but no file was saved"
            summary_failed=true
        fi
    elif [[ $credentials == 2 ]]; then
        if $remote_credentials_saved; then
            if [[ "${credentials_encrypted:-true}" == "false" ]]; then
                log WARN "🔓 Credentials: Stored in Git repository (decrypted export - high risk)"
            else
                log SUCCESS "🔒 Credentials: Stored in Git repository (encrypted export)"
            fi
        else
            log WARN "🔒 Credentials: Git push requested but no files were committed"
            summary_failed=true
        fi
    fi

    # Environment summary
    if [[ $environment == 0 ]]; then
        log INFO "🌱 Environment: Skipped"
    elif [[ $environment == 1 ]]; then
        if $local_env_saved; then
            log SUCCESS "🌱 Environment: Stored locally ($local_env_file)"
        elif [[ $environment_exported == true ]]; then
            log WARN "🌱 Environment: Captured variables but failed to save locally"
            summary_failed=true
        else
            log INFO "🌱 Environment: No environment variables detected in container"
        fi
    elif [[ $environment == 2 ]]; then
        if $remote_environment_saved; then
            if [[ -n "$environment_git_relative_path" ]]; then
                log WARN "🌱 Environment: Stored in Git repository at $environment_git_relative_path (review access controls)"
            else
                log WARN "🌱 Environment: Stored in Git repository (review access controls)"
            fi
        elif [[ $environment_exported == true ]]; then
            log WARN "🌱 Environment: Captured variables but failed to copy to Git repository"
            summary_failed=true
        else
            log WARN "🌱 Environment: Git push requested but no environment variables were captured"
            summary_failed=true
        fi
    fi

    if $summary_failed; then
        log WARN "Push completed with warnings. Review the details above."
    else
        log SUCCESS "Push completed successfully."
    fi
    
    return 0
}
