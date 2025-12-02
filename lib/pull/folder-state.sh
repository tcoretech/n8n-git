#!/usr/bin/env bash
# Load current n8n folder/project state for restore operations

# Global state maps - populated once during restore
declare -g -A N8N_PROJECTS=()              # ["project_name"]="project_id"
declare -g -A N8N_FOLDERS=()               # ["project_id/folder/path"]="folder_id"
declare -g -A N8N_FOLDER_PARENTS=()        # ["folder_id"]="parent_folder_id"
declare -g -A N8N_WORKFLOWS=()             # ["workflow_id"]="folder_id|project_id|version_id"
declare -g N8N_DEFAULT_PROJECT_ID=""
# shellcheck disable=SC2034 # Exported for restore pipeline state checks
declare -g RESTORE_N8N_STATE_INITIALIZED="false"

invalidate_n8n_state_cache() {
    N8N_PROJECTS=()
    N8N_FOLDERS=()
    N8N_FOLDER_PARENTS=()
    N8N_WORKFLOWS=()
    N8N_DEFAULT_PROJECT_ID=""
    RESTORE_N8N_STATE_INITIALIZED="false"
}

# --- Internal helpers -------------------------------------------------------

_sanitize_cache_text() {
    local value="${1:-}"
    value=$(printf '%s' "$value" \
        | tr -d '\r' \
        | tr '\n\t' '  ' \
        | sed 's/[[:cntrl:]]//g' \
        | sed 's/[[:space:]]\+/ /g' \
        | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')
    value=${value//\\r/}
    value=${value//\\n/}
    value=${value//\\t/}
    printf '%s' "$value"
}

_normalize_folder_path() {
    local raw="${1:-}"
    local -a cleaned=()
    IFS='/' read -r -a __parts <<< "$raw"
    for __component in "${__parts[@]}"; do
        local sanitized
        sanitized=$(_sanitize_cache_text "$__component")
        [[ -z "$sanitized" ]] && continue
        cleaned+=("$sanitized")
    done
    unset __parts __component

    if ((${#cleaned[@]} == 0)); then
        printf ''
    else
        (IFS=/; printf '%s' "${cleaned[*]}")
    fi
}

_build_folder_cache_key() {
    local project_id
    project_id=$(_sanitize_cache_text "${1:-}")
    local folder_path
    folder_path=$(_normalize_folder_path "${2:-}")

    if [[ -z "$project_id" ]]; then
        printf '%s' "$folder_path"
    elif [[ -z "$folder_path" ]]; then
        printf '%s' "$project_id"
    else
        printf '%s/%s' "$project_id" "$folder_path"
    fi
}

set_folder_cache_entry() {
    local project_id
    project_id=$(_sanitize_cache_text "${1:-}")
    local folder_path
    folder_path=$(_normalize_folder_path "${2:-}")
    local folder_id
    folder_id=$(_sanitize_cache_text "${3:-}")

    [[ -z "$folder_id" ]] && return 0

    local cache_key
    cache_key=$(_build_folder_cache_key "$project_id" "$folder_path")
    N8N_FOLDERS["$cache_key"]="$folder_id"

    if [[ "${verbose:-false}" == "true" ]]; then
        local log_message
        if [[ -z "$folder_path" ]]; then
            printf -v log_message 'Cached folder mapping: project=%s (root) → %s' "${project_id:-<none>}" "$folder_id"
        else
            printf -v log_message 'Cached folder mapping: project=%s path=%s → %s' "${project_id:-<none>}" "$folder_path" "$folder_id"
        fi
        log DEBUG "$log_message"
    fi
}

set_workflow_assignment_state() {
    local workflow_id
    workflow_id=$(_sanitize_cache_text "${1:-}")
    local folder_id
    folder_id=$(_sanitize_cache_text "${2:-}")
    local project_id
    project_id=$(_sanitize_cache_text "${3:-}")
    local version_id
    version_id=$(_sanitize_cache_text "${4:-}")

    [[ -z "$workflow_id" ]] && return 0

    N8N_WORKFLOWS["$workflow_id"]="$folder_id|$project_id|$version_id"
}

debug_dump_folder_cache() {
    local context="${1:-}"
    [[ "${verbose:-false}" != "true" ]] && return 0

    local total=${#N8N_FOLDERS[@]}
    local context_label=""
    if [[ -n "$context" ]]; then
        context_label=" ($context)"
    fi

    if (( total == 0 )); then
        log DEBUG "Folder cache empty${context_label}"
        return 0
    fi

    log DEBUG "Folder cache entries${context_label}:"
    local shown=0
    for __folder_cache_key in "${!N8N_FOLDERS[@]}"; do
        log DEBUG "    ${__folder_cache_key:-<project-root>} → ${N8N_FOLDERS[$__folder_cache_key]}"
        shown=$((shown + 1))
        if (( shown >= 10 )); then
            break
        fi
    done

    if (( total > shown )); then
        log DEBUG "    …and $((total - shown)) additional entrie(s) hidden"
    fi
    unset __folder_cache_key
}

# Load projects from n8n API into memory
# Returns: 0 on success, 1 on failure
load_n8n_projects() {
    local projects_json="$1"
    
    N8N_PROJECTS=()
    N8N_DEFAULT_PROJECT_ID=""
    
    if [[ -z "$projects_json" ]]; then
        log ERROR "Cannot load projects: empty payload"
        return 1
    fi
    
    local project_count=0
    local personal_project_id=""
    
    # Stream projects directly, no temp files
    while IFS=$'\t' read -r project_id project_name project_type; do
        [[ -z "$project_id" ]] && continue
        
        project_id=$(_sanitize_cache_text "$project_id")
        project_name=$(_sanitize_cache_text "$project_name")

        # Normalize project name for lookup (case-insensitive)
        local name_key
        name_key=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed 's/^ //; s/ $//')
        
        N8N_PROJECTS["$name_key"]="$project_id"
        project_count=$((project_count + 1))
        
        # Track personal/default project
        if [[ "$project_type" == "personal" ]] || [[ "$name_key" == "personal" ]]; then
            personal_project_id="$project_id"
            remember_personal_project_name "$project_name"
        fi
        
        # First project becomes default if no personal found
        [[ -z "$N8N_DEFAULT_PROJECT_ID" ]] && N8N_DEFAULT_PROJECT_ID="$project_id"
        
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "Project available: ${project_name} (ID: ${project_id})"
        fi
    done < <(printf '%s' "$projects_json" | jq -r '
        (if type == "array" then . else (.data // []) end)
        | .[]
        | [.id, .name, (.type // "")] 
        | @tsv
    ' 2>/dev/null | tr -d '\r')
    
    # Prefer personal project as default
    if [[ -n "$personal_project_id" ]]; then
        N8N_DEFAULT_PROJECT_ID="$personal_project_id"
        N8N_PROJECTS["personal"]="$personal_project_id"
    fi
    
    if [[ "$project_count" -eq 0 ]]; then
        log ERROR "No projects found in n8n instance"
        return 1
    fi
    
    log INFO "Loaded $project_count project(s) from n8n"
    return 0
}

# Load existing folders from n8n API into memory
# Builds folder path lookup by recursively resolving parent chains
# Returns: 0 on success, 1 on failure
load_n8n_folders() {
    local folders_json="$1"
    
    if [[ -z "$folders_json" ]]; then
        log DEBUG "n8n returned no folders; keeping folder cache empty"
        return 0
    fi
    
    # Only clear cache when loading fresh data from n8n
    N8N_FOLDERS=()
    N8N_FOLDER_PARENTS=()
    
    # First pass: load all folders with their immediate parent references
    declare -A folder_names=()
    declare -A folder_projects=()
    
    while IFS=$'\t' read -r folder_id folder_name parent_id project_id; do
        [[ -z "$folder_id" ]] && continue
        
        folder_id=$(_sanitize_cache_text "$folder_id")
        folder_name=$(_sanitize_cache_text "$folder_name")
        parent_id=$(_sanitize_cache_text "$parent_id")
        project_id=$(_sanitize_cache_text "$project_id")

        [[ -z "$folder_id" ]] && continue

        folder_names["$folder_id"]="$folder_name"
        folder_projects["$folder_id"]="$project_id"
        
        # Store parent relationship (empty means root)
        if [[ -n "$parent_id" && "$parent_id" != "null" ]]; then
            N8N_FOLDER_PARENTS["$folder_id"]="$parent_id"
        fi
        
        done < <(printf '%s' "$folders_json" | jq -r '
        (if type == "array" then . else (.data // []) end)
        | .[]
        | [
            .id,
            .name,
            (.parentFolderId // (.parentFolder.id // "")),
            (.projectId // (.homeProject.id // .homeProjectId // ""))
          ]
        | @tsv
        ' 2>/dev/null | tr -d '\r')
    
    # Second pass: build full paths by walking parent chains
    local folder_count=0
    local fallback_project_assignments=0
    local skipped_missing_project=0
    for folder_id in "${!folder_names[@]}"; do
        local project_id="${folder_projects[$folder_id]}"
        if [[ -z "$project_id" || "$project_id" == "null" ]]; then
            local parent_ref="${N8N_FOLDER_PARENTS[$folder_id]:-}"
            if [[ -n "$parent_ref" && -n "${folder_projects[$parent_ref]:-}" && "${folder_projects[$parent_ref]}" != "null" ]]; then
                project_id="${folder_projects[$parent_ref]}"
            elif [[ -n "$N8N_DEFAULT_PROJECT_ID" ]]; then
                project_id="$N8N_DEFAULT_PROJECT_ID"
                fallback_project_assignments=$((fallback_project_assignments + 1))
            else
                skipped_missing_project=$((skipped_missing_project + 1))
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Skipping folder ID $folder_id — project reference missing and no default project configured"
                fi
                continue
            fi
        fi

        # Persist resolved project assignment for downstream lookups
        folder_projects["$folder_id"]="$project_id"
        
        # Walk up parent chain to build full path
        local -a path_parts=()
        local current_id="$folder_id"
        local safety_counter=0
        
        while [[ -n "$current_id" ]] && ((safety_counter < 50)); do
            local segment="${folder_names[$current_id]:-}"
            if [[ -z "$segment" ]]; then
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Folder metadata incomplete when resolving parent chain for folder ID $folder_id (missing parent metadata); using partial path"
                fi
                break
            fi

            path_parts=("$segment" "${path_parts[@]}")
            current_id="${N8N_FOLDER_PARENTS[$current_id]:-}"
            safety_counter=$((safety_counter + 1))
        done

        if (( safety_counter >= 50 )); then
            log WARN "Detected potential cycle while resolving folder hierarchy for ID $folder_id; truncated path after 50 iterations"
        fi

        # Build path key: project_id/folder/path
        local folder_path
        folder_path=$(_normalize_folder_path "$(IFS=/; printf '%s' "${path_parts[*]}")")

        set_folder_cache_entry "$project_id" "$folder_path" "$folder_id"
        folder_count=$((folder_count + 1))
        
        if [[ "$verbose" == "true" ]]; then
            local folder_display="${folder_names[$folder_id]:-Folder}"
            local path_display="${folder_path:-<project-root>}"
            log DEBUG "Discovered folder '$folder_display' (ID: $folder_id) at '$path_display' in project $project_id"
        fi
    done
    
    log INFO "Loaded $folder_count folder(s) from n8n"
    if [[ "$fallback_project_assignments" -gt 0 ]]; then
        local fallback_msg="Assigned default project ${N8N_DEFAULT_PROJECT_ID:-<unknown>} to $fallback_project_assignments folder(s) without explicit project metadata"
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "$fallback_msg"
        else
            log INFO "$fallback_msg"
        fi
    fi
    if [[ "$skipped_missing_project" -gt 0 ]]; then
        log WARN "Omitted $skipped_missing_project folder(s) because n8n did not report a project reference"
    fi
    return 0
}

# Load existing workflows from n8n API into memory
# Tracks current folder assignment for each workflow
# Returns: 0 on success, 1 on failure
load_n8n_workflows() {
    local workflows_json="$1"
    
    N8N_WORKFLOWS=()
    
    if [[ -z "$workflows_json" ]]; then
        log DEBUG "No workflows in n8n instance (starting fresh)"
        return 0
    fi
    
    local workflow_count=0
    
    while IFS=$'\t' read -r workflow_id folder_id project_id version_id; do
        workflow_id=$(_sanitize_cache_text "$workflow_id")
        folder_id=$(_sanitize_cache_text "$folder_id")
        project_id=$(_sanitize_cache_text "$project_id")
        version_id=$(_sanitize_cache_text "$version_id")

        [[ -z "$workflow_id" ]] && continue
        
        # Store current assignment: folder_id|project_id|version_id
        N8N_WORKFLOWS["$workflow_id"]="${folder_id}|${project_id}|${version_id}"
        workflow_count=$((workflow_count + 1))
        
        done < <(printf '%s' "$workflows_json" | jq -r '
        (if type == "array" then . else (.data // []) end)
        | .[]
        | [
            .id,
            (.parentFolderId // (.parentFolder.id // "")),
            (.homeProject.id // .homeProjectId // ""),
            (.versionId // (.version.id // ""))
          ]
        | @tsv
        ' 2>/dev/null | tr -d '\r')
    
    log INFO "Loaded $workflow_count workflow(s) from n8n"
    return 0
}

# Initialize all n8n state from API responses
# This is the single entry point for loading state
# Returns: 0 on success, 1 on failure
load_n8n_state() {
    local projects_json="$1"
    local folders_json="$2"
    local workflows_json="$3"
    local force_refresh="${4:-false}"

    if [[ "$force_refresh" == "true" ]]; then
        invalidate_n8n_state_cache
    fi

    log INFO "Loading current n8n workspace state"
        
    if ! load_n8n_projects "$projects_json"; then
        log ERROR "Failed to load n8n projects"
        return 1
    fi
    
    if ! load_n8n_folders "$folders_json"; then
        log WARN "Failed to load n8n folders (continuing with empty folder state)"
    fi
    
    if ! load_n8n_workflows "$workflows_json"; then
        log WARN "Failed to load n8n workflows (continuing with empty workflow state)"
    fi
    
    log SUCCESS "n8n workspace state ready"
    # shellcheck disable=SC2034 # Exported for downstream restore steps
    RESTORE_N8N_STATE_INITIALIZED="true"
    return 0
}

# Lookup project ID by name (case-insensitive)
# Args: project_name
# Returns: project_id or empty string
get_project_id() {
    local project_name="$1"
    local name_key
    name_key=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed 's/^ //; s/ $//')
    
    printf '%s' "${N8N_PROJECTS[$name_key]:-}"
}

# Check if folder exists in n8n
# Args: project_id, folder_path
# Returns: folder_id or empty string
get_folder_id() {
    local project_id="$1"
    local folder_path="$2"
    local path_key
    path_key=$(_build_folder_cache_key "$project_id" "$folder_path")

    printf '%s' "${N8N_FOLDERS[$path_key]:-}"
}

# Get current folder assignment for workflow
# Args: workflow_id
# Returns: "folder_id|project_id" or empty string
get_workflow_assignment() {
    local workflow_id="$1"
    printf '%s' "${N8N_WORKFLOWS[$workflow_id]:-}"
}
