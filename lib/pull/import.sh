#!/usr/bin/env bash
# =========================================================
# lib/pull/import.sh - Pull import operations for n8n-git
# =========================================================
# All pull-related functions: orchestrate pull/import flows

# Source required modules
PULL_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1091 # modules resolved relative to this file at runtime
source "$PULL_LIB_DIR/../utils/common.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/../n8n/snapshot.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/../github/git.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/utils.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/staging.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/folder-state.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/folder-sync.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/folder-assignment.sh"
# shellcheck disable=SC1091
source "$PULL_LIB_DIR/validate.sh"

pull_import() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local workflows_mode="${5:-2}"
    local credentials_mode="${6:-1}"
    local apply_folder_structure="${7:-auto}"
    local is_dry_run=${8:-false}
    local credentials_folder_name="${9:-.credentials}"
    local interactive_mode="${10:-false}"
    local preserve_ids="${11:-false}"
    local no_overwrite="${12:-false}"
    local existing_repo_path="${13:-}"
    local folder_structure_backup=false
    local download_dir=""
    local repo_workflows=""
    local structured_workflows_dir=""
    local resolved_structured_dir=""
    local staged_manifest_file=""
    local repo_credentials=""
    local repo_credentials_type=""
    local selected_base_dir=""
    local keep_api_session_alive="false"
    local selected_backup=""
    local dated_backup_found=false
    preserve_ids="$(normalize_boolean_option "$preserve_ids")"
    local preserve_ids_requested="$preserve_ids"

    # Helper to cleanup download dir only if we created it
    cleanup_download_dir() {
        if [[ -z "$existing_repo_path" && -n "$download_dir" ]]; then
            cleanup_temp_path "$download_dir"
        else
            return 1
        fi
    }

    invalidate_n8n_state_cache

    no_overwrite="$(normalize_boolean_option "$no_overwrite")"
    if [[ "$no_overwrite" == "true" ]]; then
        preserve_ids="false"
    fi

    if [[ "$workflows_mode" != "0" ]]; then
        if [[ "$no_overwrite" == "true" ]]; then
            log INFO "Workflow pull will always assign new workflow IDs (--no-overwrite enabled)."
        elif [[ "$preserve_ids" == "true" ]]; then
            log INFO "Workflow pull will attempt to preserve existing workflow IDs when possible."
        else
            log INFO "Workflow pull will reuse workflow IDs when safe and mint new ones only if conflicts arise."
        fi
    fi

    local resolved_local_backup_dir="${local_backup_path:-}"
    if [[ -z "$resolved_local_backup_dir" || "${local_backup_path_source:-}" == "default" || "${local_backup_path_source:-}" == "unset" ]]; then
        resolved_local_backup_dir="$HOME/n8n-backup"
    fi
    resolved_local_backup_dir="$(posix_path_for_host_shell "$resolved_local_backup_dir")"
    local local_backup_dir="$resolved_local_backup_dir"
    local local_credentials_dir="$local_backup_dir/$credentials_folder_name"
    local local_credentials_legacy_file="$local_backup_dir/credentials.json"
    local requires_remote=false

    credentials_folder_name="${credentials_folder_name%/}"
    if [[ -z "$credentials_folder_name" ]]; then
        credentials_folder_name=".credentials"
    fi
    
    # Simplified path logic: treat credentials folder as relative to the repository root (or github_path)
    local credentials_git_relative_dir="$credentials_folder_name"
    local credentials_dir_relative="$credentials_git_relative_dir"
    local credentials_subpath="$credentials_git_relative_dir/credentials.json"

    # Simplified project logic: do not assume project folders exist in Git
    local project_storage_relative=""

    local restore_scope="none"
    if [[ "$workflows_mode" != "0" && "$credentials_mode" != "0" ]]; then
        restore_scope="all"
    elif [[ "$workflows_mode" != "0" ]]; then
        restore_scope="workflows"
    elif [[ "$credentials_mode" != "0" ]]; then
        restore_scope="credentials"
    fi

    log INFO "Workflows: $(format_storage_value "$workflows_mode"), Credentials: $(format_storage_value "$credentials_mode")"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Show pull plan for clarity
    # --- 1. Prepare backup sources based on selected modes ---
    log HEADER "Preparing Backup Sources"

    if [[ "$workflows_mode" == "2" || "$credentials_mode" == "2" ]]; then
        requires_remote=true
    fi

    if [[ -n "$existing_repo_path" && -d "$existing_repo_path" ]]; then
        log INFO "Repository ready"
        log DEBUG "Reusing existing repository at $existing_repo_path"
        download_dir="$existing_repo_path"
        requires_remote=false # Skip cloning
        selected_base_dir="$download_dir"
    fi

    if $requires_remote; then
        download_dir=$(mktemp -d -t n8n-download-XXXXXXXXXX)

        local git_repo_url="https://${github_token}@github.com/${github_repo}.git"
        local sparse_target=""
        if [[ -n "$github_path" ]]; then
            local resolved_path
            resolved_path="$(render_github_path_with_tokens "$github_path")"
            sparse_target="${resolved_path#/}"
            sparse_target="${sparse_target%/}"
        fi

        local -a git_clone_args=("--depth" "1" "--branch" "$branch")
        local sparse_requested=false
        if [[ -n "$sparse_target" ]]; then
            sparse_requested=true
            git_clone_args+=("--filter=blob:none" "--no-checkout")
            if git clone -h 2>&1 | grep -q -- '--sparse'; then
                git_clone_args+=("--sparse")
            fi
        fi

        log INFO "Cloning repository $github_repo branch $branch..."
        local clone_args_display
        clone_args_display=$(printf '%s ' "${git_clone_args[@]}" "$git_repo_url" "$download_dir")
        clone_args_display="${clone_args_display% }"
        if [[ -n "$github_token" ]]; then
            clone_args_display="${clone_args_display//$github_token/********}"
        fi
        local clone_success=false
        if git_run_capture_stderr git clone "${git_clone_args[@]}" "$git_repo_url" "$download_dir" >/dev/null; then
            clone_success=true
        else
            if [[ -n "$GIT_LAST_STDERR" ]]; then
                log WARN "git clone stderr: $GIT_LAST_STDERR"
            fi
            if $sparse_requested; then
                log WARN "Sparse-aware clone failed; retrying without sparse options"
                cleanup_download_dir
                download_dir=$(mktemp -d -t n8n-download-XXXXXXXXXX)
                if git_run_capture_stderr git clone --depth 1 --branch "$branch" "$git_repo_url" "$download_dir" >/dev/null; then
                    clone_success=true
                    sparse_requested=false
                else
                    if [[ -n "$GIT_LAST_STDERR" ]]; then
                        log WARN "Retry clone stderr: $GIT_LAST_STDERR"
                    fi
                fi
            fi
        fi

        if [[ "$clone_success" == false ]]; then
            log ERROR "Failed to clone repository. Check URL, token, branch, and permissions."
            cleanup_download_dir
            return 1
        fi

        selected_base_dir="$download_dir"

        cd "$download_dir" || {
            log ERROR "Failed to change to download directory"
            cleanup_download_dir
            return 1
        }

        if [[ -n "$sparse_target" ]]; then
            log INFO "Restricting checkout to configured GitHub path: $sparse_target"
            if ! git_configure_sparse_checkout "$download_dir" "$sparse_target" "$branch"; then
                log WARN "Sparse checkout configuration failed; using full repository contents."
                git -C "$download_dir" sparse-checkout disable >/dev/null 2>&1 || true
                if ! git -C "$download_dir" checkout "$branch" >/dev/null 2>&1; then
                    log WARN "Fallback checkout failed; repository contents may be incomplete."
                fi
            fi
        elif [[ "$sparse_requested" == false ]]; then
            git -C "$download_dir" checkout "$branch" >/dev/null 2>&1 || true
        fi

        local backup_dirs=()
        readarray -t backup_dirs < <(find . -type d -name "backup_*" | sort -r)

        if [ ${#backup_dirs[@]} -gt 0 ]; then
            log INFO "Found ${#backup_dirs[@]} dated backup(s):"

            if ! [ -t 0 ] || [[ "${assume_defaults:-false}" == "true" ]]; then
                selected_backup="${backup_dirs[0]}"
                dated_backup_found=true
                log INFO "Auto-selecting most recent backup in non-interactive mode: $selected_backup"
            else
                echo ""
                echo "Select a backup to pull from:"
                echo "------------------------------------------------"
                echo "0) Use files from repository root (not a dated backup)"
                for i in "${!backup_dirs[@]}"; do
                    local backup_date="${backup_dirs[$i]#./backup_}"
                    echo "$((i+1))) ${backup_date} (${backup_dirs[$i]})"
                done
                echo "------------------------------------------------"

                local valid_selection=false
                while ! $valid_selection; do
                    echo -n "Select a backup number (0-${#backup_dirs[@]}): "
                    local selection
                    read -r selection

                    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#backup_dirs[@]}" ]; then
                        valid_selection=true
                        if [ "$selection" -eq 0 ]; then
                            log INFO "Using repository root files (not a dated backup)"
                        else
                            selected_backup="${backup_dirs[$((selection-1))]}"
                            dated_backup_found=true
                            log INFO "Selected backup: $selected_backup"
                        fi
                    else
                        echo "Invalid selection. Please enter a number between 0 and ${#backup_dirs[@]}."
                    fi
                done
            fi
        fi

        if $dated_backup_found; then
            local dated_path="${selected_backup#./}"
            selected_base_dir="$download_dir/$dated_path"
            log INFO "Looking for files in dated backup: $dated_path"
        fi

        # Adjust base directory if github_path is set
        # This ensures that the import logic treats the github_path as the root
        if [[ -n "$github_path" ]]; then
            local resolved_path
            resolved_path="$(render_github_path_with_tokens "$github_path")"
            selected_base_dir="${selected_base_dir%/}/$resolved_path"
        fi

        if [[ "$workflows_mode" == "2" ]]; then
            locate_workflow_artifacts "$selected_base_dir" "$download_dir" "$project_storage_relative" repo_workflows structured_workflows_dir

            if [[ -n "$structured_workflows_dir" ]]; then
                folder_structure_backup=true
                log DEBUG "Detected workflow directory: $structured_workflows_dir"
            elif [[ -n "$repo_workflows" ]]; then
                log SUCCESS "Found workflows.json in remote backup: $repo_workflows"
            fi
        fi

        if [[ "$credentials_mode" == "2" ]]; then
            locate_credentials_artifact "$selected_base_dir" "$download_dir" "$credentials_dir_relative" "$credentials_subpath" repo_credentials repo_credentials_type
            if [[ -n "$repo_credentials" ]]; then
                if [[ "$repo_credentials_type" == "directory" ]]; then
                    log SUCCESS "Found credential directory: $repo_credentials"
                else
                    log SUCCESS "Found credentials file: $repo_credentials"
                fi
            fi
        fi

        if [[ "$credentials_mode" != "0" ]]; then
            local credential_artifact_missing=false
            if [[ "$repo_credentials_type" == "directory" ]]; then
                if [[ -z "$repo_credentials" || ! -d "$repo_credentials" ]]; then
                    credential_artifact_missing=true
                fi
            else
                if [[ -z "$repo_credentials" || ! -f "$repo_credentials" ]]; then
                    credential_artifact_missing=true
                else
                    repo_credentials_type="file"
                fi
            fi

            if $credential_artifact_missing; then
                log WARN "Credentials artifact not found under '$credentials_git_relative_dir'. Skipping credential pull."
                credentials_mode="0"
            fi
        fi

        cd - >/dev/null 2>&1 || true
    else
        log INFO "Skipping Git fetch; relying on local backups only."
    fi

    # If reusing repo, we need to locate artifacts even if requires_remote is false
    if [[ "$workflows_mode" == "2" && -n "$existing_repo_path" ]]; then
         # Adjust base directory if github_path is set (reuse case)
         if [[ -n "$github_path" ]]; then
            local resolved_path
            resolved_path="$(render_github_path_with_tokens "$github_path")"
            selected_base_dir="${selected_base_dir%/}/$resolved_path"
         fi

         locate_workflow_artifacts "$selected_base_dir" "$download_dir" "$project_storage_relative" repo_workflows structured_workflows_dir

        if [[ -n "$structured_workflows_dir" ]]; then
            folder_structure_backup=true
            log DEBUG "Detected workflow directory: $structured_workflows_dir"
        elif [[ -n "$repo_workflows" ]]; then
            log SUCCESS "Found workflows.json in remote backup: $repo_workflows"
        fi
    fi

    if [[ "$workflows_mode" == "1" ]]; then
        selected_base_dir="$local_backup_dir"
        local detected_local_workflows=""
        local detected_local_directory=""
        locate_workflow_artifacts "$local_backup_dir" "$local_backup_dir" "$project_storage_relative" detected_local_workflows detected_local_directory

        if [[ -n "$detected_local_directory" ]]; then
            folder_structure_backup=true
            structured_workflows_dir="$detected_local_directory"
            log INFO "Using workflow directory from local backup: $structured_workflows_dir"
        fi

        if [[ -z "$repo_workflows" && -n "$detected_local_workflows" ]]; then
            repo_workflows="$detected_local_workflows"
            log INFO "Selected local workflows backup: $repo_workflows"
        fi

        if [[ -z "$repo_workflows" && -z "$structured_workflows_dir" ]]; then
            log WARN "No workflows.json or workflow files detected in $local_backup_dir"
        fi
    fi

    if [[ "$credentials_mode" == "1" ]]; then
        if [[ -d "$local_credentials_dir" ]]; then
            repo_credentials="$local_credentials_dir"
            repo_credentials_type="directory"
            log INFO "Selected local credentials directory: $repo_credentials"
        elif [[ -f "$local_credentials_legacy_file" ]]; then
            repo_credentials="$local_credentials_legacy_file"
            repo_credentials_type="file"
            log INFO "Selected local credentials backup: $repo_credentials"
        else
            log WARN "No credentials found in local storage ($local_credentials_dir)"
        fi
    fi

    local credentials_bundle_tmp=""
    local credentials_to_import=""
    local credentials_payload_file=""
    local credentials_import_mode="none"
    local credentials_stage_dir=""
    local credentials_entry_count=-1

    if [[ "$credentials_mode" != "0" ]]; then
        if [[ "$repo_credentials_type" == "directory" ]]; then
            credentials_stage_dir=$(mktemp -d -t n8n-credentials-dir-XXXXXXXX)
            if [[ -z "$credentials_stage_dir" || ! -d "$credentials_stage_dir" ]]; then
                log ERROR "Unable to create staging directory for credentials"
                if [[ -n "$download_dir" ]]; then
                    cleanup_download_dir
                fi
                return 1
            fi
            chmod 700 "$credentials_stage_dir" 2>/dev/null || true

            local copy_failed=false
            local staged_count=0
            while IFS= read -r -d '' credential_file; do
                local target_file
                target_file="$credentials_stage_dir/$(basename "$credential_file")"
                if ! cp "$credential_file" "$target_file" 2>/dev/null; then
                    log ERROR "Failed to stage credential file: $credential_file"
                    copy_failed=true
                    break
                fi
                chmod 600 "$target_file" 2>/dev/null || true
                staged_count=$((staged_count + 1))
            done < <(find "$repo_credentials" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)

            if [[ "$copy_failed" == "true" ]]; then
                cleanup_temp_path "$credentials_stage_dir"
                if [[ -n "$download_dir" ]]; then
                    cleanup_download_dir
                fi
                return 1
            fi

            credentials_entry_count=$staged_count

            if (( staged_count == 0 )); then
                log INFO "Credential directory '$repo_credentials' contained no JSON files; continuing with empty credential set."
            else
                log SUCCESS "Staged $staged_count credential file(s) from $repo_credentials"
            fi

            credentials_bundle_tmp=$(mktemp -t n8n-credentials-bundle-XXXXXXXX.json)
            if ! bundle_credentials_directory "$credentials_stage_dir" "$credentials_bundle_tmp"; then
                log ERROR "Failed to assemble credentials from directory: $repo_credentials"
                cleanup_temp_path "$credentials_stage_dir"
                if [[ -n "$credentials_bundle_tmp" ]]; then
                    rm -f "$credentials_bundle_tmp"
                fi
                if [[ -n "$download_dir" ]]; then
                    cleanup_download_dir
                fi
                return 1
            fi

            credentials_to_import="$credentials_stage_dir"
            credentials_import_mode="directory"
            credentials_payload_file="$credentials_bundle_tmp"
        elif [[ "$repo_credentials_type" == "file" ]]; then
            credentials_to_import="$repo_credentials"
            credentials_import_mode="file"
            credentials_payload_file="$repo_credentials"
            local jq_entry_count
            if jq_entry_count=$(jq -r 'if type=="array" then length else 0 end' "$repo_credentials" 2>/dev/null); then
                if [[ "$jq_entry_count" =~ ^[0-9]+$ ]]; then
                    credentials_entry_count="$jq_entry_count"
                fi
            fi
        else
            log WARN "Credentials artifact unavailable; skipping credential pull."
            credentials_mode="0"
        fi
    fi

    if [[ "$credentials_mode" != "0" && "$credentials_entry_count" -eq 0 ]]; then
        log INFO "No credential entries detected in selected source; skipping credential restoration."
        if [[ "$credentials_import_mode" == "directory" && -n "$credentials_stage_dir" && -d "$credentials_stage_dir" ]]; then
            cleanup_temp_path "$credentials_stage_dir"
            credentials_stage_dir=""
        fi
        if [[ -n "$credentials_bundle_tmp" && -f "$credentials_bundle_tmp" ]]; then
            rm -f "$credentials_bundle_tmp"
            credentials_bundle_tmp=""
        fi
        credentials_import_mode="none"
        credentials_to_import=""
        credentials_payload_file=""
        credentials_mode="0"
    fi

    # Validate files before proceeding
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup && [[ "$apply_folder_structure" == "true" ]]; then
            keep_api_session_alive="true"
        fi
        if $folder_structure_backup; then
            local validation_dir="$structured_workflows_dir"
            if [[ -n "$github_path" ]]; then
                validation_dir="$(resolve_github_storage_root "$selected_base_dir")"
            fi

            if [[ -z "$validation_dir" || ! -d "$validation_dir" ]]; then
                log ERROR "Workflow directory not found for import"
                file_validation_passed=false
                validation_dir=""
            fi

            if [[ -n "$validation_dir" ]]; then
                local separated_count
                separated_count=$(find "$validation_dir" -type f -name "*.json" \
                    ! -path "*/.credentials/*" \
                    ! -name "credentials.json" \
                    ! -name "workflows.json" \
                    -print | wc -l | tr -d ' ')
                if [[ "$separated_count" -eq 0 ]]; then
                    log ERROR "No workflow JSON files found for directory import in $validation_dir"
                    file_validation_passed=false
                else
                    log INFO "Detected $separated_count workflow JSON file(s) for directory import"
                fi
            fi
        else
            if [ ! -f "$repo_workflows" ] || [ ! -s "$repo_workflows" ]; then
                log ERROR "Valid workflows.json not found for $restore_scope pull"
                file_validation_passed=false
            else
                log SUCCESS "Workflows file validated for import"
            fi
        fi
    fi
    
    if [[ "$credentials_mode" != "0" ]]; then
        local credentials_valid=true
        local cred_source_desc="local secure storage"

        if [[ "$credentials_import_mode" == "directory" ]]; then
            if [[ -z "$credentials_to_import" || ! -d "$credentials_to_import" ]]; then
                credentials_valid=false
            elif ! validate_credentials_payload "$credentials_to_import"; then
                credentials_valid=false
            else
                if [[ "$repo_credentials_type" == "directory" && "$repo_credentials" != "$local_credentials_dir" ]]; then
                    cred_source_desc="Git repository directory ($credentials_git_relative_dir)"
                else
                    cred_source_desc="local credential directory"
                fi
            fi
        else
            if [[ -z "$credentials_to_import" || ! -f "$credentials_to_import" ]]; then
                credentials_valid=false
            elif ! validate_credentials_payload "$credentials_to_import"; then
                credentials_valid=false
            else
                if [[ "$repo_credentials" != "$local_credentials_legacy_file" ]]; then
                    cred_source_desc="Git repository ($credentials_git_relative_dir)"
                fi
            fi
        fi

        if ! $credentials_valid; then
            log ERROR "Valid credential bundle not found for $restore_scope pull"
            log ERROR "💡 Suggestion: Run with --credentials 0 to pull workflows only."
            file_validation_passed=false
        else
            if [[ "$credentials_entry_count" -ge 0 ]]; then
                log SUCCESS "Credentials validated for import from $cred_source_desc ($credentials_entry_count file(s))"
            else
                log SUCCESS "Credentials validated for import from $cred_source_desc"
            fi
        fi
    fi

    if [[ "$apply_folder_structure" == "auto" ]]; then
        if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && [ "$file_validation_passed" = "true" ]; then
            if [[ -n "$structured_workflows_dir" && -d "$structured_workflows_dir" ]]; then
                apply_folder_structure="true"
                log INFO "Folder structure backup detected; enabling automatic layout restoration."
            else
                apply_folder_structure="skip"
                log INFO "Workflow directory not detected; skipping folder layout restoration."
            fi
        else
            apply_folder_structure="skip"
        fi
    fi

    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with pull."
        if [[ -n "$download_dir" ]]; then
            if cleanup_download_dir; then
                log INFO "Cleaned up temporary download directory after validation failure: $download_dir"
            else
                log WARN "Unable to remove temporary download directory after validation failure: $download_dir"
            fi
        fi
        if [[ -n "$credentials_bundle_tmp" && -f "$credentials_bundle_tmp" ]]; then
            rm -f "$credentials_bundle_tmp"
        fi
        return 1
    fi
    
    # --- 2. Import Data ---
    log HEADER "Importing Data into n8n"

    local existing_workflow_snapshot=""
    local existing_workflow_mapping=""
    existing_workflow_snapshot_source=""

    local pre_import_workflow_count=0
    if [[ "$workflows_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        if ! capture_existing_workflow_snapshot "$container_id" "$keep_api_session_alive" "$existing_workflow_snapshot" "$is_dry_run" existing_workflow_snapshot; then
            existing_workflow_snapshot=""
        fi
        if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" ]]; then
            local counted_value
            if counted_value=$(jq -r "$WORKFLOW_COUNT_FILTER" "$existing_workflow_snapshot" 2>/dev/null); then
                if [[ -n "$counted_value" && "$counted_value" != "null" ]]; then
                    pre_import_workflow_count="$counted_value"
                fi
            fi
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Pre-import workflow snapshot captured via ${existing_workflow_snapshot_source:-unknown} source"
            fi
        else
            log DEBUG "Pre-import workflow snapshot unavailable; assuming 0 existing workflows"
        fi
        log DEBUG "Pre-import workflow count: $pre_import_workflow_count"
    fi

    local container_import_workflows=""
    local workflow_import_mode="file"
    if $folder_structure_backup; then
        container_import_workflows="/tmp/n8n-workflow-import-dir-$$"
        workflow_import_mode="directory"
    else
        container_import_workflows="/tmp/import_workflows.json"
    fi
    local container_import_credentials="/tmp/import_credentials.json"
    if [[ "$credentials_import_mode" == "directory" ]]; then
        container_import_credentials="/tmp/import_credentials"
    fi

    # --- Credentials decryption integration ---
    local decrypt_tmpfile=""
    local skip_credentials_restore=false
    local skip_credentials_reason=""
    if [[ "$credentials_mode" != "0" && -n "$credentials_payload_file" ]]; then
        # Only attempt decryption if not a dry run and payload file is not empty
        if [ "$is_dry_run" != "true" ] && [ -s "$credentials_payload_file" ]; then
            # Check if payload appears to be encrypted (any credential with string data)
            if jq -e '[.[] | select(has("data") and (.data | type == "string"))] | length > 0' "$credentials_payload_file" >/dev/null 2>&1; then
                log INFO "Encrypted credentials detected. Preparing decryption flow..."
                local decrypt_lib
                decrypt_lib="$PULL_LIB_DIR/../n8n/decrypt.sh"
                if [[ ! -f "$decrypt_lib" ]]; then
                    decrypt_lib="$PULL_LIB_DIR/decrypt.sh"
                fi
                if [[ ! -f "$decrypt_lib" ]]; then
                    decrypt_lib="$PULL_LIB_DIR/../decrypt.sh"
                fi
                if [[ ! -f "$decrypt_lib" ]]; then
                    log ERROR "Decrypt helper not found at $decrypt_lib"
                    if [[ -n "$download_dir" ]]; then
                        cleanup_download_dir
                    fi
                    return 1
                fi
                # shellcheck disable=SC1090,SC1091
                source "$decrypt_lib"
                check_dependencies

                local prompt_device="/dev/tty"
                if [[ ! -r "$prompt_device" ]]; then
                    prompt_device="/proc/self/fd/2"
                fi

                if [[ "$interactive_mode" == "true" ]]; then
                    local decrypt_success=false
                    while true; do
                        local decryption_key=""
                        printf "Enter encryption key for credentials decryption (leave blank to skip): " >"$prompt_device"
                        if ! read -r -s decryption_key <"$prompt_device"; then
                            printf '\n' >"$prompt_device" 2>/dev/null || true
                            log ERROR "Unable to read encryption key from terminal."
                            skip_credentials_restore=true
                            skip_credentials_reason="Unable to read encryption key from terminal. Skipping credential pull."
                            break
                        fi

                        printf '\n' >"$prompt_device" 2>/dev/null || echo >&2

                        if [[ -z "$decryption_key" ]]; then
                            skip_credentials_restore=true
                            skip_credentials_reason="No encryption key provided. Skipping credential pull."
                            break
                        fi

                        local attempt_tmpfile
                        attempt_tmpfile="$(mktemp -t n8n-decrypted-XXXXXXXX.json)"
                        if decrypt_credentials_file "$decryption_key" "$credentials_payload_file" "$attempt_tmpfile"; then
                            if ! validate_credentials_payload "$attempt_tmpfile" ; then
                                log ERROR "Decrypted credentials failed validation."
                                rm -f "$attempt_tmpfile"
                            else
                                log SUCCESS "Credentials decrypted successfully."
                                decrypt_tmpfile="$attempt_tmpfile"
                                credentials_payload_file="$decrypt_tmpfile"
                                if [[ "$credentials_import_mode" == "file" ]]; then
                                    credentials_to_import="$decrypt_tmpfile"
                                elif [[ "$credentials_import_mode" == "directory" ]]; then
                                    if ! render_credentials_bundle_to_directory "$decrypt_tmpfile" "$credentials_stage_dir" false "decrypted credential staging"; then
                                        log ERROR "Failed to materialize decrypted credentials into staging directory."
                                        rm -f "$attempt_tmpfile"
                                        decrypt_tmpfile=""
                                        credentials_payload_file="$credentials_bundle_tmp"
                                        break
                                    fi
                                fi
                                decrypt_success=true
                                break
                            fi
                        else
                            log ERROR "Failed to decrypt credentials with provided key."
                            rm -f "$attempt_tmpfile"
                        fi
                    done

                    if [[ "$decrypt_success" != "true" && "$skip_credentials_restore" != "true" ]]; then
                        skip_credentials_restore=true
                        skip_credentials_reason="Decryption did not succeed. Skipping credential pull."
                    fi
                else
                    skip_credentials_restore=true
                    skip_credentials_reason="Encrypted credentials detected but running in non-interactive mode; skipping credential pull."
                fi
            fi
        fi
    fi

    if [[ "$skip_credentials_restore" == "true" ]]; then
        credentials_mode="0"
        credentials_to_import=""
        if [[ "$credentials_import_mode" == "directory" && -n "$credentials_stage_dir" && -d "$credentials_stage_dir" ]]; then
            cleanup_temp_path "$credentials_stage_dir"
            credentials_stage_dir=""
        fi
        if [[ -n "$decrypt_tmpfile" ]]; then
            rm -f "$decrypt_tmpfile"
            decrypt_tmpfile=""
        fi
        if [[ -n "$skip_credentials_reason" ]]; then
            log WARN "$skip_credentials_reason"
        else
            log WARN "Credential pull will be skipped; continuing with remaining pull tasks."
        fi
    fi

    if [[ "$credentials_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        if ! validate_credentials_payload "$credentials_to_import"; then
            if [[ -n "$decrypt_tmpfile" ]]; then
                rm -f "$decrypt_tmpfile"
            fi
            if [[ "$credentials_import_mode" == "directory" && -n "$credentials_stage_dir" && -d "$credentials_stage_dir" ]]; then
                cleanup_temp_path "$credentials_stage_dir"
            fi
            if [[ -n "$download_dir" ]]; then
                cleanup_download_dir
            fi
            return 1
        fi
    fi

    log INFO "Copying files to container..."
    local copy_status="success"

    # Copy workflow file if needed
    if [[ "$workflows_mode" != "0" ]]; then
        local stage_target_folder=""
        if [[ -n "${n8n_path:-}" ]]; then
            stage_target_folder="${n8n_path#/}"
            stage_target_folder="${stage_target_folder%/}"
        fi

        # Note: We do NOT append github_path to stage_target_folder.
        # github_path defines the SOURCE scope in the repo.
        # n8n_path defines the DESTINATION scope in n8n.
        # If the user wants to map repo/folder -> n8n/root, github_path=folder, n8n_path=root.

        if $folder_structure_backup; then
            local stage_source_dir="$structured_workflows_dir"
            if [[ -n "$github_path" ]]; then
                stage_source_dir="$(resolve_github_storage_root "$selected_base_dir")"
            fi

            if [[ -n "$structured_workflows_dir" && -n "$stage_source_dir" ]]; then
                local stage_folder_subpath=""
                local normalized_root="${structured_workflows_dir%/}"
                local normalized_stage="${stage_source_dir%/}"
                if [[ "$normalized_stage" == "$normalized_root" ]]; then
                    stage_folder_subpath=""
                elif [[ "$normalized_stage" == "$normalized_root"/* ]]; then
                    stage_folder_subpath="${normalized_stage#"$normalized_root"/}"
                fi

                if [[ -n "$stage_folder_subpath" ]]; then
                    stage_folder_subpath="${stage_folder_subpath#/}"
                    stage_folder_subpath="${stage_folder_subpath%/}"
                    if [[ "$stage_folder_subpath" == "workflows" ]]; then
                        stage_folder_subpath=""
                    elif [[ "$stage_folder_subpath" == workflows/* ]]; then
                        stage_folder_subpath="${stage_folder_subpath#workflows/}"
                    fi
                    if [[ -n "$stage_folder_subpath" ]]; then
                        if [[ -n "$stage_target_folder" ]]; then
                            local trimmed_target
                            trimmed_target="${stage_target_folder%/}"
                            local suffix="/$stage_folder_subpath"
                            if [[ "$trimmed_target" == "$stage_folder_subpath" ]]; then
                                :
                            elif (( ${#trimmed_target} >= ${#suffix} )) && [[ "${trimmed_target: -${#suffix}}" == "$suffix" ]]; then
                                :
                            else
                                stage_target_folder="${stage_target_folder%/}/$stage_folder_subpath"
                            fi
                        else
                            stage_target_folder="$stage_folder_subpath"
                        fi
                    fi
                fi
            fi

            if [[ "$is_dry_run" == "true" ]]; then
                resolved_structured_dir="$stage_source_dir"
                if [[ -z "$stage_source_dir" || ! -d "$stage_source_dir" ]]; then
                    log DRYRUN "Would skip staging workflows because source directory is unavailable (${stage_source_dir:-<empty>})"
                else
                    log DRYRUN "Would stage workflows in ${container_import_workflows} by scanning directory $stage_source_dir"
                fi
            else
                if [[ -z "$stage_source_dir" || ! -d "$stage_source_dir" ]]; then
                    log ERROR "Workflow directory not found for staging: ${stage_source_dir:-<empty>}"
                    copy_status="failed"
                elif ! dockExec "$container_id" "rm -rf $container_import_workflows && mkdir -p $container_import_workflows" false; then
                    log ERROR "Failed to prepare container directory for workflow import."
                    copy_status="failed"
                else
                    if [[ "$is_dry_run" != "true" ]]; then
                        if ! capture_existing_workflow_snapshot "$container_id" "$keep_api_session_alive" "$existing_workflow_snapshot" "$is_dry_run" existing_workflow_snapshot; then
                            existing_workflow_snapshot=""
                        fi
                        if [[ -n "$existing_workflow_snapshot" ]]; then
                            log DEBUG "Captured existing workflow snapshot from ${existing_workflow_snapshot_source:-unknown} source for duplicate detection."
                        fi
                    fi

                    if [[ -z "$existing_workflow_mapping" && "$is_dry_run" != "true" ]]; then
                        if [[ -n "$n8n_base_url" ]]; then
                            local mapping_json=""
                            if get_workflow_folder_mapping "$container_id" "" mapping_json; then
                                existing_workflow_mapping=$(mktemp -t n8n-workflow-map-XXXXXXXX.json)
                                printf '%s' "$mapping_json" > "$existing_workflow_mapping"
                                log DEBUG "Captured workflow folder mapping for duplicate detection."
                            else
                                log WARN "Unable to retrieve workflow folder mapping; duplicate matching will fall back to snapshot data."
                            fi
                        else
                            log DEBUG "Skipping workflow mapping fetch; n8n base URL not configured."
                        fi
                    fi

                    staged_manifest_file=$(mktemp -t n8n-staged-workflows-XXXXXXXX.json)
                    if ! stage_directory_workflows_to_container "$stage_source_dir" "$container_id" "$container_import_workflows" "$staged_manifest_file" "$existing_workflow_snapshot" "$preserve_ids" "$no_overwrite" "$existing_workflow_mapping" "$stage_target_folder"; then
                        rm -f "$staged_manifest_file"
                        log ERROR "Failed to copy workflow files into container."
                        copy_status="failed"
                    else
                        resolved_structured_dir="$stage_source_dir"
                    fi
                fi
            fi
        else
            if [ "$is_dry_run" = "true" ]; then
                log DRYRUN "Would copy $repo_workflows to ${container_id}:${container_import_workflows}"
            else
                local docker_cp_repo_workflows
                docker_cp_repo_workflows=$(convert_path_for_docker_cp "$repo_workflows")
                [[ -z "$docker_cp_repo_workflows" ]] && docker_cp_repo_workflows="$repo_workflows"
                if docker cp "$docker_cp_repo_workflows" "${container_id}:${container_import_workflows}"; then
                    log SUCCESS "Successfully copied workflows.json to container"
                else
                    log ERROR "Failed to copy workflows.json to container."
                    copy_status="failed"
                fi
            fi
        fi

        if [[ "$copy_status" == "success" ]]; then
            if [[ "$is_dry_run" != "true" ]]; then
                if ! capture_existing_workflow_snapshot "$container_id" "$keep_api_session_alive" "$existing_workflow_snapshot" "$is_dry_run" existing_workflow_snapshot; then
                    existing_workflow_snapshot=""
                fi
                if [[ -n "$existing_workflow_snapshot" ]]; then
                    log DEBUG "Captured pre-import workflows snapshot for post-import ID detection."
                fi

                # Preserve staged manifest for in-place updates during reconciliation
                if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                    local staged_manifest_debug_path="${PULL_MANIFEST_STAGE_DEBUG_PATH:-${RESTORE_MANIFEST_STAGE_DEBUG_PATH:-}}"
                    persist_manifest_debug_copy "$staged_manifest_file" "$staged_manifest_debug_path" "staged manifest"
                    # Keep staged_manifest_file for in-place reconciliation (no copy needed)
                fi
            fi
        fi
    fi

    # Copy credentials file if needed (use decrypted if available)
    if [[ "$credentials_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            if [[ "$credentials_import_mode" == "directory" ]]; then
                log DRYRUN "Would copy credential directory $credentials_to_import to ${container_id}:${container_import_credentials}/"
            else
                log DRYRUN "Would copy $credentials_to_import to ${container_id}:${container_import_credentials}"
            fi
        else
            if [[ "$credentials_import_mode" == "directory" ]]; then
                if ! dockExec "$container_id" "rm -rf '$container_import_credentials' && mkdir -p '$container_import_credentials'" false; then
                    log ERROR "Failed to prepare container directory for credential import"
                    copy_status="failed"
                else
                    local docker_cp_credentials_dir
                    docker_cp_credentials_dir=$(convert_path_for_docker_cp "${credentials_to_import}/.")
                    [[ -z "$docker_cp_credentials_dir" ]] && docker_cp_credentials_dir="${credentials_to_import}/."
                    if docker cp "$docker_cp_credentials_dir" "${container_id}:${container_import_credentials}/"; then
                        log SUCCESS "Successfully copied credential directory to container"
                    else
                        log ERROR "Failed to copy credential directory to container."
                        copy_status="failed"
                    fi
                fi
            else
                local docker_cp_credentials_file
                docker_cp_credentials_file=$(convert_path_for_docker_cp "$credentials_to_import")
                [[ -z "$docker_cp_credentials_file" ]] && docker_cp_credentials_file="$credentials_to_import"
                if docker cp "$docker_cp_credentials_file" "${container_id}:${container_import_credentials}"; then
                    log SUCCESS "Successfully copied credential bundle to container"
                else
                    log ERROR "Failed to copy credential bundle to container."
                    copy_status="failed"
                fi
            fi
        fi
    fi

    # Clean up decrypted temp file if used
    if [ -n "$decrypt_tmpfile" ]; then
        rm -f "$decrypt_tmpfile"
    fi
    if [[ -n "$credentials_bundle_tmp" && -f "$credentials_bundle_tmp" ]]; then
        rm -f "$credentials_bundle_tmp"
    fi
    if [[ "$credentials_import_mode" == "directory" && -n "$credentials_stage_dir" && -d "$credentials_stage_dir" ]]; then
        cleanup_temp_path "$credentials_stage_dir"
    fi
    
    if [ "$copy_status" = "failed" ]; then
        log ERROR "Failed to copy files to container - cannot proceed with pull"
        if [[ -n "$download_dir" ]]; then
            cleanup_download_dir
        fi
        return 1
    fi

    if [ "$is_dry_run" != "true" ]; then
        if [[ "$workflows_mode" != "0" ]]; then
            dockExecAsRoot "$container_id" "if [ -d '$container_import_workflows' ]; then chown -R node:node '$container_import_workflows'; fi" false || log WARN "Unable to adjust ownership for workflow import directory"
        fi
        if [[ "$credentials_mode" != "0" ]]; then
            dockExecAsRoot "$container_id" "if [ -e '$container_import_credentials' ]; then chown -R node:node '$container_import_credentials'; fi" false || log WARN "Unable to adjust ownership for credentials import file"
        fi
    fi
    
    # Import data
    log INFO "Importing data into n8n..."
    local import_status="success"
    
    # Import workflows if needed
    if [[ "$workflows_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            if [[ "$workflow_import_mode" == "directory" ]]; then
                log DRYRUN "Would enumerate workflow JSON files under $container_import_workflows and import each individually"
            else
                log DRYRUN "Would run: N8N_IMPORT_EXPORT_OVERWRITE=false n8n import:workflow --input=$container_import_workflows"
            fi
        else
            log INFO "Importing workflows..."
            if [[ "$workflow_import_mode" == "directory" ]]; then
                local -a container_workflow_files=()
                if ! mapfile -t container_workflow_files < <(docker exec "$container_id" sh -c "find '$container_import_workflows' -type f -name '*.json' -print 2>/dev/null | sort" ); then
                    log ERROR "Unable to enumerate staged workflows in $container_import_workflows"
                    import_status="failed"
                elif ((${#container_workflow_files[@]} == 0)); then
                    log ERROR "No workflow JSON files found in $container_import_workflows to import"
                    import_status="failed"
                else
                    local imported_count=0
                    local failed_count=0
                    for workflow_file in "${container_workflow_files[@]}"; do
                        if [[ -z "$workflow_file" ]]; then
                            continue
                        fi
                        local wf_name
                        wf_name=$(docker exec "$container_id" cat "$workflow_file" | jq -r '.name // "Unknown"')
                        log INFO "Importing workflow: $wf_name"
                        local escaped_file
                        escaped_file=$(printf '%q' "$workflow_file")
                        if ! dockExec "$container_id" "N8N_IMPORT_EXPORT_OVERWRITE=false n8n import:workflow --input=$escaped_file" false; then
                            log ERROR "Failed to import workflow file: $workflow_file"
                            failed_count=$((failed_count + 1))
                        else
                            imported_count=$((imported_count + 1))
                        fi
                    done

                    if (( failed_count > 0 )); then
                        log ERROR "Failed to import $failed_count workflow file(s) from $container_import_workflows"
                        import_status="failed"
                    else
                        log SUCCESS "Imported $imported_count workflow file(s)"
                        
                        # Capture post-import snapshot to identify newly created workflow IDs
                        if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" && -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                            local post_import_snapshot=""
                            SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
                            if snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"; then
                                post_import_snapshot="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
                                log DEBUG "Captured post-import workflow snapshot for ID reconciliation"
                                
                                # Update manifest with actual imported workflow IDs by comparing snapshots
                                local updated_manifest
                                updated_manifest=$(mktemp -t n8n-updated-manifest-XXXXXXXX.ndjson)
                                if reconcile_imported_workflow_ids "$existing_workflow_snapshot" "$post_import_snapshot" "$staged_manifest_file" "$updated_manifest"; then
                                    mv "$updated_manifest" "$staged_manifest_file"
                                    log INFO "Reconciled manifest with actual imported workflow IDs from n8n"
                                    summarize_manifest_assignment_status "$staged_manifest_file" "post-import"
                                else
                                    rm -f "$updated_manifest"
                                    log WARN "Unable to reconcile workflow IDs from post-import snapshot; folder assignment may be affected"
                                fi
                                
                                rm -f "$post_import_snapshot"
                            else
                                log WARN "Failed to capture post-import snapshot; workflow ID reconciliation skipped"
                            fi
                        fi
                    fi
                fi
            else
                if ! dockExec "$container_id" "N8N_IMPORT_EXPORT_OVERWRITE=false n8n import:workflow --input=$container_import_workflows" "$is_dry_run"; then
                    log WARN "Standard import failed, trying with --separate flag..."
                    if ! dockExec "$container_id" "N8N_IMPORT_EXPORT_OVERWRITE=false n8n import:workflow --separate --input=$container_import_workflows" "$is_dry_run"; then
                        log ERROR "Failed to import workflows"
                        import_status="failed"
                    else
                        log SUCCESS "Workflows imported successfully with --separate flag"
                    fi
                else
                    log SUCCESS "Workflows imported successfully"
                fi
            fi
        fi
    fi
    
    # Import credentials if needed
    if [[ "$credentials_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            if [[ "$credentials_import_mode" == "directory" ]]; then
                log DRYRUN "Would run: n8n import:credentials --separate --input=$container_import_credentials"
            else
                log DRYRUN "Would run: n8n import:credentials --input=$container_import_credentials"
            fi
        else
            log INFO "Importing credentials..."
            if [[ "$credentials_import_mode" == "directory" ]]; then
                if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_import_credentials" "$is_dry_run"; then
                    log WARN "Directory import with --separate flag failed, retrying standard import..."
                    if ! dockExec "$container_id" "n8n import:credentials --input=$container_import_credentials" "$is_dry_run"; then
                        log ERROR "Failed to import credentials"
                        import_status="failed"
                    else
                        log SUCCESS "Credentials imported successfully"
                    fi
                else
                    log SUCCESS "Credentials imported successfully"
                fi
            else
                if ! dockExec "$container_id" "n8n import:credentials --input=$container_import_credentials" "$is_dry_run"; then
                    # Try with --separate flag on failure
                    log WARN "Standard import failed, trying with --separate flag..."
                    if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_import_credentials" "$is_dry_run"; then
                        log ERROR "Failed to import credentials"
                        import_status="failed"
                    else
                        log SUCCESS "Credentials imported successfully with --separate flag"
                    fi
                else
                    log SUCCESS "Credentials imported successfully"
                fi
            fi
        fi
    fi
    
    if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && [ "$import_status" != "failed" ] && [[ "$apply_folder_structure" == "true" ]]; then
        local folder_source_dir="$resolved_structured_dir"
        if [[ -z "$folder_source_dir" ]]; then
            folder_source_dir="$structured_workflows_dir"
            if [[ -n "$github_path" ]]; then
                folder_source_dir="$(resolve_github_storage_root "$folder_source_dir")"
            fi
        fi

        if [[ -z "$folder_source_dir" || ! -d "$folder_source_dir" ]]; then
            if [[ "$is_dry_run" == "true" ]]; then
                log DRYRUN "Would apply folder structure from directory, but source is unavailable (${folder_source_dir:-<empty>})."
            else
                log WARN "Workflow directory unavailable for folder restoration; skipping folder assignment."
            fi
        else
            if ! apply_folder_structure_from_directory "$folder_source_dir" "$container_id" "$is_dry_run" "" "$staged_manifest_file" "$stage_target_folder" true; then
                log WARN "Folder structure restoration encountered issues; workflows may require manual reorganization."
            fi
        fi
    fi

    # Clean up manifest and snapshot files
    if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
        local final_manifest_debug_path="${PULL_MANIFEST_DEBUG_PATH:-${RESTORE_MANIFEST_DEBUG_PATH:-}}"
        persist_manifest_debug_copy "$staged_manifest_file" "$final_manifest_debug_path" "pull manifest"
        cleanup_temp_path "$staged_manifest_file"
    fi
    if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" ]]; then
        cleanup_temp_path "$existing_workflow_snapshot"
    fi
    if [[ -n "$existing_workflow_mapping" && -f "$existing_workflow_mapping" ]]; then
        cleanup_temp_path "$existing_workflow_mapping"
    fi

    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log DEBUG "Cleaning up temporary files in container..."
        dockExecAsRoot "$container_id" "rm -rf $container_import_workflows $container_import_credentials 2>/dev/null || true" false >/dev/null 2>&1
    fi
    
    # Clean up downloaded repository
    if [[ -n "$download_dir" ]]; then
        cleanup_download_dir
    fi

    # DO NOT clean up session yet - needed for folder structure sync and summary queries
    
    # Handle pull result
    if [ "$import_status" = "failed" ]; then
        log WARN "Pull partially completed with some errors. Check logs for details."
        return 1
    fi
    
    # ============================================================================
    # RESTORE SUMMARY - Collect all metrics and display in comprehensive format
    # ============================================================================
    
    
    # Collect workflow metrics from exported environment variables (no queries needed)
    local post_import_workflow_count=${RESTORE_POST_IMPORT_COUNT:-0}
    local created_count=${RESTORE_WORKFLOWS_CREATED:-0}
    local updated_count=${RESTORE_WORKFLOWS_UPDATED:-0}
    local staged_count=${RESTORE_WORKFLOWS_TOTAL:-0}
    local had_workflow_activity=false
    
    # Determine if workflow activity occurred
    if [[ $staged_count -gt 0 ]] || [[ $created_count -gt 0 ]] || [[ $updated_count -gt 0 ]]; then
        had_workflow_activity=true
    fi
    
    # Collect folder structure metrics from exported environment variables
    local projects_created=${RESTORE_PROJECTS_CREATED:-0}
    local folders_created=${RESTORE_FOLDERS_CREATED:-0}
    local folders_moved=${RESTORE_FOLDERS_MOVED:-0}
    local workflows_repositioned=${RESTORE_WORKFLOWS_REASSIGNED:-0}
    local folder_sync_ran=${RESTORE_FOLDER_SYNC_RAN:-false}
    
    # Display summary table
    if [[ "$workflows_mode" != "0" || "$credentials_mode" != "0" ]]; then
        log HEADER "Restore Results"
        
        if [[ "$workflows_mode" != "0" ]]; then
            log INFO "Workflows:"
            if [[ $had_workflow_activity == true ]]; then
                log INFO "  • Workflows created:     $created_count"
                log INFO "  • Workflows updated:     $updated_count"
                log INFO "  • Total in instance:     $post_import_workflow_count"
            else
                log INFO "  • No changes (already up to date)"
                log INFO "  • Total in instance:     $post_import_workflow_count"
            fi
            
            if [[ "$folder_sync_ran" == "true" ]]; then
                echo ""
                log INFO "Folder Organization:"
                if [[ $projects_created -gt 0 || $folders_created -gt 0 || $folders_moved -gt 0 || $workflows_repositioned -gt 0 ]]; then
                    log INFO "  • Projects created:      $projects_created"
                    log INFO "  • Folders created:       $folders_created"
                    log INFO "  • Folders repositioned:  $folders_moved"
                    log INFO "  • Workflows repositioned: $workflows_repositioned"
                else
                    log INFO "  • All workflows already in target folders"
                fi
            fi
        fi
        
        if [[ "$credentials_mode" != "0" ]]; then
            echo ""
            log INFO "Credentials:"
            log INFO "  • Imported successfully"
        fi
    fi
    
    # Final status message
    if [[ $had_workflow_activity == true ]] || [[ $workflows_repositioned -gt 0 ]] || [[ "$credentials_mode" != "0" ]]; then
        :  # no-op: success message handled on return
    else
        log INFO "Pull completed with no changes (all content already up to date)."
    fi
    
    # NOW clean up n8n API session AFTER all operations complete
    if [[ "$keep_api_session_alive" == "true" && -n "${N8N_API_AUTH_MODE:-}" ]]; then
        finalize_n8n_api_auth
        keep_api_session_alive="false"
    fi
    
    # Clean up session cookie file explicitly (prevents EXIT trap message)
    cleanup_n8n_session "auto"

    return 0
}

validate_credentials_payload() {
    local payload_path="$1"

    if [[ -z "$payload_path" ]]; then
        log ERROR "Credentials payload path not provided"
        return 1
    fi

    if [[ -d "$payload_path" ]]; then
        local -a _credential_files=()
        mapfile -t _credential_files < <(find "$payload_path" -maxdepth 1 -type f -name '*.json' -print | sort)
        if ((${#_credential_files[@]} == 0)); then
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Credential directory '$payload_path' contains no JSON files; treating as empty set"
            fi
            return 0
        fi

        local file
        for file in "${_credential_files[@]}"; do
            if ! jq empty "$file" >/dev/null 2>&1; then
                log ERROR "Credential file '$file' is not valid JSON"
                return 1
            fi
            if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
                log WARN "Credential file '$file' is not a JSON object; import may fail"
            fi
        done
        return 0
    fi

    if [[ -f "$payload_path" ]]; then
        if ! jq empty "$payload_path" >/dev/null 2>&1; then
            log ERROR "Credential payload is not valid JSON: $payload_path"
            return 1
        fi
        if ! jq -e 'type == "array"' "$payload_path" >/dev/null 2>&1; then
            log WARN "Credential payload '$payload_path' is not a JSON array; import may fail"
        fi
        return 0
    fi

    log ERROR "Credentials payload not found: ${payload_path:-<empty>}"
    return 1
}
