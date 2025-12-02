#!/usr/bin/env bash
# =========================================================
# lib/utils/interactive.sh - Interactive UI functions for n8n-git
# =========================================================
# All interactive user interface functions: selection menus,
# configuration prompts, and user interaction handling

# Source common utilities
# shellcheck disable=SC1091  # common utilities resolved relative to this module
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

show_config_summary() {
    log INFO "Current configuration:"
    local value_color="$NORMAL"
    local accent_color="$DIM"
    
    # Backup configuration - use numeric system if available
    local workflows_desc="Not set"
    local credentials_desc="Not set"
    local environment_desc="Not set"
    local folder_desc=""
    
    # Determine workflows description from numeric value
    if [[ -n "${workflows:-}" ]]; then
        case "$workflows" in
            0) workflows_desc="Disabled" ;;
            1) workflows_desc="Local" ;;
            2) 
                workflows_desc="GitHub"
                if [[ "${folder_structure_enabled:-false}" == "true" ]] || [[ "$folder_structure" == "true" ]]; then
                    folder_desc="Enabled"
                else
                    folder_desc="Disabled"
                fi
                ;;
        esac
    fi
    
    # Determine credentials description from numeric value  
    if [[ -n "${credentials:-}" ]]; then
        case "$credentials" in
            0) credentials_desc="Disabled" ;;
            1) credentials_desc="Local" ;;
            2) credentials_desc="GitHub" ;;
        esac
    fi

    if [[ -n "${environment:-}" ]]; then
        case "$environment" in
            0) environment_desc="Disabled" ;;
            1) environment_desc="Local" ;;
            2) environment_desc="GitHub" ;;
        esac
    fi
    
    local folder_display=""
    if [[ -n "$folder_desc" ]]; then
        folder_display=" ${accent_color}(Folder structure: ${folder_desc})${NC}"
    fi

    log INFO "  Workflows: ${value_color}${workflows_desc}${NC}${folder_display}"
    log INFO "  Credentials: ${value_color}${credentials_desc}${NC}"
    log INFO "  Environment: ${value_color}${environment_desc}${NC}"

    local project_label="${project_name:-$PERSONAL_PROJECT_TOKEN}"
    local project_effective
    project_effective="$(effective_project_name "$project_label")"
    if is_personal_project_token "$project_label" && [[ "$project_effective" != "$project_label" ]]; then
        log INFO "  Project: ${value_color}${project_label}${NC} ${accent_color}(resolved: ${project_effective})${NC}"
    else
        log INFO "  Project: ${value_color}${project_effective}${NC}"
    fi

    local effective_prefix
    effective_prefix="$(effective_repo_prefix)"
    if [[ -n "$effective_prefix" ]]; then
        log INFO "  GitHub path: ${value_color}${effective_prefix}${NC}"
    else
        log INFO "  GitHub path: ${accent_color}<repository root>${NC}"
    fi

    if [[ "${n8n_path_source:-default}" != "default" && "${n8n_path_source:-unset}" != "unset" ]]; then
        if [[ -n "$n8n_path" ]]; then
            log INFO "  n8n path: ${value_color}${n8n_path}${NC} ${accent_color}(source: ${n8n_path_source})${NC}"
        else
            log INFO "  n8n path: ${accent_color}<project root>${NC} ${accent_color}(source: ${n8n_path_source})${NC}"
        fi
    elif [[ -n "$github_path" && "${github_path_source:-default}" != "default" ]]; then
        : # explicit GitHub path already shown above
    elif [[ -z "$github_path" && -n "$n8n_path" ]]; then
        # maintain visibility of default path when explicitly set but treated as default
        log INFO "  n8n path: ${value_color}${n8n_path}${NC}"
    fi
    
    if [[ -n "$github_repo" ]]; then
        log INFO "  GitHub: ${value_color}$github_repo${NC} ${accent_color}(branch: ${github_branch:-main})${NC}"
        if [[ -n "$github_token" ]]; then
            local pat_preview="${github_token:0:15}*****"
            log INFO "  GitHub PAT: ${NORMAL}${pat_preview}${NC}"
        else
            log INFO "  GitHub PAT: ${DIM}<empty>${NC}"
        fi
    fi

    if [[ -n "${git_commit_name:-}" || -n "${git_commit_email:-}" ]]; then
        local display_name display_email
        display_name="${git_commit_name:-n8n-git push}"
        display_email="${git_commit_email:-push@n8n.local}"
        log INFO "  Git identity: ${value_color}${display_name}${NC} ${accent_color}<${display_email}>${NC}"
    fi
    
    if [[ -n "$n8n_api_key" ]]; then
        local api_preview="${n8n_api_key:0:8}xxxxxx"
        log INFO "  n8n API auth: ${NORMAL}${api_preview}${NC}"
    elif [[ -n "$n8n_session_credential" ]]; then
        log INFO "  n8n session credential: ${value_color}${n8n_session_credential}${NC}"
        log INFO "  n8n session auth: ${GREEN}configured${NC}"
    elif [[ -n "$n8n_email" || -n "$n8n_password" ]]; then
        log INFO "  n8n session login: ${value_color}direct email/password${NC}"
        log INFO "  n8n session auth: ${GREEN}configured${NC}"
    else
        log INFO "  n8n session auth: ${DIM}<empty>${NC}"
    fi

    # Check if local storage is needed (when workflows=1 or credentials=1)
    if [[ "${needs_local_path:-}" == "true" ]] || [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]]; then
        log INFO "  Local storage path: ${value_color}${local_backup_path}${NC}"
    fi
    echo
}

describe_config_sources() {
    local active="${ACTIVE_CONFIG_PATH:-<none>}"
    local project_status="missing"
    local user_status="missing"
    local custom_status=""

    [[ -f "$LOCAL_CONFIG_FILE" ]] && project_status="found"
    [[ -f "$USER_CONFIG_FILE" ]] && user_status="found"
    if [[ -n "${config_file:-}" ]]; then
        local expanded_custom
        expanded_custom="$(expand_config_path "$config_file")"
        if [[ -n "$expanded_custom" ]]; then
            if [[ -f "$expanded_custom" ]]; then
                custom_status="found"
            else
                custom_status="missing"
            fi
        fi
    fi

    log INFO "Configuration sources:"
    if [[ "$project_status" == "found" ]]; then
        log INFO "  Project config: ${NORMAL}$LOCAL_CONFIG_FILE${NC} (${GREEN}${project_status}${NC})"
    else
        log INFO "  Project config: ${DIM}$LOCAL_CONFIG_FILE${NC} (${DIM}${project_status}${NC})"
    fi
    if [[ "$user_status" == "found" ]]; then
        log INFO "  User config: ${NORMAL}$USER_CONFIG_FILE${NC} (${GREEN}${user_status}${NC})"
    else
        log INFO "  User config: ${DIM}$USER_CONFIG_FILE${NC} (${DIM}${user_status}${NC})"
    fi
    if [[ -n "${config_file:-}" ]]; then
        local expanded_custom
        expanded_custom="$(expand_config_path "$config_file")"
        if [[ "$custom_status" == "found" ]]; then
            log INFO "  --config: ${NORMAL}${expanded_custom:-$config_file}${NC} (${GREEN}${custom_status}${NC})"
        else
            log INFO "  --config: ${DIM}${expanded_custom:-$config_file}${NC} (${DIM}${custom_status:-unset}${NC})"
        fi
    fi
    if [[ "$active" != "<none>" ]]; then
        log INFO "  Active config: ${NORMAL}${active}${NC}"
    else
        log INFO "  Active config: ${DIM}<none loaded>${NC}"
    fi
    echo
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  push      Export workflows, credentials, and environment variables to local or Git storage.
  pull      Import workflows, credentials, and environment variables into n8n.
  reset     Replay Git history to restore, archive, or delete workflows by commit/tag/time.
  config    Launch the interactive configuration wizard.

GitHub Options:
  --repo <user/repo>      Git repository (e.g., 'myuser/n8n-backups').
  --token <pat>           GitHub Personal Access Token for remote operations.
  --branch <branch>       Git branch to use (default: 'main').
  --github-path <path>    Subdirectory within the repository (supports tokens: %DATE%, %PROJECT%, %PERSONAL_PROJECT%, %HOSTNAME%).

n8n Instance Options:
  --container <id|name>   Docker container ID or name (default: 'n8n').
  --n8n-url <url>         n8n base URL (required for folder structure sync).
  --n8n-api-key <key>     n8n API key (placeholder; folder API not yet available).
  --n8n-cred <name>       Basic Auth credential name in n8n for session authentication.
  --n8n-email <email>     Email for direct session authentication (not recommended).
  --n8n-password <pass>   Password for direct session authentication (not recommended).
  --n8n-path <path>       Path within n8n project (e.g., 'clients/acme').

Storage Mode Options:
  --workflows <mode>      Workflow handling: disable (0), local (1), remote (2).
  --credentials <mode>    Credential handling: disable (0), local (1), remote (2).
  --environment <mode>    Environment variable handling: disable (0), local (1), remote (2).
  --local-path <path>     Local storage directory (default: '~/n8n-backup').
  --decrypt <true|false>  Export credentials decrypted (default: false - keep encrypted!).

Folder Structure Options:
  --folder-structure      Sync n8n folder hierarchy to Git (requires session auth).

Pull-Specific Options:
  --preserve              Keep original workflow IDs during import (avoid duplicates).
  --no-overwrite          Force new workflow IDs during import (create duplicates).

Reset-Specific Options:
  --to <sha|tag>          Target commit, tag, or branch.
  --since <time>          Time window start (e.g., 'yesterday', '2025-11-01 09:00').
  --until <time>          Time window end (optional, defaults to now).
  --interactive           Launch interactive commit picker.
  --mode <soft|hard>      Reset mode: soft (archive) or hard (delete).
    --hard                  Shorthand for --mode hard (perform a hard delete during reset).
    --soft                  Shorthand for --mode soft (archive mode during reset).

General Options:
  --dry-run               Simulate without making changes.
  --defaults              Assume defaults for prompts (non-interactive mode).
  --verbose               Enable verbose logging.
  --log-file <path>       Append logs to file.
  --config <path>         Custom config file path.
  -h, --help              Show this help message.

Configuration Precedence:
  1. CLI arguments (highest priority)
  2. ./.config (project-specific)
  3. ~/.config/n8n-git/config (user-specific)
  4. Interactive prompts
  5. Built-in defaults

Examples:
  # Backup to GitHub (workflows to Git, credentials local)
  n8n-git push --repo me/backups --workflows 2 --credentials 1

  # Pull workflows from public repo into specific n8n path
  n8n-git pull --repo Zie619/n8n-workflows --github-path workflows/Gmail --n8n-path Examples/Gmail

  # Interactive time travel through Git history
  n8n-git reset --interactive --mode soft

For more help, see: https://github.com/tcoretech/n8n-git
EOF
}

select_container() {
    log HEADER "Selecting n8n container..."
    mapfile -t containers < <(docker ps --format "{{.ID}}\t{{.Names}}\t{{.Image}}" 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        log ERROR "No running Docker containers found."
        exit 1
    fi

    local n8n_options=()
    local other_options=()
    local all_ids=()
    local default_option_num=-1

    log INFO "${BOLD}Available running containers:${NC}"
    log INFO "${DIM}------------------------------------------------${NC}"
    log INFO "${BOLD}Num\tID (Short)\tName\tImage${NC}"
    log INFO "${DIM}------------------------------------------------${NC}"

    local i=1
    for container_info in "${containers[@]}"; do
        local id name image
        IFS=$'\t' read -r id name image <<< "$container_info"
        local short_id=${id:0:12}
        all_ids+=("$id")
    local display_name="$name"

        if [ -n "$default_container" ] && { [ "$id" = "$default_container" ] || [ "$name" = "$default_container" ]; }; then
            default_option_num=$i
            display_name="${display_name} ${YELLOW}(default)${NC}"
        fi

        local line
        if [[ "$image" == *"n8nio/n8n"* || "$name" == *"n8n"* ]]; then
            line=$(printf "%s%d)%s %s\t%s\t%s %s(n8n)%s" "$GREEN" "$i" "$NC" "$short_id" "$display_name" "$image" "$YELLOW" "$NC")
            n8n_options+=("$line")
        else
            line=$(printf "%d) %s\t%s\t%s" "$i" "$short_id" "$display_name" "$image")
            other_options+=("$line")
        fi
        i=$((i+1))
    done

    for option in "${n8n_options[@]}"; do echo -e "$option"; done
    for option in "${other_options[@]}"; do echo -e "$option"; done
    echo -e "${DIM}------------------------------------------------${NC}"

    local selection
    local prompt_text="Select container number"
    if [ "$default_option_num" -ne -1 ]; then
        prompt_text="$prompt_text [default: $default_option_num]"
    fi
    prompt_text+=": "

    while true; do
    printf '%s' "$prompt_text"
        read -r selection
        selection=${selection:-$default_option_num}

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#containers[@]} ]; then
            local selected_full_id="${all_ids[$((selection-1))]}"
            log SUCCESS "Selected container: $selected_full_id"
            # shellcheck disable=SC2034  # exported for caller consumption
            SELECTED_CONTAINER_ID="$selected_full_id"
            return
        elif [ -z "$selection" ] && [ "$default_option_num" -ne -1 ]; then
             local selected_full_id="${all_ids[$((default_option_num-1))]}"
             log SUCCESS "Selected container (default): $selected_full_id"
             # shellcheck disable=SC2034  # exported for caller consumption
             SELECTED_CONTAINER_ID="$selected_full_id"
             return
        else
            log ERROR "Invalid selection. Please enter a number between 1 and ${#containers[@]}."
        fi
    done
}

select_command() {
    log HEADER "Choose Command"

    echo "1) Push n8n data using current configuration"
    echo "2) Pull n8n data using current configuration"
    echo "3) Configure defaults (create/update config)"
    echo "4) Configure with prompts before running push/pull"
    echo "5) Quit"

    local choice
    while true; do
        printf "\nSelect an option (1-5): "
        read -r choice
        # shellcheck disable=SC2034  # exported selection consumed by caller
        case "$choice" in
            1) SELECTED_COMMAND="push"; return ;;
            2) SELECTED_COMMAND="pull"; return ;;
            3) SELECTED_COMMAND="config"; return ;;
            4) SELECTED_COMMAND="config-reprompt"; return ;;
            5) log INFO "Exiting..."; exit 0 ;;
            *) log ERROR "Invalid option. Please select 1, 2, 3, 4, or 5." ;;
        esac
    done
}

select_restore_type() {
    log HEADER "Choose Pull Components"

    local local_backup_dir="$HOME/n8n-backup"
    local local_workflows_file="$local_backup_dir/workflows.json"
    local credentials_folder="${credentials_folder_name:-.credentials}"
    local local_credentials_dir="$local_backup_dir/$credentials_folder"

    local workflows_default="${RESTORE_WORKFLOWS_MODE:-${restore_workflows_mode:-2}}"
    local credentials_default="${RESTORE_CREDENTIALS_MODE:-${restore_credentials_mode:-1}}"
    local folder_structure_default="${RESTORE_APPLY_FOLDER_STRUCTURE:-${restore_folder_structure_preference:-auto}}"
    local workflows_choice=""
    local credentials_choice=""

    while true; do
        echo "Workflows pull mode:"
        echo "0) Disabled - Skip pulling workflows"
        echo "1) Local Storage - Pull from local backup ($local_workflows_file)"
        echo "2) Remote Storage - Pull from Git repository"
        printf "\nSelect workflows pull mode (0-2) [%s]: " "$workflows_default"
        read -r workflows_choice
        workflows_choice=${workflows_choice:-$workflows_default}
        case "$workflows_choice" in
            0|1|2) : ;; 
            *) log ERROR "Invalid option. Please enter 0, 1, or 2."; continue ;;
        esac

        echo
        echo "Credentials pull mode:"
        echo "0) Disabled - Skip pulling credentials"
        echo "1) Local Secure Storage - Pull from local backup ($local_credentials_dir)"
        echo "2) Remote Storage - Pull from Git repository"
        printf "\nSelect credentials pull mode (0-2) [%s]: " "$credentials_default"
        read -r credentials_choice
        credentials_choice=${credentials_choice:-$credentials_default}
        case "$credentials_choice" in
            0|1|2) : ;;
            *) log ERROR "Invalid option. Please enter 0, 1, or 2."; echo; continue ;;
        esac

        if [[ "$workflows_choice" == "0" && "$credentials_choice" == "0" ]]; then
            log WARN "At least one component must be selected for pull."
            echo
            continue
        fi

        break
    done

    RESTORE_WORKFLOWS_MODE="$workflows_choice"
    RESTORE_CREDENTIALS_MODE="$credentials_choice"

    if [[ "$RESTORE_WORKFLOWS_MODE" != "0" && "$RESTORE_CREDENTIALS_MODE" != "0" ]]; then
        # shellcheck disable=SC2034  # surfaced to caller scripts
        SELECTED_RESTORE_TYPE="all"
    elif [[ "$RESTORE_WORKFLOWS_MODE" != "0" ]]; then
        # shellcheck disable=SC2034  # surfaced to caller scripts
        SELECTED_RESTORE_TYPE="workflows"
    else
        # shellcheck disable=SC2034  # surfaced to caller scripts
        SELECTED_RESTORE_TYPE="credentials"
    fi

    if [[ "$RESTORE_WORKFLOWS_MODE" == "2" ]]; then
        case "$folder_structure_default" in
            true) RESTORE_APPLY_FOLDER_STRUCTURE="true" ;;
            skip) RESTORE_APPLY_FOLDER_STRUCTURE="skip" ;;
            auto) RESTORE_APPLY_FOLDER_STRUCTURE="auto" ;;
            *) RESTORE_APPLY_FOLDER_STRUCTURE="auto" ;;
        esac
    else
        RESTORE_APPLY_FOLDER_STRUCTURE="skip"
    fi

    log INFO "Selected pull configuration: Workflows=($RESTORE_WORKFLOWS_MODE) $(format_storage_value "$RESTORE_WORKFLOWS_MODE"), Credentials=($RESTORE_CREDENTIALS_MODE) $(format_storage_value "$RESTORE_CREDENTIALS_MODE")"
}

select_credential_source() {
    local local_file="$1"
    local git_file="$2"
    local selected_source=""
    
    log HEADER "Multiple Credential Sources Found"
    log INFO "Both local and Git repository credentials are available."
    echo "1) Local Storage"
    echo "   📍 $local_file"
    echo "   🔒 Stored securely with root file permissions"
    echo "2) Git Repository"
    echo "   📍 $git_file"
    echo "   ⚠️  Ensure to maintain encryption for security - credentials stored in Git history"
    
    local choice
    while true; do
        printf "\nSelect credential source (1-2) [default: 1]: "
        read -r choice
        choice=${choice:-1}
        case "$choice" in
            1) selected_source="$local_file"; break ;;
            2) 
                log WARN "⚠️  You selected Git repository credentials (less secure)"
                printf "Are you sure? (yes/no) [no]: "
                local confirm
                read -r confirm
                if [[ "$confirm" == "yes" || "$confirm" == "y" ]]; then
                    selected_source="$git_file"
                    break
                fi
                ;;
            *) log ERROR "Invalid option. Please select 1 or 2." ;;
        esac
    done
    
    echo "$selected_source"
}

show_pull_plan() {
    local restore_scope="$1"
    local github_repo="$2"
    local branch="$3"
    local workflows_mode="${4:-${RESTORE_WORKFLOWS_MODE:-2}}"
    local credentials_mode="${5:-${RESTORE_CREDENTIALS_MODE:-1}}"

    log HEADER "📋 Pull Plan"
    if [[ -n "${restore_scope:-}" ]]; then
        log INFO "Scope: ${restore_scope}"
    fi
    if [[ -n "$github_repo" ]]; then
        log INFO "Repository: $github_repo (branch: $branch)"
    fi

    case "$workflows_mode" in
        0) log INFO "📄 Workflows: Will remain unchanged" ;;
        1) log INFO "📄 Workflows: Will be pulled from local backup (~/.n8n-backup/workflows.json)" ;;
        2) log INFO "📄 Workflows: Will be pulled from Git repository" ;;
    esac

    case "$credentials_mode" in
        0) log INFO "🔒 Credentials: Will remain unchanged" ;;
        1) log INFO "🔒 Credentials: Will be pulled from local secure storage (~/.n8n-backup/$credentials_folder/)" ;;
        2) log INFO "🔒 Credentials: Will be pulled from Git repository" ;;
    esac

    return 0
}

get_github_config() {
    local reconfigure_mode="${1:-false}"
    local local_token="$github_token"
    local local_repo="$github_repo"
    local local_branch="$github_branch"

    log HEADER "GitHub Configuration"

    # Re-ask for token if not set or in reconfigure mode
    if [[ -z "$local_token" || "$reconfigure_mode" == "true" ]]; then
        while true; do
            local prompt="Enter GitHub Personal Access Token (PAT)"
            if [[ -n "$github_token" && "$reconfigure_mode" == "true" ]]; then
                local masked
                masked="$(printf '%s' "$github_token" | sed -E 's/^(.{15}).*/\1xxxx/')"
                prompt="$prompt [${masked}]"
            fi
            prompt+=": "
            printf "%s" "$prompt"
            read -r -s local_token
            echo
            if [[ -z "$local_token" && -n "$github_token" ]]; then
                local_token="$github_token"
            fi
            if [ -z "$local_token" ]; then 
                log ERROR "GitHub token is required."
            else
                break  # Exit loop once we have a valid token
            fi
        done
    fi

    # Re-ask for repo if not set or in reconfigure mode
    while [[ -z "$local_repo" ]] || [[ "$reconfigure_mode" == "true" ]]; do
        local repo_prompt="Enter GitHub repository (format: username/repo)"
        if [[ -n "$github_repo" ]]; then
            repo_prompt="$repo_prompt [${github_repo}]"
        fi
        repo_prompt+=": "
        printf "%s" "$repo_prompt"
        local repo_input
        read -r repo_input
        if [[ -z "$repo_input" && -n "$github_repo" ]]; then
            repo_input="$github_repo"
        fi
        if [ -z "$repo_input" ] || ! echo "$repo_input" | grep -q "/"; then
            log ERROR "Invalid GitHub repository format. It should be 'username/repo'."
            local_repo=""
            if [[ -n "$github_repo" ]]; then
                local_repo="$github_repo"
            fi
            if [[ -z "$local_repo" ]]; then
                continue
            fi
        else
            local_repo="$repo_input"
        fi
        break  # Valid repo captured
    done

    # Re-ask for branch if not set or in reconfigure mode
    if [[ -z "$local_branch" ]] || [[ "$reconfigure_mode" == "true" ]]; then
         local branch_default="main"
         if [[ -n "$github_branch" ]]; then
             branch_default="$github_branch"
         elif [[ -n "$local_branch" ]]; then
             branch_default="$local_branch"
         fi
         printf "Enter Branch to use [%s]: " "$branch_default"
         read -r local_branch
         local_branch=${local_branch:-$branch_default}
    else
        log INFO "Using branch: $local_branch"
    fi

    github_token="$local_token"
    github_repo="$local_repo"
    github_branch="$local_branch"
}

prompt_default_container() {
    local current_default="${default_container:-${container:-}}"
    printf "Default container name or ID [%s]: " "${current_default:-<none>}"
    local container_input
    read -r container_input
    container_input=${container_input:-$current_default}
    if [[ -n "$container_input" && "$container_input" != "<none>" ]]; then
        default_container="$container_input"
    fi
}

prompt_project_scope() {
    local force_reprompt="${1:-false}"
    local project_default="${project_name:-$PERSONAL_PROJECT_TOKEN}"
    if [[ "$project_name_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi

    printf "Project to manage [%s]: " "$project_default"
    local project_input
    read -r project_input
    if [[ -n "$project_input" ]]; then
        set_project_from_path "$project_input"
        project_name_source="interactive"
    fi

    local current_path="${n8n_path:-}"
    if [[ -z "$current_path" ]]; then
        printf "n8n folder path within project (leave blank for project root): "
    else
        printf "n8n folder path within project [%s]: " "$current_path"
    fi
    local path_input
    read -r path_input
    if [[ -n "$path_input" ]]; then
        set_n8n_path "$path_input" "interactive"
    elif [[ "$force_reprompt" == "true" ]]; then
        set_n8n_path "$current_path" "interactive"
    fi
}

prompt_local_backup_settings() {
    local force_reprompt="${1:-false}"
    local has_local_storage=false
    if [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]] || [[ "$environment" == "1" ]]; then
        has_local_storage=true
    fi

    if [[ "$has_local_storage" == true ]] && { [[ "$local_backup_path_source" == "default" ]] || [[ "$force_reprompt" == "true" ]]; }; then
        printf "Local push directory [%s]: " "$local_backup_path"
        local backup_input
        read -r backup_input
        if [[ -n "$backup_input" ]]; then
            if [[ "$backup_input" =~ ^~ ]]; then
                backup_input="${backup_input/#\~/$HOME}"
            fi
            local_backup_path="$backup_input"
            local_backup_path_source="interactive"
        fi
    fi

}

prompt_credentials_encryption() {
    local force_reprompt="${1:-false}"
    if [[ "$credentials" == "0" ]]; then
        return
    fi
    if [[ "${assume_defaults:-false}" == "true" && "$force_reprompt" != "true" ]]; then
        return
    fi
    if [[ "$credentials_encrypted_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi

    local default_label="yes"
    if [[ "$credentials_encrypted" == "false" ]]; then
        default_label="no"
    fi
    printf "Maintain encryption of credentials (recommended)? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        credentials_encrypted=true
        credentials_encrypted_source="interactive"
        return
    fi

    local allow_plaintext=false
    if [[ "$credentials" == "2" ]]; then
        log WARN "Unencrypted credentials in Git history can expose secrets."
        printf "Continue exporting credentials unencrypted to Git? (yes/no) [no]: "
        local confirm
        read -r confirm
        confirm=${confirm:-no}
        if [[ "$confirm" =~ ^([Yy]es|[Yy])$ ]]; then
            allow_plaintext=true
        fi
    else
        allow_plaintext=true
        log INFO "Credentials will be written decrypted to local storage. Protect the files appropriately."
    fi

    if [[ "$allow_plaintext" == "true" ]]; then
        credentials_encrypted=false
    else
        credentials_encrypted=true
    fi
    credentials_encrypted_source="interactive"
}

prompt_folder_structure_settings() {
    local force_reprompt="${1:-false}"
    local skip_validation="${2:-false}"

    if [[ "$workflows" != "2" ]]; then
        folder_structure=false
        return
    fi

    if [[ "$folder_structure_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi

    local folder_default="no"
    if [[ "${folder_structure:-false}" == "true" ]]; then
        folder_default="yes"
    fi
    printf "Mirror n8n folder structure in Git? (yes/no) [%s]: " "$folder_default"
    local choice
    read -r choice
    choice=${choice:-no}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        folder_structure=true
    else
        folder_structure=false
    fi
    folder_structure_source="interactive"

    if [[ "$folder_structure" != "true" ]]; then
        return
    fi

    while [[ -z "$n8n_base_url" ]]; do
        printf "n8n base URL (e.g., http://localhost:5678): "
        read -r n8n_base_url
        if [[ -z "$n8n_base_url" ]]; then
            log ERROR "n8n base URL is required when folder structure is enabled."
        fi
    done

    printf "n8n API key (leave blank to use stored credential): "
    read -r -s n8n_api_key
    echo
    if [[ -z "$n8n_api_key" ]]; then
        local default_cred_name="${n8n_session_credential:-N8N REST BACKUP}"
        printf "n8n credential name for session auth [%s]: " "$default_cred_name"
        read -r n8n_session_credential
        n8n_session_credential=${n8n_session_credential:-$default_cred_name}
    else
        n8n_session_credential=""
    fi

    if [[ -z "$n8n_api_key" ]]; then
        if [[ -n "$n8n_email" ]]; then
            printf "Optional direct login email [%s] (leave blank to keep current): " "$n8n_email"
        else
            printf "Optional direct login email (leave blank to skip): "
        fi
        local direct_email
        read -r direct_email
        if [[ -n "$direct_email" ]]; then
            n8n_email="$direct_email"
            printf "Direct login password (input hidden): "
            read -r -s n8n_password
            echo
        elif [[ "$force_reprompt" == "true" ]]; then
            n8n_email=""
            n8n_password=""
        fi
    fi

    if [[ "$skip_validation" != "true" ]]; then
        log INFO "Validating n8n API access..."
        if ! validate_n8n_api_access "$n8n_base_url" "$n8n_api_key" "$n8n_email" "$n8n_password" "$container" "$n8n_session_credential"; then
            log ERROR "❌ n8n API validation failed!"
            log ERROR "Authentication failed with all available methods."
            log ERROR "Cannot proceed with folder structure creation."
            log INFO "💡 Please verify:"
            log INFO "   1. n8n instance is running and accessible"
            log INFO "   2. Credentials (API key or stored credential) are correct"
            log INFO "   3. No authentication barriers blocking access"
            exit 1
        else
            log SUCCESS "n8n API configuration validated successfully!"
            log INFO "Folder structure enabled with n8n API integration"
        fi
    else
        log INFO "Skipping n8n API validation (configuration wizard)."
    fi
}

prompt_storage_modes() {
    local force_reprompt="${1:-false}"
    if [[ "$force_reprompt" == "true" || "$workflows_source" == "default" ]]; then
        select_workflows_storage
        workflows_source="interactive"
    fi
    if [[ "$force_reprompt" == "true" || "$credentials_source" == "default" ]]; then
        select_credentials_storage "$force_reprompt"
        credentials_source="interactive"
    fi
    if [[ "$force_reprompt" == "true" || "$environment_source" == "default" ]]; then
        select_environment_storage
        environment_source="interactive"
    fi
}

prompt_dry_run_choice() {
    local force_reprompt="${1:-false}"
    if [[ "$dry_run_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi
    local default_label="no"
    if [[ "$dry_run" == "true" ]]; then
        default_label="yes"
    fi
    printf "Run in dry-run mode by default? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        dry_run=true
    else
        dry_run=false
    fi
    dry_run_source="interactive"
}

prompt_verbose_logging() {
    local default_label="no"
    if [[ "${verbose:-false}" == "true" ]]; then
        default_label="yes"
    fi
    printf "Enable verbose logging by default? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        verbose=true
    else
        verbose=false
    fi
}

prompt_log_file_path() {
    local current_path="${log_file:-}"
    if [[ -n "$current_path" ]]; then
        printf "Log file path [%s] (leave blank to disable): " "$current_path"
    else
        printf "Optional log file path (leave blank to skip): "
    fi
    local log_input
    read -r log_input
    log_input="$(expand_config_path "$log_input")"

    if [[ -z "$log_input" ]]; then
        if [[ -n "$current_path" ]]; then
            log INFO "Clearing configured log file path."
        fi
        log_file=""
    else
        log_file="$log_input"
    fi
}

prompt_assume_defaults_choice() {
    local default_label="no"
    if [[ "${assume_defaults:-false}" == "true" ]]; then
        default_label="yes"
    fi
    printf "Assume defaults for future prompts (--defaults)? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        assume_defaults=true
    else
        assume_defaults=false
    fi
    assume_defaults_source="interactive"
}

prompt_pull_defaults() {
    local preserve_label="no"
    if [[ "${restore_preserve_ids:-false}" == "true" ]]; then
        preserve_label="yes"
    fi

    printf "Preserve workflow IDs on pull/reset by default? (yes/no) [%s]: " "$preserve_label"
    local choice
    read -r choice
    choice=${choice:-$preserve_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        restore_preserve_ids=true
    else
        restore_preserve_ids=false
    fi
    restore_preserve_ids_source="interactive"

    local no_overwrite_label="no"
    if [[ "${restore_no_overwrite:-false}" == "true" ]]; then
        no_overwrite_label="yes"
    fi
    printf "Avoid overwriting existing workflows by default (--no-overwrite)? (yes/no) [%s]: " "$no_overwrite_label"
    local overwrite_choice
    read -r overwrite_choice
    overwrite_choice=${overwrite_choice:-$no_overwrite_label}
    if [[ "$overwrite_choice" =~ ^([Yy]es|[Yy])$ ]]; then
        restore_no_overwrite=true
        restore_preserve_ids=false
    else
        restore_no_overwrite=false
    fi
    restore_no_overwrite_source="interactive"
}

prompt_git_identity() {
    local name_default="${git_commit_name:-n8n-git push}"
    local email_default="${git_commit_email:-push@n8n.local}"

    printf "Git commit author name [%s]: " "$name_default"
    local name_input
    read -r name_input
    git_commit_name="${name_input:-$name_default}"

    printf "Git commit author email [%s]: " "$email_default"
    local email_input
    read -r email_input
    git_commit_email="${email_input:-$email_default}"
}

collect_push_preferences() {
    local force_reprompt="${1:-false}"
    local skip_validation="${2:-false}"

    prompt_project_scope "$force_reprompt"
    prompt_storage_modes "$force_reprompt"
    prompt_local_backup_settings "$force_reprompt"
    prompt_folder_structure_settings "$force_reprompt" "$skip_validation"
}

expand_config_path() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        printf '%s\n' ""
        return
    fi
    case "${raw,,}" in
        null|none|off|false)
            printf '%s\n' ""
            return
            ;;
    esac
    if [[ "$raw" == "/dev/null" ]]; then
        printf '%s\n' ""
        return
    fi
    if [[ "$raw" == ~* ]]; then
        printf '%s\n' "${raw/#\~/$HOME}"
    else
        printf '%s\n' "$raw"
    fi
}

escape_config_value() {
    local value="$1"
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_config_file() {
    local destination_path
    destination_path="$(expand_config_path "$1")"

    if [[ -z "$destination_path" ]]; then
        log ERROR "No configuration destination provided."
        return 1
    fi

    local target_dir
    target_dir="$(dirname "$destination_path")"

    if ! mkdir -p "$target_dir"; then
        log ERROR "Failed to create config directory: $target_dir"
        return 1
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local example_path="$script_dir/../../.config.example"
    local use_template="false"
    if [[ -f "$example_path" ]]; then
        use_template="true"
    fi

    local -a lines
    lines+=("# Generated by n8n-git configuration wizard on $(date -u +%Y-%m-%dT%H:%M:%SZ)")
    lines+=("# Location: $destination_path")
    lines+=("")

    local decrypt_value="false"
    if [[ "$credentials_encrypted" == "false" ]]; then
        decrypt_value="true"
    fi

    local branch_value="${github_branch:-main}"
    local assume_defaults_value
    assume_defaults_value="$(normalize_boolean_option "${assume_defaults:-false}")"
    local preserve_ids_value
    preserve_ids_value="$(normalize_boolean_option "${restore_preserve_ids:-false}")"
    local no_overwrite_value
    no_overwrite_value="$(normalize_boolean_option "${restore_no_overwrite:-false}")"
    local folder_structure_value
    folder_structure_value="$(normalize_boolean_option "${folder_structure:-false}")"
    local dry_run_value
    dry_run_value="$(normalize_boolean_option "${dry_run:-false}")"
    local verbose_value
    verbose_value="$(normalize_boolean_option "${verbose:-false}")"

    declare -A replacements=(
        [GITHUB_TOKEN]="${github_token:-}"
        [GITHUB_REPO]="${github_repo:-}"
        [GITHUB_BRANCH]="$branch_value"
        [GITHUB_PATH]="${github_path-}"
        [N8N_CONTAINER]="${default_container:-${container:-}}"
        [N8N_PROJECT]="${project_name:-$PERSONAL_PROJECT_TOKEN}"
        [N8N_PATH]="${n8n_path:-}"
        [WORKFLOWS]="${workflows:-1}"
        [CREDENTIALS]="${credentials:-1}"
        [ENVIRONMENT]="${environment:-0}"
        [LOCAL_BACKUP_PATH]="${local_backup_path:-$HOME/n8n-backup}"
        [DECRYPT_CREDENTIALS]="$decrypt_value"
        [FOLDER_STRUCTURE]="$folder_structure_value"
        [N8N_BASE_URL]="${n8n_base_url:-}"
        [N8N_API_KEY]="${n8n_api_key:-}"
        [N8N_LOGIN_CREDENTIAL_NAME]="${n8n_session_credential:-}"
        [N8N_EMAIL]="${n8n_email:-}"
        [N8N_PASSWORD]="${n8n_password:-}"
        [DRY_RUN]="$dry_run_value"
        [VERBOSE]="$verbose_value"
        [ASSUME_DEFAULTS]="$assume_defaults_value"
        [LOG_FILE]="${log_file:-}"
        [GIT_COMMIT_NAME]="${git_commit_name:-}"
        [GIT_COMMIT_EMAIL]="${git_commit_email:-}"
        [RESTORE_PRESERVE_ID]="$preserve_ids_value"
        [RESTORE_NO_OVERWRITE]="$no_overwrite_value"
    )

    declare -A allow_empty_values=(
        [GITHUB_PATH]=1
    )

    declare -A applied=()

    if [[ "$use_template" == "true" ]]; then
        while IFS= read -r template_line; do
            local replaced_line="$template_line"
            local key
            for key in "${!replacements[@]}"; do
                local value="${replacements[$key]}"
                local allow_empty="${allow_empty_values[$key]:-0}"
                if [[ -z "$value" && "$allow_empty" != "1" ]]; then
                    continue
                fi
                if [[ "$template_line" =~ ^[[:space:]]*#?[[:space:]]*$key= ]]; then
                    replaced_line="${key}=\"$(escape_config_value "$value")\""
                    applied["$key"]=1
                    break
                fi
            done
            lines+=("$replaced_line")
        done < "$example_path"
    else
        local key
        for key in "${!replacements[@]}"; do
            local value="${replacements[$key]}"
            local allow_empty="${allow_empty_values[$key]:-0}"
            if [[ -z "$value" && "$allow_empty" != "1" ]]; then
                continue
            fi
            lines+=("${key}=\"$(escape_config_value "$value")\"")
            applied["$key"]=1
        done
    fi

    local append_key
    for append_key in "${!replacements[@]}"; do
        local value="${replacements[$append_key]}"
        local allow_empty="${allow_empty_values[$append_key]:-0}"
        if [[ -z "$value" && "$allow_empty" != "1" ]]; then
            continue
        fi
        if [[ -z "${applied[$append_key]:-}" ]]; then
            lines+=("${append_key}=\"$(escape_config_value "$value")\"")
        fi
    done

    {
        for line in "${lines[@]}"; do
            printf '%s\n' "$line"
        done
    } > "$destination_path"

    if ! chmod 600 "$destination_path" 2>/dev/null; then
        log WARN "Could not set permissions on $destination_path. Please ensure it is protected manually."
    fi

    log SUCCESS "Configuration saved to $destination_path"
    return 0
}

# =========================================================
# Reset commit picker helpers (interactive reset verb)
# =========================================================

RESET_PICKER_LIMIT="${RESET_PICKER_LIMIT:-60}"
RESET_PICKER_GROUP_PAGE="${RESET_PICKER_GROUP_PAGE:-0}"
RESET_PICKER_GROUPS_PER_PAGE="${RESET_PICKER_GROUPS_PER_PAGE:-5}"
RESET_PICKER_DEFAULT_VIEW="${RESET_PICKER_DEFAULT_VIEW:-day}"
RESET_PICKER_BATCH_WINDOW_SECONDS="${RESET_PICKER_BATCH_WINDOW_SECONDS:-300}"
RESET_PICKER_INITIAL_LAYOUT="${RESET_PICKER_INITIAL_LAYOUT:-grouped}"
RESET_PICKER_FULL_REDRAW="${RESET_PICKER_FULL_REDRAW:-true}"
RESET_PICKER_LAST_TOTAL=0
RESET_PICKER_TOTAL_PAGES=1
RESET_PICKER_PAGE_MIN=0
RESET_PICKER_PAGE_MAX=0
RESET_PICKER_PAGE_VISIBLE_COUNT=0
RESET_PICKER_LIST_PAGE="${RESET_PICKER_LIST_PAGE:-0}"
RESET_PICKER_LIST_PAGE_SIZE="${RESET_PICKER_LIST_PAGE_SIZE:-30}"
RESET_PICKER_LIST_TOTAL_PAGES=1
RESET_PICKER_LIST_PAGE_MIN=0
RESET_PICKER_LIST_PAGE_MAX=0
RESET_PICKER_LIST_PAGE_VISIBLE_COUNT=0
declare -ga _RESET_PICKER_COMMITS=()
declare -ga _RESET_PICKER_RENDERED_INDICES=()
declare -ga _RESET_PICKER_GROUPS=()
declare -ga _RESET_PICKER_GROUP_DISPLAY_ORDER=()
declare -gA _RESET_PICKER_EXPANDED_GROUPS=()

_reset_picker_python_available() {
    command -v python3 >/dev/null 2>&1
}

_reset_picker_format_iso() {
    local iso="$1"
    if [[ -z "$iso" ]]; then
        echo ""
        return 0
    fi
    if _reset_picker_python_available; then
        python3 - "$iso" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime
iso = sys.argv[1].replace('Z', '+00:00')
try:
    dt = datetime.fromisoformat(iso)
    print(dt.strftime('%Y-%m-%d (%a)'))
except Exception:
    pass
PY
        return 0
    fi
    printf '%s\n' "${iso%%T*}"
}

_reset_picker_week_label() {
    local iso="$1"
    if [[ -z "$iso" ]]; then
        echo ""
        return 0
    fi
    if _reset_picker_python_available; then
        python3 - "$iso" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timedelta
iso = sys.argv[1].replace('Z', '+00:00')
try:
    dt = datetime.fromisoformat(iso)
except Exception:
    print("")
    raise SystemExit
year, week, _ = dt.isocalendar()
start = dt - timedelta(days=dt.weekday())
end = start + timedelta(days=6)
label = f"{year}-W{week:02d} ({start.strftime('%b %d')} – {end.strftime('%b %d')})"
print(label)
PY
        return 0
    fi
    printf '%s\n' "${iso%%T*}"
}

_reset_picker_iso_to_epoch() {
    local iso="$1"
    if [[ -z "$iso" ]]; then
        echo "0"
        return 0
    fi
    if _reset_picker_python_available; then
        python3 - "$iso" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timezone
raw = sys.argv[1].replace('Z', '+00:00')
try:
    dt = datetime.fromisoformat(raw)
    print(int(dt.timestamp()))
except Exception:
    print(0)
PY
        return 0
    fi
    date -d "$iso" +%s 2>/dev/null || echo "0"
}

_reset_picker_format_decorations() {
    local refs="$1"
    local decorations=""
    refs="${refs//\(/}"
    refs="${refs//\)/}"
    IFS=',' read -r -a parts <<<"$refs"
    for ref in "${parts[@]}"; do
        ref="${ref#"${ref%%[![:space:]]*}"}"
        ref="${ref%"${ref##*[![:space:]]}"}"
        [[ -z "$ref" ]] && continue
        case "$ref" in
            tag:*)
                decorations+=" ${YELLOW}[tag:${ref#tag: }]${NC}"
                ;;
            HEAD*)
                decorations+=" ${GREEN}[${ref}]${NC}"
                ;;
            origin/*|*/\*)
                decorations+=" ${DIM}[${ref}]${NC}"
                ;;
        esac
    done
    printf '%s' "$decorations"
}

_reset_picker_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

_reset_picker_clean_descriptor() {
    local descriptor="$1"
    descriptor="${descriptor%.json}"
    descriptor="${descriptor%.zip}"
    descriptor="$(_reset_picker_trim "$descriptor")"
    if [[ "$descriptor" == *".credentials/"* ]]; then
        descriptor="${descriptor##*.credentials/}"
    fi
    descriptor="$(_reset_picker_trim "$descriptor")"
    printf '%s' "$descriptor"
}

_reset_picker_strip_brackets() {
    local text="$1"
    if [[ -z "$text" ]]; then
        printf ''
        return 0
    fi
    text="$(printf '%s' "$text" | sed 's/\[[^][]*\]//g')"
    text="$(_reset_picker_trim "$text")"
    printf '%s' "$text"
}

_reset_picker_strip_ansi() {
    local text="$1"
    if [[ -z "$text" ]]; then
        printf ''
        return 0
    fi
    text="$(printf '%s' "$text" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
    text="$(_reset_picker_trim "$text")"
    printf '%s' "$text"
}

_reset_picker_format_sample_text() {
    local sample_str="$1"
    local overflow="${2:-0}"
    if [[ -z "$sample_str" && overflow -le 0 ]]; then
        echo ""
        return 0
    fi

    local -a names=()
    if [[ -n "$sample_str" ]]; then
        IFS='|' read -r -a names <<<"$sample_str"
        local idx
        for idx in "${!names[@]}"; do
            names[idx]=$(_reset_picker_strip_brackets "${names[idx]}")
        done
    fi

    if ((${#names[@]} == 0)); then
        if (( overflow > 0 )); then
            printf ' (and %d more)' "$overflow"
        else
            printf ''
        fi
        return 0
    fi

    if ((${#names[@]} == 1 && overflow == 0)); then
        printf ' (%s)' "${names[0]}"
        return 0
    fi

    if ((${#names[@]} == 1)); then
        printf ' (%s, and %d more)' "${names[0]}" "$overflow"
        return 0
    fi

    if ((${#names[@]} >= 2)); then
        local extra=""
        if (( overflow > 0 )); then
            extra=", and ${overflow} more"
        fi
        printf ' (%s, %s%s)' "${names[0]}" "${names[1]}" "$extra"
        return 0
    fi
}

_reset_picker_relative_label() {
    local epoch="$1"
    if [[ -z "$epoch" || "$epoch" == "0" ]]; then
        echo ""
        return 0
    fi
    local now
    now=$(date +%s)
    local diff=$(( now - epoch ))
    local day=$(( diff / 86400 ))
    if (( diff < 0 )); then
        diff=$(( -diff ))
        day=$(( diff / 86400 ))
        if (( day <= 1 )); then
            echo "in ${day}d"
            return 0
        fi
    fi
    if (( diff < 86400 )); then
        echo "today"
    elif (( diff < 172800 )); then
        echo "yesterday"
    elif (( diff < 604800 )); then
        echo "${day}d ago"
    elif (( diff < 2419200 )); then
        local weeks=$(( day / 7 ))
        echo "${weeks}w ago"
    else
        local months=$(( day / 30 ))
        echo "${months}mo ago"
    fi
}

_reset_picker_time_badge() {
    local iso="$1"
    local epoch="$2"
    local time_part="${iso:11:5}"
    local rel
    rel="$(_reset_picker_relative_label "$epoch")"
    if [[ -n "$rel" ]]; then
        printf '[%s · %s]' "$time_part" "$rel"
    else
        printf '[%s]' "$time_part"
    fi
}

_reset_picker_parse_subject() {
    local subject="$1"
    local action=""
    local entity_hint=""
    local timestamp=""
    local descriptor="$subject"
    local remainder="$subject"

    if [[ "$remainder" =~ ^[[:space:]]*\[([^\]]+)\][[:space:]]*(.*)$ ]]; then
        action="${BASH_REMATCH[1]}"
        remainder="${BASH_REMATCH[2]}"
    fi

    if [[ "$remainder" =~ ^[[:space:]]*\[([^\]]+)\][[:space:]]*(.*)$ ]]; then
        entity_hint="${BASH_REMATCH[1]}"
        remainder="${BASH_REMATCH[2]}"
    fi

    if [[ "$remainder" =~ ^[[:space:]]*\(([^\)]+)\)[[:space:]]*-[[:space:]]*(.*)$ ]]; then
        timestamp="${BASH_REMATCH[1]}"
        remainder="${BASH_REMATCH[2]}"
    fi

    descriptor="$(_reset_picker_trim "$remainder")"
    descriptor="$(_reset_picker_clean_descriptor "$descriptor")"
    if [[ -z "$descriptor" ]]; then
        descriptor="$subject"
    fi

    local entity_type
    entity_type="$(_reset_picker_infer_entity_type "$descriptor" "$entity_hint")"

    printf '%s|%s|%s|%s\n' "$action" "$timestamp" "$descriptor" "$entity_type"
}

_reset_picker_action_key() {
    local raw="$1"
    raw="${raw,,}"
    case "$raw" in
        new* ) printf 'new' ;;
        add* ) printf 'new' ;;
        update* ) printf 'updated' ;;
        change* ) printf 'updated' ;;
        delete* ) printf 'deleted' ;;
        remove* ) printf 'deleted' ;;
        *) printf 'other' ;;
    esac
}

_reset_picker_action_color() {
    local key="$1"
    case "$key" in
        new) printf '%s' "$GREEN" ;;
        updated) printf '%s' "$BLUE" ;;
        deleted) printf '%s' "$RED" ;;
        *) printf '%s' "$NC" ;;
    esac
}

_reset_picker_collect_commits() {
    local limit="$RESET_PICKER_LIMIT"
    local log_output
    if ! log_output=$(git log --max-count="$limit" --date-order --pretty=format:'%H%x1f%h%x1f%cI%x1f%an%x1f%s%x1f%d%x1e' 2>/dev/null); then
        return 1
    fi

    _RESET_PICKER_COMMITS=()
    local records=()
    while IFS= read -r -d $'\x1e' record; do
        [[ -z "$record" ]] && continue
        record=${record//$'\n'/}
        records+=("$record")
    done <<<"$log_output"

    for record in "${records[@]}"; do
        [[ -z "$record" ]] && continue
        IFS=$'\x1f' read -r sha short iso author subject refs <<<"$record"
        [[ -z "$sha" ]] && continue
        local day_label week_label decorations
        day_label=$(_reset_picker_format_iso "$iso")
        week_label=$(_reset_picker_week_label "$iso")
        decorations=$(_reset_picker_format_decorations "$refs")
        local epoch
        epoch=$(_reset_picker_iso_to_epoch "$iso")
        _RESET_PICKER_COMMITS+=("$sha|$short|$iso|$author|$subject|$decorations|$day_label|$week_label|$epoch")
    done

    ((${#_RESET_PICKER_COMMITS[@]} > 0)) || return 1

    _reset_picker_build_groups
    RESET_PICKER_GROUP_PAGE=0
    return 0
}

_reset_picker_build_groups() {
    _RESET_PICKER_GROUPS=()
    _RESET_PICKER_GROUP_DISPLAY_ORDER=()
    _RESET_PICKER_EXPANDED_GROUPS=()
    local threshold="$RESET_PICKER_BATCH_WINDOW_SECONDS"
    local current_group=""
    local prev_epoch=""

    for idx in "${!_RESET_PICKER_COMMITS[@]}"; do
        local entry="${_RESET_PICKER_COMMITS[$idx]}"
        IFS='|' read -r _ _ _ _ _ _ _ _ epoch <<<"$entry"
        if [[ -z "$current_group" ]]; then
            current_group="$idx"
            prev_epoch="$epoch"
            continue
        fi

        local delta=$(( prev_epoch - epoch ))
        if (( delta >= 0 && delta <= threshold )); then
            current_group+=",$idx"
        else
            _RESET_PICKER_GROUPS+=("$current_group")
            current_group="$idx"
        fi
        prev_epoch="$epoch"
    done

    if [[ -n "$current_group" ]]; then
        _RESET_PICKER_GROUPS+=("$current_group")
    fi
}

_reset_picker_matches_filter() {
    local entry="$1"
    local filter="$2"
    if [[ -z "$filter" ]]; then
        return 0
    fi
    local sha short iso author subject decorations day_label week_label epoch
    IFS='|' read -r sha short iso author subject decorations day_label week_label epoch <<<"$entry"
    local haystack="${sha,,} ${short,,} ${author,,} ${subject,,} ${iso,,} ${day_label,,} ${week_label,,}"
    local needle="${filter,,}"
    [[ "$haystack" == *"$needle"* ]]
}

_reset_picker_emit_json() {
    local entry="$1"
    local selection="$2"
    local filter_text="${3:-}"
    local view_label="${4:-}"
    IFS='|' read -r sha short iso author subject decorations day_label week_label _ <<<"$entry"
    local display="${short} ${subject}"
    local selection_value="$selection"
    if [[ -n "$filter_text" ]]; then
        selection_value+=" • filter:\"$filter_text\""
    fi
    local json_output=""
    json_output=$(jq -n --compact-output \
        --arg sha "$sha" \
        --arg short "$short" \
        --arg subject "$subject" \
        --arg date "$iso" \
        --arg author "$author" \
        --arg display "$display" \
        --arg selection "$selection_value" \
        --arg decorations "$decorations" \
        --arg view "$view_label" \
        '{sha:$sha, short:$short, subject:$subject, date:$date, author:$author, display:$display, selection:$selection, decorations:$decorations, view:$view}')

    local result_path="${RESET_PICKER_RESULT_PATH:-}"
    if [[ -n "$result_path" ]]; then
        printf '%s\n' "$json_output" >>"$result_path"
    else
        printf '%s\n' "$json_output"
    fi
}

_reset_picker_render_list() {
    local view="$1"
    local filter="$2"
    local page=${RESET_PICKER_LIST_PAGE:-0}
    (( page < 0 )) && page=0
    _RESET_PICKER_RENDERED_INDICES=()

    if [[ -n "$filter" ]]; then
        log INFO "${DIM}Filter:${NC} \"$filter\""
    fi

    local -a matching_indices=()
    local idx
    for idx in "${!_RESET_PICKER_COMMITS[@]}"; do
        local entry="${_RESET_PICKER_COMMITS[$idx]}"
        if _reset_picker_matches_filter "$entry" "$filter"; then
            matching_indices+=("$idx")
        fi
    done

    local total_matches=${#matching_indices[@]}
    if (( total_matches == 0 )); then
        log WARN "No commits match the current filter."
        RESET_PICKER_LAST_TOTAL=0
        RESET_PICKER_LIST_TOTAL_PAGES=1
        RESET_PICKER_LIST_PAGE_MIN=0
        RESET_PICKER_LIST_PAGE_MAX=0
        RESET_PICKER_LIST_PAGE_VISIBLE_COUNT=0
        return 0
    fi

    local per_page=${RESET_PICKER_LIST_PAGE_SIZE:-30}
    (( per_page <= 0 )) && per_page=30

    local total_pages=$(((total_matches + per_page - 1) / per_page))
    (( total_pages <= 0 )) && total_pages=1
    RESET_PICKER_LIST_TOTAL_PAGES=$total_pages

    if (( page >= total_pages )); then
        page=$(( total_pages - 1 ))
        RESET_PICKER_LIST_PAGE=$page
    fi

    local start_index=$(( page * per_page ))
    local end_index=$(( start_index + per_page ))
    if (( end_index > total_matches )); then
        end_index=$total_matches
    fi

    local display_start=$(( start_index + 1 ))
    local display_end=$end_index
    if (( total_matches == 0 )); then
        display_start=0
        display_end=0
    elif (( display_end < display_start )); then
        display_end=$display_start
    fi

    RESET_PICKER_LIST_PAGE_MIN=$display_start
    # shellcheck disable=SC2034  # shared with navigation prompts
    RESET_PICKER_LIST_PAGE_MAX=$display_end
    RESET_PICKER_LIST_PAGE_VISIBLE_COUNT=$(( end_index - start_index ))

    printf "%sShowing commits %d-%d of %d (page %d/%d)%s\n\n" \
        "$DIM" \
        "$display_start" \
        "$display_end" \
        "$total_matches" \
        "$(( page + 1 ))" \
        "$total_pages" \
        "$NC"

    local count=0
    local last_group=""
    local printed=0
    for idx in "${matching_indices[@]}"; do
        _RESET_PICKER_RENDERED_INDICES+=("$idx")
        count=$((count + 1))
        if (( count < display_start || count > display_end )); then
            continue
        fi
        local entry="${_RESET_PICKER_COMMITS[$idx]}"
        local sha short iso author subject decorations day_label week_label epoch
        IFS='|' read -r sha short iso author subject decorations day_label week_label epoch <<<"$entry"
        local group_label heading_prefix
        if [[ "$view" == "week" ]]; then
            group_label="$week_label"
            heading_prefix="Week"
        else
            group_label="$day_label"
            heading_prefix="Day"
        fi
        if [[ -n "$group_label" && "$group_label" != "$last_group" ]]; then
            log HEADER "${heading_prefix}: $group_label"
            last_group="$group_label"
        fi
        local time_label
        time_label="$(_reset_picker_time_badge "$iso" "$epoch")"
        local parsed_subject
        parsed_subject=$(_reset_picker_parse_subject "$subject")
        IFS='|' read -r action_label _ descriptor entity_type <<<"$parsed_subject"
        local action_key
        action_key=$(_reset_picker_action_key "$action_label")
        local action_block
        action_block="$(_reset_picker_action_color "$action_key")[${action_label:-Commit}]${NC}"
        local type_tag=""
        case "$entity_type" in
            credential) type_tag="${MAGENTA:-$YELLOW}[CRED]${NC}" ;;
            workflow) type_tag="${BLUE}[WF]${NC}" ;;
            system) type_tag="${DIM}[SYS]${NC}" ;;
            *) type_tag="${DIM}[--]${NC}" ;;
        esac
        local descriptor_text
        descriptor_text="$(_reset_picker_clean_descriptor "$descriptor")"
        if [[ -z "$descriptor_text" ]]; then
            descriptor_text="$subject"
        fi
        local short_block="${BLUE}${short}${NC}"
        if [[ -n "$decorations" ]]; then
            short_block+=" $decorations"
        fi
        printf "  %2d) %s %s %s %s %s %s\n" \
            "$count" \
            "$short_block" \
            "$action_block" \
            "$type_tag" \
            "$descriptor_text" \
            "${DIM}— $author${NC}" \
            "${DIM}${time_label}${NC}"
        printed=$((printed + 1))
    done

    if (( printed == 0 )); then
        log WARN "No commits match the current page range."
    fi

    RESET_PICKER_LAST_TOTAL=$total_matches
}

_reset_picker_group_preview() {
    local group_idx="$1"
    local __header_var="$2"
    local __details_var="$3"
    local group_entry="${_RESET_PICKER_GROUPS[$group_idx]:-}"

    if [[ -z "$group_entry" ]]; then
        printf -v "$__header_var" ''
        printf -v "$__details_var" ''
        return 0
    fi

    IFS=',' read -r -a members <<<"$group_entry"
    local commit_count="${#members[@]}"
    local primary="${_RESET_PICKER_COMMITS[${members[0]}]}"
    local primary_short primary_iso primary_decorations day_label week_label primary_epoch
    IFS='|' read -r _ primary_short primary_iso _ _ primary_decorations day_label week_label primary_epoch <<<"$primary"
    local oldest="${_RESET_PICKER_COMMITS[${members[$((commit_count - 1))]}]}"
    local oldest_iso
    IFS='|' read -r _ _ oldest_iso _ _ _ _ _ _ <<<"$oldest"

    local primary_day="${day_label:-${primary_iso%%T*}}"
    local time_end="${primary_iso:11:5}"
    local time_start="${oldest_iso:11:5}"
    local time_label="$time_end"
    if [[ -n "$time_start" && "$time_start" != "$time_end" ]]; then
        time_label="${time_start}-${time_end}"
    fi

    declare -A type_action_counts=()
    declare -A type_action_samples=()
    declare -A type_action_overflow=()
    local sample_limit=2

    local member
    for member in "${members[@]}"; do
        local entry="${_RESET_PICKER_COMMITS[$member]}"
        IFS='|' read -r _ short _ _ subject _ _ _ _ <<<"$entry"
        local parsed
        parsed=$(_reset_picker_parse_subject "$subject")
        IFS='|' read -r action_label _ descriptor entity_type <<<"$parsed"
        local clean_name
        clean_name=$(_reset_picker_clean_descriptor "$descriptor")
        clean_name=$(_reset_picker_strip_brackets "$clean_name")
        local action_key
        action_key=$(_reset_picker_action_key "$action_label")
        local key="${entity_type}|${action_key}"
        type_action_counts["$key"]=$(( ${type_action_counts["$key"]:-0} + 1 ))
        local existing_samples="${type_action_samples["$key"]:-}"
        local current_sample_count=0
        if [[ -n "$existing_samples" ]]; then
            IFS='|' read -r -a __tmp <<<"$existing_samples"
            current_sample_count="${#__tmp[@]}"
        fi
        if (( current_sample_count < sample_limit )); then
            if [[ -z "$existing_samples" ]]; then
                type_action_samples["$key"]="$clean_name"
            else
                type_action_samples["$key"]+="|$clean_name"
            fi
        else
            type_action_overflow["$key"]=$(( ${type_action_overflow["$key"]:-0} + 1 ))
        fi
    done

    local header_line
    local commit_plural=""
    [[ $commit_count -ne 1 ]] && commit_plural="s"

    local header_relative
    header_relative="$(_reset_picker_relative_label "$primary_epoch")"
    local header_time_label="$time_label"
    if [[ -n "$header_relative" ]]; then
        header_time_label+=" · $header_relative"
    fi

    printf -v header_line "• %s%s%s : %s %s (%d commit%s)" \
        "$BLUE" "$primary_short" "$NC" \
        "$primary_day" "$header_time_label" \
        "$commit_count" "$commit_plural"

    local -a detail_lines=()
    if [[ -n "$primary_decorations" ]]; then
        local refs_plain
        refs_plain=$(_reset_picker_strip_ansi "$primary_decorations")
        refs_plain=$(_reset_picker_trim "$refs_plain")
        [[ -n "$refs_plain" ]] && detail_lines+=("$refs_plain")
    fi

    local types=("workflow" "credential" "system")
    local actions=(new updated deleted other)
    local type_key action
    for type_key in "${types[@]}"; do
        local type_label
        case "$type_key" in
            workflow) type_label="Workflows" ;;
            credential) type_label="Credentials" ;;
            system) type_label="System changes" ;;
        esac

        for action in "${actions[@]}"; do
            local key="${type_key}|${action}"
            local count="${type_action_counts[$key]:-0}"
            (( count == 0 )) && continue
            local action_label=""
            case "$action" in
                new) action_label="New" ;;
                updated) action_label="Updated" ;;
                deleted) action_label="Deleted" ;;
                *) action_label="Changed" ;;
            esac
            local sample_text
            sample_text=$(_reset_picker_format_sample_text "${type_action_samples[$key]:-}" "${type_action_overflow[$key]:-0}")
            sample_text=$(_reset_picker_strip_brackets "$sample_text")
            if [[ -n "$sample_text" ]]; then
                sample_text=" $sample_text"
            fi
            local summary_line
            printf -v summary_line '%d %s %s%s' "$count" "$action_label" "$type_label" "$sample_text"
            summary_line=$(_reset_picker_strip_brackets "$summary_line")
            detail_lines+=("$summary_line")
        done
    done

    if ((${#detail_lines[@]} == 0)); then
        detail_lines+=("Mixed updates (legacy commit format)")
    fi

    local detail_buffer=""
    detail_buffer="$(IFS=$'\n'; echo "${detail_lines[*]}")"

    printf -v "$__header_var" '%s' "$header_line"
    printf -v "$__details_var" '%s' "$detail_buffer"
}

_reset_picker_auto_select() {
    local hint="$1"
    local view="$2"
    local filter="$3"
    local entry=""
    local label=""

    if [[ "$hint" =~ ^[0-9]+$ ]]; then
        local index=$((hint - 1))
        if (( index >= 0 && index < ${#_RESET_PICKER_COMMITS[@]} )); then
            entry="${_RESET_PICKER_COMMITS[$index]}"
            label="Auto-select #$hint"
        fi
    else
        local lower_hint="${hint,,}"
        for idx in "${!_RESET_PICKER_COMMITS[@]}"; do
            local sha short
            IFS='|' read -r sha short _ <<<"${_RESET_PICKER_COMMITS[$idx]}"
            if [[ "${sha,,}" == "$lower_hint"* || "${short,,}" == "$lower_hint"* ]]; then
                entry="${_RESET_PICKER_COMMITS[$idx]}"
                label="Auto-select ${short}"
                break
            fi
        done
    fi

    if [[ -z "$entry" ]]; then
        return 1
    fi

    _reset_picker_emit_json "$entry" "$label" "$filter" "$view"
    return 0
}

interactive_commit_picker() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log ERROR "Interactive picker requires a Git repository."
        return 2
    fi

    if ! _reset_picker_collect_commits; then
        log ERROR "Unable to collect commit history for the picker."
        return 2
    fi

    if ((${#_RESET_PICKER_COMMITS[@]} == 0)); then
        log ERROR "This repository has no commits to pick from."
        return 2
    fi

    local autopick="${RESET_INTERACTIVE_AUTOPICK:-}"
    local auto_action="${RESET_INTERACTIVE_AUTOPICK_ACTION:-}"
    local filter="${RESET_INTERACTIVE_FILTER:-}"
    local view="${RESET_PICKER_DEFAULT_VIEW}"
    local layout="${RESET_PICKER_INITIAL_LAYOUT,,}"
    if [[ "$layout" != "list" ]]; then
        layout="grouped"
    fi

    if [[ -n "$auto_action" && "${auto_action,,}" == "abort" ]]; then
        log WARN "Interactive picker cancelled via RESET_INTERACTIVE_AUTOPICK_ACTION."
        return 130
    fi

    if [[ -z "$autopick" && "${assume_defaults:-false}" == "true" ]]; then
        autopick="1"
    fi

    if [[ -n "$autopick" ]]; then
        if ! _reset_picker_auto_select "$autopick" "$view" "$filter"; then
            log ERROR "Automatic selection hint '$autopick' did not match any commits."
            return 2
        fi
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log ERROR "Interactive picker requires a TTY. Use RESET_INTERACTIVE_AUTOPICK to run non-interactively."
        return 2
    fi

    while true; do
        _reset_picker_clear_screen
        local total=0
        if [[ "$layout" == "grouped" ]]; then
            _reset_picker_render_grouped "$filter"
            total="$RESET_PICKER_LAST_TOTAL"
        else
            _reset_picker_render_list "$view" "$filter"
            total="$RESET_PICKER_LAST_TOTAL"
        fi

        if [[ "$layout" == "grouped" ]]; then
            local page_display=$((RESET_PICKER_GROUP_PAGE + 1))
            local total_pages=${RESET_PICKER_TOTAL_PAGES:-1}
            printf "%s---------------------------------------- page %d/%d ----------------------------------------%s\n" \
                "$DIM" "$page_display" "$total_pages" "$NC"
            printf "Restore to (# or #.#) • (e)xpand (#) • (f)ilter • (n)ext / (p)rev page • (l)ist view • (q)uit\n"
        else
            local list_page=$((RESET_PICKER_LIST_PAGE + 1))
            local list_pages=${RESET_PICKER_LIST_TOTAL_PAGES:-1}
            printf "%s---------------------------------------- page %d/%d ----------------------------------------%s\n" \
                "$DIM" "$list_page" "$list_pages" "$NC"
            printf "Restore to (#) • (f)ilter • (n)ext / (p)rev page • (g)roup view • (q)uit\n"
        fi

        printf "> "

        local response
        read -r response
        response="${response// /}"
        printf "\n"

        if [[ -z "$response" ]]; then
            if [[ "$layout" == "grouped" ]]; then
                local default_pick=${RESET_PICKER_PAGE_MIN:-1}
                if (( ${RESET_PICKER_PAGE_VISIBLE_COUNT:-0} <= 0 )); then
                    continue
                fi
                response="$default_pick"
            else
                local list_visible=${RESET_PICKER_LIST_PAGE_VISIBLE_COUNT:-0}
                if (( list_visible <= 0 )); then
                    if (( total == 0 )); then
                        continue
                    fi
                    response="1"
                else
                    response="${RESET_PICKER_LIST_PAGE_MIN:-1}"
                fi
            fi
        fi

        local lower_response="${response,,}"
        case "$lower_response" in
            q)
                return 130
                ;;
            f)
                printf "Filter text (empty clears): "
                read -r filter
                RESET_PICKER_GROUP_PAGE=0
                RESET_PICKER_LIST_PAGE=0
                continue
                ;;
            g)
                layout="grouped"
                RESET_PICKER_GROUP_PAGE=0
                continue
                ;;
            l)
                layout="list"
                RESET_PICKER_LIST_PAGE=0
                continue
                ;;
            n|next)
                if [[ "$layout" == "grouped" ]]; then
                    if (( RESET_PICKER_GROUP_PAGE < RESET_PICKER_TOTAL_PAGES - 1 )); then
                        RESET_PICKER_GROUP_PAGE=$((RESET_PICKER_GROUP_PAGE + 1))
                    else
                        log WARN "Already viewing the latest page."
                    fi
                elif [[ "$layout" == "list" ]]; then
                    if (( RESET_PICKER_LIST_PAGE < RESET_PICKER_LIST_TOTAL_PAGES - 1 )); then
                        RESET_PICKER_LIST_PAGE=$((RESET_PICKER_LIST_PAGE + 1))
                    else
                        log WARN "Already viewing the latest page."
                    fi
                else
                    log WARN "Paging is only available in grouped view."
                fi
                continue
                ;;
            p|prev)
                if [[ "$layout" == "grouped" ]]; then
                    if (( RESET_PICKER_GROUP_PAGE > 0 )); then
                        RESET_PICKER_GROUP_PAGE=$((RESET_PICKER_GROUP_PAGE - 1))
                    else
                        log WARN "Already at the earliest page."
                    fi
                elif [[ "$layout" == "list" ]]; then
                    if (( RESET_PICKER_LIST_PAGE > 0 )); then
                        RESET_PICKER_LIST_PAGE=$((RESET_PICKER_LIST_PAGE - 1))
                    else
                        log WARN "Already at the earliest page."
                    fi
                else
                    log WARN "Paging is only available in grouped view."
                fi
                continue
                ;;
            d)
                if [[ "$layout" == "list" ]]; then
                    view="day"
                    continue
                fi
                ;;
            w)
                if [[ "$layout" == "list" ]]; then
                    view="week"
                    continue
                fi
                ;;
            e|o)
                if [[ "$layout" == "grouped" ]]; then
                    printf "Enter batch number to toggle: "
                    local target
                    read -r target
                    response="e${target}"
                    lower_response="${response,,}"
                else
                    log WARN "Expand command only available in grouped view."
                    continue
                fi
                ;;
        esac

        if [[ "$layout" == "grouped" ]]; then
            if [[ "$lower_response" =~ ^[eoc][0-9]+$ ]]; then
                local ord="${lower_response:1}"
                if ! _reset_picker_toggle_group "$ord"; then
                    log WARN "Invalid batch index '$ord'."
                fi
                continue
            fi

            if [[ "$response" =~ ^[0-9]+\.[0-9]+$ ]]; then
                local group_ord="${response%%.*}"
                local commit_ord="${response##*.}"
                local commit_index
                if ! commit_index=$(_reset_picker_resolve_commit_index "$group_ord" "$commit_ord"); then
                    log WARN "Invalid batch/commit selection '$response'."
                    continue
                fi
                local selection_label="Batch ${group_ord} • commit ${commit_ord}"
                local select_status=0
                if _reset_picker_select_commit "$commit_index" "$selection_label" "$filter" "grouped"; then
                    return 0
                else
                    select_status=$?
                    if [[ $select_status -eq 2 ]]; then
                        continue
                    fi
                fi
                log WARN "Unable to select commit for '$response'."
                continue
            fi

            if [[ "$response" =~ ^[0-9]+$ ]]; then
                if (( total == 0 )); then
                    log WARN "No batches available to select."
                    continue
                fi
                local ord="$response"
                local group_index
                if ! group_index=$(_reset_picker_resolve_group_index "$ord"); then
                    log WARN "Batch selection '$ord' is out of range (1-$total)."
                    continue
                fi
                local primary_index
                primary_index=$(_reset_picker_group_primary_index "$group_index")
                local selection_label="Batch ${ord} • default"
                local select_status=0
                if _reset_picker_select_commit "$primary_index" "$selection_label" "$filter" "grouped"; then
                    return 0
                else
                    select_status=$?
                    if [[ $select_status -eq 2 ]]; then
                        continue
                    fi
                fi
                log WARN "Unable to select commit for batch '$ord'."
                continue
            fi

            log WARN "Unrecognised option '$response'. Use numbers, e#, or #.# format."
            continue
        fi

        if [[ "$response" =~ ^[0-9]+$ ]]; then
            if (( total == 0 )); then
                log WARN "No commits available to select."
                continue
            fi
            local selection="$response"
            if (( selection < 1 || selection > total )); then
                log WARN "Selection out of range. Enter a value between 1 and $total."
                continue
            fi
            local commit_index="${_RESET_PICKER_RENDERED_INDICES[$((selection - 1))]}"
            local entry="${_RESET_PICKER_COMMITS[$commit_index]}"
            local day_label week_label short
            IFS='|' read -r _ short _ _ _ _ day_label week_label _ <<<"$entry"
            local selection_label="$short"
            if [[ "$view" == "week" && -n "$week_label" ]]; then
                selection_label+=" • Week $week_label"
            elif [[ "$view" == "day" && -n "$day_label" ]]; then
                selection_label+=" • $day_label"
            fi
            local select_status=0
            if _reset_picker_select_commit "$commit_index" "$selection_label" "$filter" "$view"; then
                return 0
            else
                select_status=$?
                if [[ $select_status -eq 2 ]]; then
                    continue
                fi
            fi
            log WARN "Unable to select commit."
            continue
        fi

        log WARN "Unrecognised option '$response'."
    done
}

export -f interactive_commit_picker

select_config_destination() {
    local has_cli=false
    local cli_path=""
    if [[ -n "$config_file" ]]; then
        cli_path="$(expand_config_path "$config_file")"
        has_cli=true
    fi

    local default_option="1"
    if [[ "$has_cli" == true ]]; then
        default_option="3"
    fi

    local project_marker=""
    local user_marker=""
    local cli_marker=""

    if [[ -f "$LOCAL_CONFIG_FILE" ]]; then
        project_marker=" ${YELLOW}(will update)${NC}"
    else
        project_marker=" ${YELLOW}(will create)${NC} ${DIM}(missing)${NC}"
    fi
    if [[ -f "$USER_CONFIG_FILE" ]]; then
        user_marker=" ${YELLOW}(will update)${NC}"
    else
        user_marker=" ${YELLOW}(will create)${NC} ${DIM}(missing)${NC}"
    fi
    if [[ "$has_cli" == true ]]; then
        if [[ -f "$cli_path" ]]; then
            cli_marker=" ${YELLOW}(will update)${NC}"
        else
            cli_marker=" ${YELLOW}(will create)${NC} ${DIM}(missing)${NC}"
        fi
    fi
    if [[ -n "${ACTIVE_CONFIG_PATH:-}" ]]; then
        if [[ "$ACTIVE_CONFIG_PATH" == "$LOCAL_CONFIG_FILE" ]]; then project_marker+=" ${GREEN}(active)${NC}"; fi
        if [[ "$ACTIVE_CONFIG_PATH" == "$USER_CONFIG_FILE" ]]; then user_marker+=" ${GREEN}(active)${NC}"; fi
        if [[ "$ACTIVE_CONFIG_PATH" == "$cli_path" ]]; then cli_marker+=" ${GREEN}(active)${NC}"; fi
    fi

    while true; do
        log HEADER "Choose configuration destination"
        log INFO "1) Project config: ${NORMAL}$LOCAL_CONFIG_FILE${NC}${project_marker}"
        log INFO "2) User config: ${NORMAL}$USER_CONFIG_FILE${NC}${user_marker}"
        if [[ "$has_cli" == true ]]; then
            log INFO "3) --config path: ${NORMAL}$cli_path${NC}${cli_marker}"
            log INFO "4) Enter a different custom path"
        else
            log INFO "3) Enter a custom path"
        fi

        printf "Select option [%s]: " "$default_option"
        local selection
        read -r selection
        selection=${selection:-$default_option}

        case "$selection" in
            1)
                CONFIG_WIZARD_TARGET="$LOCAL_CONFIG_FILE"
                break
                ;;
            2)
                CONFIG_WIZARD_TARGET="$USER_CONFIG_FILE"
                break
                ;;
            3)
                if [[ "$has_cli" == true ]]; then
                    if [[ -z "$cli_path" ]]; then
                        log ERROR "The --config path is empty; please choose another option."
                    else
                        CONFIG_WIZARD_TARGET="$cli_path"
                        break
                    fi
                else
                    printf "Enter full path to configuration file: "
                    local custom_path
                    read -r custom_path
                    custom_path="$(expand_config_path "$custom_path")"
                    if [[ -z "$custom_path" ]]; then
                        log ERROR "Custom path cannot be empty."
                    else
                        CONFIG_WIZARD_TARGET="$custom_path"
                        break
                    fi
                fi
                ;;
            4)
                if [[ "$has_cli" == true ]]; then
                    printf "Enter full path to configuration file: "
                    local custom_path
                    read -r custom_path
                    custom_path="$(expand_config_path "$custom_path")"
                    if [[ -z "$custom_path" ]]; then
                        log ERROR "Custom path cannot be empty."
                    else
                        CONFIG_WIZARD_TARGET="$custom_path"
                        break
                    fi
                else
                    log ERROR "Invalid selection."
                fi
                ;;
            *)
                log ERROR "Invalid selection."
                ;;
        esac
    done

    log INFO "Configuration will be saved to: $CONFIG_WIZARD_TARGET"
}

run_configuration_wizard() {
    log HEADER "n8n-git configuration wizard"
    describe_config_sources
    select_config_destination
    log INFO "This will create or update your configuration at $CONFIG_WIZARD_TARGET"

    local expanded_target
    expanded_target="$(expand_config_path "$CONFIG_WIZARD_TARGET")"

    # Reset in-memory config so we only use the selected file as the source of truth
    github_token=""; github_repo=""; github_branch=""; github_path=""
    default_container=""; container=""
    project_name=""; n8n_path=""
    workflows=""; credentials=""; environment=""
    local_backup_path=""; credentials_encrypted=""
    folder_structure=""; n8n_base_url=""; n8n_api_key=""; n8n_session_credential=""
    n8n_email=""; n8n_password=""
    dry_run=""; verbose=""; assume_defaults=""
    log_file=""; git_commit_name=""; git_commit_email=""
    restore_preserve_ids=""; restore_no_overwrite=""
    project_name_source="unset"; workflows_source="unset"; credentials_source="unset"
    environment_source="unset"; local_backup_path_source="unset"; folder_structure_source="unset"
    credentials_encrypted_source="unset"; dry_run_source="unset"; container_source="unset"
    github_path_source="unset"; n8n_path_source="unset"; assume_defaults_source="unset"
    restore_preserve_ids_source="unset"; restore_no_overwrite_source="unset"

    config_file="$expanded_target"
    load_config

    if [[ -z "${project_name_source:-}" || "${project_name_source:-}" == "default" || "${project_name_source:-}" == "unset" ]]; then
        set_project_from_path "$PERSONAL_PROJECT_TOKEN"
        project_name_source="default"
    fi

    prompt_default_container

    local wizard_force="true"
    command="push"
    project_name_source="default"
    workflows_source="default"
    credentials_source="default"
    environment_source="default"
    local_backup_path_source="${local_backup_path_source:-default}"
    folder_structure_source="default"
    credentials_encrypted_source="default"
    dry_run_source="default"

    if [[ -z "${project_name:-}" ]]; then
        project_name="$PERSONAL_PROJECT_TOKEN"
    fi

    collect_push_preferences "$wizard_force" "true"
    prompt_dry_run_choice "$wizard_force"
    prompt_verbose_logging
    prompt_log_file_path
    prompt_assume_defaults_choice
    prompt_pull_defaults

    local needs_github=false
    if [[ "$workflows" == "2" ]] || [[ "$credentials" == "2" ]] || [[ "$environment" == "2" ]]; then
        needs_github=true
    fi

    if [[ "$needs_github" == true ]]; then
        get_github_config "true"
        local previous_action="$command"
        command="push"
        prompt_github_path_prefix
        command="$previous_action"
        prompt_git_identity
    else
        log INFO "GitHub settings omitted (local-only storage)."
        github_token=""
        github_repo=""
        github_branch=""
        github_path=""
    fi

    write_config_file "$CONFIG_WIZARD_TARGET"
}

# Select workflows push mode (0=disabled, 1=local, 2=remote)
select_workflows_storage() {
    log HEADER "Choose Workflows Storage Mode"
    echo "0) Disabled - Skip workflows"
    echo "1) Local Storage - Only use local storage"
    echo "2) Remote Storage - Store in Github repository"
    echo
    
    local default_value="${workflows:-1}"
    case "$default_value" in
        0|1|2) : ;;
        *) default_value=1 ;;
    esac

    local choice
    while true; do
        printf "Select workflows storage mode (0-2) [%s]: " "$default_value"
        read -r choice
        choice=${choice:-$default_value}
        case "$choice" in
            0) workflows=0; log INFO "Workflows storage: (0) disabled"; return ;;
            1) workflows=1; log INFO "Workflows storage: (1) local"; return ;;
            2) workflows=2; log INFO "Workflows storage: (2) remote"; return ;;
            *) echo "Invalid choice. Please enter 0, 1, or 2." ;;
        esac
    done
}

# Select credentials push mode (0=disabled, 1=local, 2=remote)  
select_credentials_storage() {
    local force_reprompt="${1:-false}"
    log HEADER "Choose Credentials Storage Mode"
    echo "0) Disabled - Skip credentials"
    echo "1) Local Storage - Keep credentials in local file system"
    echo "2) Remote Storage - Store credentials in Github repository (keep them encrypted for safety)"
    local default_value="${credentials:-1}"
    case "$default_value" in
        0|1|2) : ;;
        *) default_value=1 ;;
    esac
    local choice
    while true; do
        printf "Select credentials storage mode (0-2) [%s]: " "$default_value"
        read -r choice
        choice=${choice:-$default_value}
        case "$choice" in
            0) credentials=0; log INFO "Credentials storage: (0) disabled"; return ;;
            1) credentials=1; log INFO "Credentials storage: (1) local"; break ;;
            2) 
                credentials=2
                log INFO "Credentials storage: (2) remote"
                break
                ;;
            *) echo "Invalid choice. Please enter 0, 1, or 2." ;;
        esac
    done

    if [[ "$credentials" != "0" ]]; then
        prompt_credentials_encryption "$force_reprompt"
    fi
}

select_environment_storage() {
    log HEADER "Choose Environment Storage Mode"
    echo "0) Disabled - Skip environment variable push"
    echo "1) Local Storage - Store environment variables in local secure storage"
    echo "2) Remote Storage - Store environment variables in Git repository (NOT RECOMMENDED)"

    local default_value="${environment:-0}"
    case "$default_value" in
        0|1|2) : ;;
        *) default_value=0 ;;
    esac

    local choice
    while true; do
        printf "Select environment storage mode (0-2) [%s]: " "$default_value"
        read -r choice
        choice=${choice:-$default_value}
        case "$choice" in
            0) environment=0; log INFO "Environment storage: (0) disabled"; return ;;
            1) environment=1; log INFO "Environment storage: (1) local"; return ;;
            2)
                log WARN "You selected REMOTE STORAGE for environment variables!"
                printf "Are you sure you want to commit environment variables to Git? (y/N): "
                read -r confirm_env
                if [[ "$confirm_env" =~ ^[Yy]$ ]]; then
                    environment=2
                    log WARN "Environment storage: (2) remote (high risk)"
                    return
                else
                    log INFO "Environment storage remains disabled."
                    environment=0
                    return
                fi
                ;;
            *) echo "Invalid choice. Please enter 0, 1, or 2." ;;
        esac
    done
}

prompt_github_path_prefix() {
    log HEADER "GitHub Storage Path"

    log INFO "Dynamic values include %DATE%, %YYYY%, %MM%, %DD%, %HH%, %mm%, %ss%"
    log INFO "%HOSTNAME%, %PERSONAL_PROJECT%, and %PROJECT%"
    echo ""

    local command_context="${command:-push}"
    local current_raw=""
    if [[ -n "$github_path" ]]; then
        current_raw="$github_path"
    elif [[ -n "$n8n_path" ]]; then
        current_raw="$n8n_path"
    else
        current_raw="${project_name:-$PERSONAL_PROJECT_TOKEN}"
    fi

    if [[ -n "$current_raw" && "$current_raw" != "/" ]]; then
        log INFO "Current path: ${NORMAL}$current_raw${NC}"
    else
        log INFO "Current path: ${DIM}<repository root>${NC}"
    fi
    echo ""

    while true; do
        local path_prefix="$current_raw"

        if [[ "$path_prefix" == "/" || -z "$path_prefix" ]]; then
            printf "GitHub path [/]: "
        else
            printf "GitHub path [%s]: " "$path_prefix"
        fi

        local path_input
        read -r path_input

        if [[ -z "$path_input" ]]; then
            if [[ "$github_path_source" == "unset" ]]; then
                github_path_source="default"
            fi
            local final_prefix
            final_prefix="$(effective_repo_prefix)"
            if [[ -n "$final_prefix" ]]; then
                if [[ "$command_context" == "pull" ]]; then
                    log INFO "GitHub pull will read from: $final_prefix"
                else
                    log INFO "GitHub pushes will be stored under: $final_prefix"
                fi
            else
                if [[ "$command_context" == "pull" ]]; then
                    log INFO "GitHub pull will use the repository root."
                else
                    log INFO "GitHub pushes will be stored at the repository root."
                fi
            fi
            return
        fi

        if [[ "$path_input" == "/" ]]; then
            github_path=""
            github_path_source="interactive"
            if [[ "$command_context" == "pull" ]]; then
                log INFO "GitHub pull will use the repository root."
            else
                log INFO "GitHub pushes will be stored at the repository root."
            fi
            return
        fi

        local normalized
        normalized="$(normalize_github_path_prefix "$path_input")"
        if [[ -z "$normalized" ]]; then
            log WARN "Path removed all characters after normalization. Enter '/' for repository root or press Enter for the default project path."
            continue
        fi

        github_path="$normalized"
        github_path_source="interactive"
        if [[ "$command_context" == "pull" ]]; then
            log INFO "GitHub pull will read from: $github_path"
        else
            log INFO "GitHub pushes will be stored under: $github_path"
        fi
        return
    done
}
_reset_picker_group_primary_index() {
    local group_idx="$1"
    local group_entry="${_RESET_PICKER_GROUPS[$group_idx]:-}"
    if [[ -z "$group_entry" ]]; then
        echo ""
        return 1
    fi
    printf '%s\n' "${group_entry%%,*}"
}

_reset_picker_group_commit_indices() {
    local group_idx="$1"
    local group_entry="${_RESET_PICKER_GROUPS[$group_idx]:-}"
    IFS=',' read -r -a group_commits <<<"$group_entry"
    printf '%s\n' "${group_commits[*]}"
}

_reset_picker_group_matches_filter() {
    local group_idx="$1"
    local filter="$2"
    if [[ -z "$filter" ]]; then
        return 0
    fi
    local indices
    IFS=' ' read -r -a indices <<<"$(_reset_picker_group_commit_indices "$group_idx")"
    local commit_idx
    for commit_idx in "${indices[@]}"; do
        local entry="${_RESET_PICKER_COMMITS[$commit_idx]}"
        if _reset_picker_matches_filter "$entry" "$filter"; then
            return 0
        fi
    done
    return 1
}

_reset_picker_resolve_group_index() {
    local ordinal="$1"
    local index=$((ordinal - 1))
    if (( index < 0 || index >= ${#_RESET_PICKER_GROUP_DISPLAY_ORDER[@]} )); then
        echo ""
        return 1
    fi
    printf '%s\n' "${_RESET_PICKER_GROUP_DISPLAY_ORDER[$index]}"
}

_reset_picker_resolve_commit_index() {
    local ordinal="$1"
    local commit_ordinal="$2"
    local group_index
    group_index=$(_reset_picker_resolve_group_index "$ordinal") || return 1
    local group_entry="${_RESET_PICKER_GROUPS[$group_index]}"
    IFS=',' read -r -a members <<<"$group_entry"
    local commit_index=$((commit_ordinal - 1))
    if (( commit_index < 0 || commit_index >= ${#members[@]} )); then
        echo ""
        return 1
    fi
    printf '%s\n' "${members[$commit_index]}"
}

_reset_picker_toggle_group() {
    local ordinal="$1"
    local group_index
    group_index=$(_reset_picker_resolve_group_index "$ordinal") || return 1
    if [[ -n "${_RESET_PICKER_EXPANDED_GROUPS[$group_index]:-}" ]]; then
        unset "_RESET_PICKER_EXPANDED_GROUPS[$group_index]"
    else
        _RESET_PICKER_EXPANDED_GROUPS[$group_index]=1
    fi
    return 0
}

_reset_picker_clear_screen() {
    if [[ "${RESET_PICKER_FULL_REDRAW,,}" == "true" ]]; then
        printf '\033[2J\033[H'
    fi
}

_reset_picker_select_commit() {
    local commit_index="$1"
    local selection_label="$2"
    local filter="$3"
    local view_label="$4"
    local auto_confirm="${5:-false}"

    local entry="${_RESET_PICKER_COMMITS[$commit_index]:-}"
    if [[ -z "$entry" ]]; then
        return 1
    fi
    if [[ "$auto_confirm" != "true" ]]; then
        if ! _reset_picker_show_confirmation "$entry" "$selection_label"; then
            return 2
        fi
    fi
    _reset_picker_emit_json "$entry" "$selection_label" "$filter" "$view_label"
    return 0
}

_reset_picker_show_confirmation() {
    local entry="$1"
    local selection_label="$2"
    local sha short iso author subject decorations day_label week_label epoch
    IFS='|' read -r sha short iso author subject decorations day_label week_label epoch <<<"$entry"
    local time_label
    time_label="$(_reset_picker_time_badge "$iso" "$epoch")"
    echo
    log HEADER "Confirm Commit Selection"
    printf "  %sSelection:%s %s\n" "$BOLD" "$NC" "$selection_label"
    printf "  %sCommit:%s %s (%s)\n" "$BOLD" "$NC" "$short" "$sha"
    printf "  %sAuthor:%s %s\n" "$BOLD" "$NC" "$author"
    printf "  %sTime:%s %s %s\n" "$BOLD" "$NC" "$day_label" "$time_label"
    printf "  %sMessage:%s %s\n" "$BOLD" "$NC" "$subject"
    if [[ -n "$decorations" ]]; then
        printf "  %sRefs:%s %s\n" "$BOLD" "$NC" "$decorations"
    fi
    printf "\nConfirm this commit? [Y]es / [N]o / [B]ack: "
    local answer
    read -r answer
    answer="${answer,,}"
    case "$answer" in
        ""|y|yes) return 0 ;;
        b|back) return 2 ;;
        *) return 1 ;;
    esac
}

_reset_picker_format_duration() {
    local seconds="$1"
    if (( seconds <= 0 )); then
        echo "<1m"
        return 0
    fi
    local mins=$((seconds / 60))
    if (( mins < 1 )); then
        echo "<1m"
        return 0
    fi
    if (( mins < 60 )); then
        printf '%dm' "$mins"
        return 0
    fi
    local hours=$((mins / 60))
    mins=$((mins % 60))
    if (( mins == 0 )); then
        printf '%dh' "$hours"
    else
        printf '%dh%02dm' "$hours" "$mins"
    fi
}
_reset_picker_render_grouped() {
    local filter="$1"
    local page=${RESET_PICKER_GROUP_PAGE:-0}
    (( page < 0 )) && page=0
    _RESET_PICKER_RENDERED_INDICES=()
    _RESET_PICKER_GROUP_DISPLAY_ORDER=()

    if [[ -n "$filter" ]]; then
        log INFO "${DIM}Filter:${NC} \"$filter\""
    fi

    local -a matching_indices=()
    local idx
    for idx in "${!_RESET_PICKER_GROUPS[@]}"; do
        if [[ -n "$filter" ]] && ! _reset_picker_group_matches_filter "$idx" "$filter"; then
            continue
        fi
        matching_indices+=("$idx")
    done

    _RESET_PICKER_GROUP_DISPLAY_ORDER=("${matching_indices[@]}")

    local total_matches=${#matching_indices[@]}
    if (( total_matches == 0 )); then
        log WARN "No batches match the current filter."
        RESET_PICKER_LAST_TOTAL=0
        RESET_PICKER_TOTAL_PAGES=1
        RESET_PICKER_PAGE_MIN=0
        RESET_PICKER_PAGE_MAX=0
        RESET_PICKER_PAGE_VISIBLE_COUNT=0
        return 0
    fi

    local per_page=${RESET_PICKER_GROUPS_PER_PAGE:-5}
    (( per_page <= 0 )) && per_page=5

    local total_pages=$(((total_matches + per_page - 1) / per_page))
    (( total_pages <= 0 )) && total_pages=1
    RESET_PICKER_TOTAL_PAGES=$total_pages

    if (( page >= total_pages )); then
        page=$(( total_pages - 1 ))
        RESET_PICKER_GROUP_PAGE=$page
    fi

    local start_index=$(( page * per_page ))
    local end_index=$(( start_index + per_page ))
    if (( end_index > total_matches )); then
        end_index=$total_matches
    fi

    local display_start=$(( start_index + 1 ))
    if (( total_matches == 0 )); then
        display_start=0
    elif (( display_start < 1 )); then
        display_start=1
    fi
    local display_end=$end_index
    if (( display_end < display_start )); then
        display_end=$display_start
    fi

    RESET_PICKER_PAGE_MIN=$display_start
    # shellcheck disable=SC2034  # shared with navigation prompts
    RESET_PICKER_PAGE_MAX=$display_end
    RESET_PICKER_PAGE_VISIBLE_COUNT=$(( end_index - start_index ))

    printf "%sShowing restore points %d-%d of %d (page %d/%d)%s\n\n" \
        "$DIM" \
        "$display_start" \
        "$display_end" \
        "$total_matches" \
        "$(( page + 1 ))" \
        "$total_pages" \
        "$NC"

    local ordinal=$(( display_start - 1 ))
    local last_day_label=""

    for (( idx=start_index; idx<end_index; idx++ )); do
        local group_idx="${matching_indices[$idx]}"
        ordinal=$((ordinal + 1))
        local group_entry="${_RESET_PICKER_GROUPS[$group_idx]}"
        IFS=',' read -r -a members <<<"$group_entry"
        local primary_index="${members[0]}"
        local primary="${_RESET_PICKER_COMMITS[$primary_index]}"
        IFS='|' read -r sha short iso author subject decorations day_label week_label epoch <<<"$primary"

        local summary_line="" detail_block=""
        _reset_picker_group_preview "$group_idx" summary_line detail_block

        if [[ -z "$summary_line" ]]; then
            local commit_total="${#members[@]}"
            local commit_plural=""
            (( commit_total != 1 )) && commit_plural="s"
            local fallback_relative
            fallback_relative=$(_reset_picker_relative_label "$epoch")
            local fallback_time_label="${iso:11:5}"
            if [[ -n "$fallback_relative" ]]; then
                fallback_time_label+=" · $fallback_relative"
            fi
            printf -v summary_line "• %s%s%s : %s %s (%d commit%s)" \
                "$BLUE" "$short" "$NC" \
                "${day_label:-${iso%%T*}}" \
                "$fallback_time_label" \
                "$commit_total" "$commit_plural"
        fi

        if [[ -n "$day_label" && "$day_label" != "$last_day_label" ]]; then
            [[ -n "$last_day_label" ]] && printf "\n"
            printf "  %sDay: %s%s\n\n" "$DIM" "$day_label" "$NC"
            last_day_label="$day_label"
        fi

        local state="${_RESET_PICKER_EXPANDED_GROUPS[$group_idx]:-}"
        local marker="[+]"
        if [[ -n "$state" ]]; then
            marker="[-]"
        fi

        printf "  %2d) %s %s\n" \
            "$ordinal" \
            "$marker" \
            "$summary_line"

        if [[ -n "$detail_block" ]]; then
            while IFS= read -r detail_line; do
                [[ -z "$detail_line" ]] && continue
                printf "        %s%s%s\n" "$DIM" "$detail_line" "$NC"
            done <<<"$detail_block"
        fi

        _RESET_PICKER_RENDERED_INDICES+=("group|$group_idx|$ordinal")

        if [[ -n "$state" ]]; then
            local commit_ordinal=0
            local member
            for member in "${members[@]}"; do
                commit_ordinal=$((commit_ordinal + 1))
                local data="${_RESET_PICKER_COMMITS[$member]}"
                IFS='|' read -r _ c_short c_iso c_author c_subject c_dec _ _ c_epoch <<<"$data"
                local parsed_commit
                parsed_commit=$(_reset_picker_parse_subject "$c_subject")
                IFS='|' read -r c_action_label _ c_descriptor c_entity_type <<<"$parsed_commit"
                local action_key
                action_key=$(_reset_picker_action_key "$c_action_label")
                local action_color
                action_color=$(_reset_picker_action_color "$action_key")
                local action_label="${c_action_label:-Commit}"
                local action_block="${action_color}[${action_label}]${NC}"
                local type_tag=""
                case "$c_entity_type" in
                    credential) type_tag="${MAGENTA:-$YELLOW}[CRED]${NC}" ;;
                    workflow) type_tag="${BLUE}[WF]${NC}" ;;
                    system) type_tag="${DIM}[SYS]${NC}" ;;
                    *) type_tag="${DIM}[--]${NC}" ;;
                esac
                local short_block="${BLUE}${c_short}${NC}"
                if [[ -n "$c_dec" ]]; then
                    short_block+=" $c_dec"
                fi
                local descriptor_text
                descriptor_text="$(_reset_picker_clean_descriptor "$c_descriptor")"
                if [[ -z "$descriptor_text" ]]; then
                    descriptor_text="$c_subject"
                fi
                local author_block="${DIM}— $c_author${NC}"
                local time_badge
                time_badge="$(_reset_picker_time_badge "$c_iso" "$c_epoch")"
                local time_block="${DIM}${time_badge}${NC}"
                printf "        %2d.%d) %s %s %s %s %s %s\n" \
                    "$ordinal" "$commit_ordinal" \
                    "$short_block" \
                    "$action_block" \
                    "$type_tag" \
                    "$descriptor_text" \
                    "$author_block" \
                    "$time_block"
                _RESET_PICKER_RENDERED_INDICES+=("commit|$member|$ordinal.$commit_ordinal")
            done
        fi

        printf "\n"
    done

    printf "\n"

    RESET_PICKER_LAST_TOTAL=$total_matches
    return 0
}
_reset_picker_infer_entity_type() {
    local descriptor="$1"
    local hint="$2"
    local descriptor_lower="${descriptor,,}"
    local hint_lower="${hint,,}"

    if [[ "$descriptor_lower" == reset* ]] || [[ "$descriptor_lower" == *" reset" ]]; then
        printf 'system'
        return 0
    fi

    if [[ "$descriptor_lower" == *".credentials/"* ]]; then
        printf 'credential'
        return 0
    fi

    if [[ "$descriptor_lower" == *"[inactive]"* ]] || [[ "$descriptor_lower" == *"[active]"* ]] || [[ "$descriptor_lower" == *" workflow"* ]] || [[ "$descriptor_lower" == *"workflows"* ]] || [[ "$descriptor_lower" == *"tests/"* ]]; then
        printf 'workflow'
        return 0
    fi

    if [[ "$descriptor_lower" == *" account"* ]] || [[ "$descriptor_lower" == *" credentials"* ]] || [[ "$descriptor_lower" == *"[httpbasicauth]"* ]] || [[ "$descriptor_lower" == *"[smtp"* ]] || [[ "$descriptor_lower" == *"[imap"* ]] || [[ "$descriptor_lower" == *"api]"* ]] || [[ "$descriptor_lower" == *"oauth"* ]]; then
        printf 'credential'
        return 0
    fi

    case "$hint_lower" in
        wf|workflow|workflows|flow|flows)
            printf 'workflow'
            return 0
            ;;
        cred|creds|credential|credentials)
            printf 'credential'
            return 0
            ;;
        sys|system)
            printf 'system'
            return 0
            ;;
    esac

    printf 'workflow'
}
