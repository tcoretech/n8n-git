#!/usr/bin/env bash
# =========================================================
# lib/n8n/endpoints.sh - n8n API endpoint wrappers
# =========================================================
# High-level functions for interacting with specific n8n API endpoints

if [[ -n "${LIB_N8N_ENDPOINTS_LOADED:-}" ]]; then
  return 0
fi
LIB_N8N_ENDPOINTS_LOADED=true

# shellcheck source=lib/n8n/auth.sh
source "${BASH_SOURCE[0]%/*}/auth.sh"

n8n_api_projects_fallback_from_workflows() {
    local workflows_json=""
    if ! workflows_json=$(n8n_api_get_workflows true 2>/dev/null); then
        log WARN "Workflow project fallback could not fetch workflows (status=${N8N_API_LAST_STATUS:-unknown}, body='${N8N_API_LAST_BODY:-}')"
        return 1
    fi

    local fallback="[]"
    if ! fallback=$(printf '%s' "$workflows_json" | jq -c '
        (if type == "array" then . else (.data // []) end)
        | map({
            id: ((.homeProject.id // .homeProjectId // "") | tostring),
            name: (.homeProject.name // .homeProject.displayName // "Personal"),
            type: (.homeProject.type // .homeProject.projectType // "personal")
        })
        | map(select(.id != ""))
        | unique_by(.id)
    ' 2>/dev/null); then
        log WARN "Workflow-derived project fallback jq failure; payload preview: $(printf '%s' "$workflows_json" | head -c 200)"
        return 1
    fi

    if [[ "$fallback" == "[]" ]]; then
        log WARN "Workflow-derived project fallback returned empty list; payload preview: $(printf '%s' "$workflows_json" | head -c 200)"
        return 1
    fi

    printf '%s' "$fallback"
    return 0
}

n8n_api_projects_fetch_personal() {
    local response=""
    if ! response=$(n8n_api_request "GET" "/projects/personal" 2>/dev/null); then
        return 1
    fi

    if [[ -z "$response" || "$response" == "{}" ]]; then
        return 1
    fi

    local normalized
    if ! normalized=$(printf '%s' "$response" | jq -c '(.data // .) | (if type == "array" then . else [.] end)'); then
        return 1
    fi

    local has_entry
    has_entry=$(printf '%s' "$normalized" | jq -r 'length > 0' 2>/dev/null || printf 'false')
    if [[ "$has_entry" != "true" ]]; then
        return 1
    fi

    printf '%s' "$normalized"
    return 0
}

n8n_api_get_projects() {
    local response=""
    local last_endpoint=""
    local status=""
    local category=""

    local -a candidate_endpoints=(
        "/projects?skip=0&take=250"
        "/projects?offset=0&limit=250"
        "/projects"
    )

    local endpoint
    for endpoint in "${candidate_endpoints[@]}"; do
        last_endpoint="$endpoint"
        if response=$(n8n_api_request "GET" "$endpoint"); then
            local has_entries="true"
            if [[ -n "$response" ]]; then
                has_entries=$(printf '%s' "$response" | jq -r '
                    if type == "array" then
                        if length > 0 then "true" else "false" end
                    else
                        (((.data // []) | length) > 0)
                    end
                ' 2>/dev/null || printf 'true')
            fi

            if [[ "$has_entries" != "true" ]]; then
                local preview_empty
                preview_empty=$(printf '%s' "$response" | tr '\n' ' ' | head -c 160)
                log WARN "Projects endpoint $endpoint returned no entries (has_entries=$has_entries, preview='${preview_empty}')"
                if [[ "${verbose:-false}" == "true" ]]; then
                    log DEBUG "Projects endpoint $endpoint returned no entries; attempting additional fallbacks."
                fi

                local personal_json
                if personal_json=$(n8n_api_projects_fetch_personal 2>/dev/null); then
                    printf '%s' "$personal_json"
                    return 0
                fi
                if [[ "${verbose:-false}" == "true" ]]; then
                    local personal_status="${N8N_API_LAST_STATUS:-unknown}"
                    log DEBUG "Personal project fallback returned no data (HTTP ${personal_status})."
                fi

                if n8n_api_projects_fallback_from_workflows; then
                    return 0
                fi

                continue
            fi

            N8N_PROJECTS_LAST_SUCCESS_JSON="$response"
            local personal_name
            personal_name=$(printf '%s' "$response" | jq -r '
                (if type == "array" then . else (.data // []) end)
                | map(select((.type // "") == "personal") | .name // empty)
                | map(select(. != "" and . != "null"))
                | first // empty
            ' 2>/dev/null || echo "")
            if [[ -n "$personal_name" ]]; then
                remember_personal_project_name "$personal_name"
                project_name="$personal_name"
                N8N_PROJECT="$personal_name"
            fi
            printf '%s' "$response"
            return 0
        fi

        status="${N8N_API_LAST_STATUS:-}"
        category="${N8N_API_LAST_ERROR_CATEGORY:-}"

        if [[ "${verbose:-false}" == "true" ]]; then
            local preview suffix
            preview="${N8N_API_LAST_BODY:-}"
            if [[ -n "$preview" ]]; then
                preview=$(printf '%s' "$preview" | tr '\n' ' ' | head -c 160)
                suffix=""
                if [[ ${#preview} -ge 160 ]]; then
                    suffix="…"
                fi
                log DEBUG "Projects endpoint $endpoint failed (HTTP ${status:-unknown}, category=${category:-none}, body=${preview}${suffix})"
            else
                log DEBUG "Projects endpoint $endpoint failed (HTTP ${status:-unknown}, category=${category:-none})"
            fi
        fi

        if [[ "$status" == "401" ]]; then
            break
        fi

        if [[ "$category" == "license" ]]; then
            break
        fi
    done

    status="${N8N_API_LAST_STATUS:-}"
    category="${N8N_API_LAST_ERROR_CATEGORY:-}"

    if [[ "$category" == "license" ]]; then
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Attempting workflow-derived project list after license block from $last_endpoint."
        fi
        if n8n_api_projects_fallback_from_workflows; then
            return 0
        fi
        log INFO "n8n projects endpoint unavailable due to license restrictions; synthesizing fallback project list."
        printf '%s' '[{"id":"default","name":"Default","type":"personal"}]'
        return 0
    fi

    if [[ "$status" == "404" || "$status" == "400" ]]; then
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Attempting fallback project enumeration via workflows after ${status:-unknown} from $last_endpoint."
        fi
        local personal_payload
        if personal_payload=$(n8n_api_projects_fetch_personal 2>/dev/null); then
            printf '%s' "$personal_payload"
            return 0
        fi
        if [[ "${verbose:-false}" == "true" ]]; then
            local personal_status="${N8N_API_LAST_STATUS:-unknown}"
            log DEBUG "Personal project fallback (error branch) returned no data (HTTP ${personal_status})."
        fi

        if n8n_api_projects_fallback_from_workflows; then
            return 0
        fi
    fi

    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "Project enumeration failed after attempting ${#candidate_endpoints[@]} endpoint(s); last endpoint $last_endpoint returned HTTP ${status:-unknown}."
    fi

    if [[ -n "${N8N_PROJECTS_LAST_SUCCESS_JSON:-}" ]]; then
        log WARN "Project enumeration failed; returning cached project list from previous successful request."
        printf '%s' "$N8N_PROJECTS_LAST_SUCCESS_JSON"
        return 0
    fi

    local error_preview=""
    local error_suffix=""
    if [[ -n "${N8N_API_LAST_BODY:-}" ]]; then
        error_preview=$(printf '%s' "${N8N_API_LAST_BODY}" | tr '\n' ' ' | head -c 160)
        if [[ ${#N8N_API_LAST_BODY} -gt 160 ]]; then
            error_preview+="…"
        fi
        local sanitized_preview="${error_preview//\"/\\\"}"
        error_suffix=", body=\"${sanitized_preview}\""
    fi

    log ERROR "Unable to enumerate n8n projects (endpoint=${last_endpoint:-unknown}, status=${status:-unknown}, category=${category:-none}${error_suffix})"

    return 1
}

n8n_api_get_folders() {
    local projects_json
    if ! projects_json=$(n8n_api_get_projects); then
        log ERROR "Unable to retrieve projects while enumerating folders"
        return 1
    fi
    # shellcheck disable=SC2034  # cached for downstream consumers in other modules
    N8N_PROJECTS_CACHE_JSON="$projects_json"

    local folders_tmp
    folders_tmp=$(mktemp -t n8n-folders-XXXXXXXX.json)
    printf '[]' > "$folders_tmp"

    local found_any="false"
    local saw_not_found="false"

    while IFS= read -r project_id; do
        [[ -z "$project_id" ]] && continue

        local project_name
        project_name=$(printf '%s' "$projects_json" | jq -r --arg pid "$project_id" '
            (if type == "array" then . else (.data // []) end)
            | map(select((.id // "") == $pid))
            | first
            | .name // "Personal"
        ' 2>/dev/null || echo "Personal")

        local folder_response
        if ! folder_response=$(n8n_api_request "GET" "/projects/$project_id/folders?skip=0&take=1000"); then
            if [[ "${N8N_API_LAST_STATUS:-}" == "404" ]]; then
                saw_not_found="true"
            else
                local status="${N8N_API_LAST_STATUS:-unknown}"
                local category="${N8N_API_LAST_ERROR_CATEGORY:-}"
                if [[ "$category" == "license" ]]; then
                    local message=""
                    if [[ -n "${N8N_API_LAST_BODY:-}" ]]; then
                        message=$(printf '%s' "${N8N_API_LAST_BODY}" | jq -r '.message // empty' 2>/dev/null || printf '')
                    fi
                    if [[ -n "$message" ]]; then
                        log INFO "Skipping folder discovery for project $project_id due to license restriction (HTTP $status, message: $message)"
                    else
                        log INFO "Skipping folder discovery for project $project_id due to license restriction (HTTP $status)"
                    fi
                else
                    log WARN "Failed to fetch folders for project $project_id (HTTP $status)"
                fi
            fi
            continue
        fi

        found_any="true"

        local normalized
        if ! normalized=$(printf '%s' "$folder_response" | jq -c --arg pid "$project_id" --arg pname "$project_name" '
            (if type == "array" then . else (.data // []) end)
            | map({
                id: ((.id // "") | tostring),
                name: (.name // "Folder"),
                parentFolderId: ((.parentFolderId // (.parentFolder.id // "")) | tostring),
                projectId: ($pid // ""),
                projectName: ($pname // "Personal")
            })
        ' 2>/dev/null); then
            log WARN "Unable to parse folder list for project $project_id"
            continue
        fi

        local normalized_tmp
        normalized_tmp=$(mktemp -t n8n-folder-normalized-XXXXXXXX.json)
        printf '%s' "$normalized" > "$normalized_tmp"
        if ! jq -s -c '.[0] + (.[1] // [])' "$folders_tmp" "$normalized_tmp" > "${folders_tmp}.tmp"; then
            log WARN "Failed to merge folder list for project $project_id"
            rm -f "$normalized_tmp" "${folders_tmp}.tmp"
            continue
        fi
        mv "${folders_tmp}.tmp" "$folders_tmp"
        rm -f "$normalized_tmp"
    done < <(printf '%s' "$projects_json" | jq -r '
        if type == "array" then .[] else (.data // [])[] end
        | .id // empty
    ')

    if [[ "$found_any" != "true" && "$saw_not_found" == "true" ]]; then
        rm -f "$folders_tmp"
        if ! n8n_api_request "GET" "/folders?skip=0&take=1000"; then
            return 1
        fi
        return 0
    fi

    local combined
    combined=$(cat "$folders_tmp")
    rm -f "$folders_tmp"
    printf '%s' "$combined"
    return 0
}

n8n_api_get_workflows() {
    local include_archived="${1:-false}"
    local base_query="/workflows?includeScopes=true&includeFolders=true&sortBy=updatedAt%3Adesc"
    local filter_query=""
    if [[ "${include_archived,,}" != "true" ]]; then
        filter_query="&filter=%7B%22isArchived%22%3Afalse%7D"
    fi

    local skip=0
    local take=50
    local all_data="[]"
    local total_expected=-1
    
    while true; do
        local endpoint="${base_query}&skip=${skip}&take=${take}${filter_query}"
        local page_response=""
        
        if ! page_response=$(n8n_api_request "GET" "$endpoint"); then
            return 1
        fi
        
        if (( total_expected == -1 )); then
             total_expected=$(jq -r '.count // -1' <<<"$page_response")
        fi

        local page_data
        page_data=$(jq -c '.data // []' <<<"$page_response")
        local page_length
        page_length=$(jq 'length' <<<"$page_data")
        
        if (( page_length == 0 )); then
            break
        fi
        
        # Merge data
        if [[ "$all_data" == "[]" ]]; then
            all_data="$page_data"
        else
            # Efficiently append arrays
            all_data="${all_data%]}"
            all_data="${all_data},${page_data:1}"
        fi
        
        local current_count
        current_count=$(jq 'length' <<<"$all_data")
        
        if (( total_expected != -1 && current_count >= total_expected )); then
            break
        fi
        
        skip=$((skip + take))
        
        # If we don't know total count, fallback to checking if page is full
        if (( total_expected == -1 && page_length < take )); then
            break
        fi
        
        # Safety break
        if (( skip > 10000 )); then
            log WARN "n8n_api_get_workflows: exceeded 10000 items limit, stopping pagination."
            break
        fi
    done
    
    # Construct final response structure matching API
    # We use printf to avoid argument list too long errors with jq --argjson
    printf '{"data":%s,"count":%d}' "$all_data" "$(jq 'length' <<<"$all_data")"
}

n8n_api_get_workflow() {
    local workflow_id="$1"

    if [[ -z "$workflow_id" ]]; then
        log WARN "Workflow id is required when requesting workflow details."
        return 1
    fi

    if ! n8n_api_request "GET" "/workflows/${workflow_id}"; then
        return 1
    fi

    return 0
}

n8n_api_archive_workflow() {
    local workflow_id="$1"

    if [[ -z "$workflow_id" ]]; then
        log WARN "Skipping archive request - workflow id not provided."
        return 1
    fi

    local archive_response=""
    if archive_response=$(n8n_api_request "POST" "/workflows/${workflow_id}/archive"); then
        if [[ "$verbose" == "true" && -n "$archive_response" ]]; then
            local preview suffix response_len
            preview=$(printf '%s' "$archive_response" | tr '\n' ' ' | head -c 200)
            response_len=$(printf '%s' "$archive_response" | wc -c | tr -d ' \n')
            suffix=""
            if [[ ${response_len:-0} -gt 200 ]]; then
                suffix="…"
            fi
            log DEBUG "Archive response for workflow $workflow_id: ${preview}${suffix}"
        fi
        return 0
    fi

    local last_status="${N8N_API_LAST_STATUS:-}"
    if [[ "$last_status" == "409" ]]; then
        log INFO "Workflow $workflow_id already archived"
        return 0
    fi

    if [[ "$last_status" == "404" ]]; then
        log DEBUG "Workflow $workflow_id not found when archiving; assuming it was already removed."
        return 0
    fi

    local payload
    payload=$(jq -n '{isArchived: true}')
    if n8n_api_request "PATCH" "/workflows/${workflow_id}" "$payload"; then
        return 0
    fi

    last_status="${N8N_API_LAST_STATUS:-}"
    if [[ "$last_status" == "409" ]]; then
        log INFO "Workflow $workflow_id already archived"
        return 0
    fi

    if [[ "$last_status" == "404" ]]; then
        log DEBUG "Workflow $workflow_id missing when patching archive; treating as already removed."
        return 0
    fi

    log WARN "Failed to archive workflow $workflow_id via n8n API (HTTP ${last_status:-unknown})."
    return 1
}

n8n_api_create_folder() {
    local name="$1"
    local project_id="$2"
    local parent_id="${3:-}"

    if [[ "$parent_id" == "null" ]]; then
        parent_id=""
    fi

    if [[ -z "$project_id" ]]; then
        log ERROR "Project ID required when creating n8n folder '$name'"
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg projectId "$project_id" \
        --arg parentId "${parent_id:-}" \
        '{
            name: $name,
            projectId: $projectId
        } + (if ($parentId // "") == "" then {} else {parentFolderId: $parentId} end)')

    n8n_api_request "POST" "/projects/$project_id/folders" "$payload"
}

n8n_api_update_folder_parent() {
    local project_id="$1"
    local folder_id="$2"
    local parent_id="${3:-}"

    if [[ "$parent_id" == "null" ]]; then
        parent_id=""
    fi

    if [[ -z "$project_id" ]]; then
        log ERROR "Project ID required when updating folder $folder_id"
        return 1
    fi

    if [[ -z "$folder_id" ]]; then
        log ERROR "Folder ID required when updating project $project_id"
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg parentId "${parent_id:-}" \
        '(if ($parentId // "") == "" then {} else {parentFolderId: $parentId} end)')

    n8n_api_request "PATCH" "/projects/$project_id/folders/$folder_id" "$payload"
}

n8n_api_update_workflow_assignment() {
    local workflow_id="$1"
    local project_id="$2"
    local folder_id="${3:-}"
    local version_id="${4:-}"
    local version_mode="${5:-auto}"

    if [[ -z "$workflow_id" ]]; then
        log WARN "Skipping workflow reassignment - missing workflow id"
        return 1
    fi

    if [[ -z "$project_id" ]]; then
        log WARN "Skipping workflow $workflow_id assignment update - missing project id"
        return 1
    fi

    local normalized_folder_id="${folder_id:-}"
    if [[ "$normalized_folder_id" == "null" ]]; then
        normalized_folder_id=""
    fi

    local include_folder="false"
    if [[ -n "$normalized_folder_id" ]]; then
        include_folder="true"
    else
        normalized_folder_id="$N8N_PROJECT_ROOT_ID"
        include_folder="true"
    fi

    local resolved_version_mode="$version_mode"
    if [[ "$resolved_version_mode" != "string" && "$resolved_version_mode" != "null" ]]; then
        if [[ -z "$version_id" || "$version_id" == "null" ]]; then
            resolved_version_mode="null"
        else
            resolved_version_mode="string"
        fi
    elif [[ "$resolved_version_mode" == "string" && ( -z "$version_id" || "$version_id" == "null" ) ]]; then
        resolved_version_mode="null"
    fi

    local jq_args=(-n --arg projectId "$project_id" --arg includeFolder "$include_folder" --arg folderId "$normalized_folder_id" --arg versionMode "$resolved_version_mode" --arg versionId "${version_id:-}")

    local payload
    payload=$(jq "${jq_args[@]}" '
        {
            homeProject: {
                id: $projectId
            }
        }
        + (if $includeFolder == "true" then { parentFolderId: (if ($folderId // "") == "" then null else $folderId end) } else {} end)
        + (if $versionMode == "string" then { versionId: $versionId }
           elif $versionMode == "null" then { versionId: null }
           else {} end)
    ')

    if [[ "$resolved_version_mode" == "null" && "$verbose" == "true" ]]; then
        log DEBUG "Updating workflow $workflow_id with null versionId payload."
    fi

    local update_response
    if ! update_response=$(n8n_api_request "PATCH" "/workflows/$workflow_id" "$payload"); then
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        local preview response_len suffix
        preview=$(printf '%s' "$update_response" | tr '\n' ' ' | head -c 200)
        response_len=$(printf '%s' "$update_response" | wc -c | tr -d ' \n')
        suffix=""
        if [[ ${response_len:-0} -gt 200 ]]; then
            suffix="…"
        fi
        if [[ -n "$preview" ]]; then
            log DEBUG "Workflow $workflow_id assignment update response preview: ${preview}${suffix}"
        fi
    fi

    return 0
}

archive_workflow() {
    local workflow_id="$1"
    local quiet="${2:-false}"

    if [[ -z "$workflow_id" ]]; then
        log ERROR "archive_workflow requires workflow_id"
        return 1
    fi

    if [[ -z "${N8N_API_AUTH_MODE:-}" ]]; then
        log ERROR "n8n API authentication not initialized. Call prepare_n8n_api_auth first."
        return 1
    fi

    log DEBUG "Archiving workflow $workflow_id"

    N8N_API_SUPPRESS_ERRORS="true"
    if ! n8n_api_request "POST" "/workflows/$workflow_id/archive" "{}" >/dev/null; then
        local status="${N8N_API_LAST_STATUS:-}"
        local body="${N8N_API_LAST_BODY:-}"
        local message=""
        if [[ -n "$body" ]]; then
            message=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null || printf '')
        fi

        if [[ "$status" == "409" ]]; then
            log INFO "Workflow $workflow_id already archived"
        elif [[ "$status" == "404" ]]; then
            log DEBUG "Workflow $workflow_id not found when archiving; assuming it was already removed."
            return 0
        elif [[ "$status" == "400" && "$message" == *"already archived"* ]]; then
            log INFO "Workflow $workflow_id already archived"
            return 0
        else
            log ERROR "Failed to archive workflow $workflow_id"
            return 1
        fi
    fi

    local attempt
    for attempt in 1 2 3 4 5; do
        local archive_check
        N8N_API_SUPPRESS_ERRORS="true"
        if archive_check=$(n8n_api_request "GET" "/workflows/$workflow_id" "" 2>/dev/null); then
            local archived_flag
            archived_flag=$(printf '%s' "$archive_check" | jq -r '(.data.isArchived // .isArchived // false) | tostring' 2>/dev/null || printf 'false')
            if [[ "${archived_flag,,}" == "true" ]]; then
                if [[ "$quiet" == "true" ]]; then
                    log DEBUG "Workflow $workflow_id archived successfully"
                else
                    log INFO "Workflow $workflow_id archived successfully"
                fi
                return 0
            fi
        else
            local verify_status="${N8N_API_LAST_STATUS:-}"
            if [[ "$verify_status" == "404" ]]; then
                log DEBUG "Workflow $workflow_id missing during archive verification; treating as archived."
                return 0
            fi
            log DEBUG "Unable to verify archive state for workflow $workflow_id (attempt $attempt)"
        fi

        sleep 1
    done

    log ERROR "Archive request acknowledged but workflow $workflow_id still reports isArchived=false"
    return 1
}

delete_workflow() {
    local workflow_id="$1"
    local skip_archive="${2:-false}"
    local quiet="${3:-false}"

    if [[ -z "$workflow_id" ]]; then
        log ERROR "delete_workflow requires workflow_id"
        return 1
    fi

    if [[ -z "${N8N_API_AUTH_MODE:-}" ]]; then
        log ERROR "n8n API authentication not initialized. Call prepare_n8n_api_auth first."
        return 1
    fi

    log DEBUG "Deleting workflow $workflow_id"

    local archive_attempted="$skip_archive"
    if [[ "$skip_archive" != "true" ]]; then
        if archive_workflow "$workflow_id" true; then
            archive_attempted="true"
        else
            log DEBUG "Pre-delete archive for workflow $workflow_id did not complete; deletion will retry if needed"
        fi
    fi
    local max_attempts=3
    local attempt=1
    local delay_seconds=2

    while (( attempt <= max_attempts )); do
        if n8n_api_request "DELETE" "/workflows/$workflow_id" "{}" >/dev/null; then
            if [[ "$quiet" == "true" ]]; then
                log DEBUG "Deleted workflow $workflow_id"
            else
                log INFO "Deleted workflow $workflow_id"
            fi
            return 0
        fi

        local status="${N8N_API_LAST_STATUS:-}"
        local last_body="${N8N_API_LAST_BODY:-}"

        if [[ "$status" == "404" ]]; then
            log INFO "Workflow $workflow_id already absent during delete (HTTP 404); treating as success"
            return 0
        fi

        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Delete workflow $workflow_id attempt $attempt failed with status='${status:-}'"
        fi

        if [[ "$status" == "400" && "$archive_attempted" != "true" ]]; then
            local message=""
            if [[ -n "$last_body" ]]; then
                message=$(printf '%s' "$last_body" | jq -r '.message // empty' 2>/dev/null || printf '')
            fi
            if [[ -z "$message" ]]; then
                message="${last_body:-}"
            fi

            if [[ "$message" == *"must be archived"* ]]; then
                log DEBUG "Workflow $workflow_id requires archival before deletion"
                if archive_workflow "$workflow_id" true; then
                    archive_attempted="true"
                    continue
                fi
                archive_attempted="true"
                log WARN "Archive attempt for workflow $workflow_id prior to deletion failed"
            fi
        fi

        if (( attempt < max_attempts )); then
            sleep "$delay_seconds"
        fi
        attempt=$((attempt + 1))
    done

    log ERROR "Failed to delete workflow $workflow_id"
    return 1
}

folder_exists() {
    local folder_id="$1"
    local project_id="${2:-}"

    if [[ -z "$folder_id" ]]; then
        return 2
    fi

    local status
    if [[ -n "$project_id" ]]; then
        N8N_API_EXPECTED_STATUS="404"
        if n8n_api_request "GET" "/projects/$project_id/folders/$folder_id" "" >/dev/null 2>&1; then
            return 0
        fi
        status="${N8N_API_LAST_STATUS:-}"
        if [[ "$status" != "404" ]]; then
            return 2
        fi
    fi

    N8N_API_EXPECTED_STATUS="404"
    if n8n_api_request "GET" "/folders/$folder_id" "" >/dev/null 2>&1; then
        return 0
    fi

    status="${N8N_API_LAST_STATUS:-}"
    if [[ "$status" == "404" ]]; then
        return 1
    fi

    return 2
}

delete_folder() {
    local folder_id="$1"
    local project_id="${2:-}"

    if [[ -z "$folder_id" ]]; then
        log ERROR "delete_folder requires folder_id"
        return 1
    fi

    if [[ -z "${N8N_API_AUTH_MODE:-}" ]]; then
        log ERROR "n8n API authentication not initialized. Call prepare_n8n_api_auth first."
        return 1
    fi

    log DEBUG "Deleting folder $folder_id (project: ${project_id:-unknown})"

    local primary_endpoint="/folders/$folder_id"
    if [[ -n "$project_id" ]]; then
        primary_endpoint="/projects/$project_id/folders/$folder_id"
    fi

    if n8n_api_request "DELETE" "$primary_endpoint" "" >/dev/null 2>&1; then
        log INFO "Folder $folder_id deleted successfully"
        return 0
    fi

    local status="${N8N_API_LAST_STATUS:-}"
    if [[ -n "$project_id" && "$status" == "404" ]]; then
        log WARN "Folder delete via project endpoint failed (404); retrying legacy endpoint."
        if n8n_api_request "DELETE" "/folders/$folder_id" "" >/dev/null 2>&1; then
            log INFO "Folder $folder_id deleted successfully (legacy endpoint)"
            return 0
        fi
        status="${N8N_API_LAST_STATUS:-}"
    fi

    if [[ "$status" == "404" ]]; then
        log DEBUG "Folder $folder_id already absent (HTTP 404); treating as success."
        return 0
    fi
    local response_body="${N8N_API_LAST_BODY:-}"
    if [[ -n "$status" ]]; then
        log ERROR "Failed to delete folder $folder_id (HTTP $status)"
    else
        log ERROR "Failed to delete folder $folder_id"
    fi
    if [[ -n "$response_body" ]]; then
        local preview
        preview="$(printf '%s' "$response_body" | tr '\n' ' ' | head -c 200)"
        if [[ ${#response_body} -gt 200 ]]; then
            preview+="…"
        fi
        log DEBUG "n8n folder delete response: $preview"
    fi

    folder_exists "$folder_id" "$project_id"
    local existence_code=$?
    if (( existence_code == 1 )); then
        log INFO "Folder $folder_id is absent after delete attempt; treating as success."
        return 0
    elif (( existence_code == 2 )); then
        local follow_status="${N8N_API_LAST_STATUS:-unknown}"
        log WARN "Unable to verify folder $folder_id removal (HTTP $follow_status)"
    fi

    return 1
}

list_workflows() {
    local include_archived="${1:-false}"
    
    if [[ -z "${N8N_API_AUTH_MODE:-}" ]]; then
        log ERROR "n8n API authentication not initialized. Call prepare_n8n_api_auth first."
        return 1
    fi
    
    # Build filter based on whether to include archived workflows
    local filter=""
    if [[ "$include_archived" != "true" ]]; then
        filter="&filter=%7B%22isArchived%22%3Afalse%7D"
    fi
    
    local endpoint="/workflows?includeScopes=true&includeFolders=true${filter}&skip=0&take=1000&sortBy=updatedAt%3Adesc"
    
    log DEBUG "Listing workflows (include_archived=$include_archived)"
    
    # Use unified API request
    local response
    if ! response=$(n8n_api_request "GET" "$endpoint" ""); then
        log ERROR "Failed to list workflows"
        return 1
    fi
    
    log DEBUG "Listed workflows successfully"
    echo "$response"
    return 0
}
