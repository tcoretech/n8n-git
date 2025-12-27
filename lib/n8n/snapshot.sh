#!/usr/bin/env bash
# =========================================================
# lib/n8n/snapshot.sh - capture n8n workspace snapshot metadata
# =========================================================
# Provides reusable helpers for collecting and caching workspace
# workflow/folder structure snapshots via the n8n REST API.

if [[ -n "${LIB_N8N_SNAPSHOT_LOADED:-}" ]]; then
  return 0
fi
LIB_N8N_SNAPSHOT_LOADED=true

set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck source=lib/n8n/endpoints.sh
source "${BASH_SOURCE[0]%/*}/endpoints.sh"

build_folder_chain_json() {
    local start_id="${1:-}"
    local include_self="${2:-false}"
    declare -n __names_ref="$3"
    declare -n __parent_ref="$4"
    local __chain_ref="$5"
    local __path_ref="$6"

    local -a ancestry=()
    local current="$start_id"
    local guard=0

    while [[ -n "$current" ]]; do
        if [[ "$include_self" == "true" || "$current" != "$start_id" ]]; then
            ancestry+=("$current")
        fi

        local next_parent="${__parent_ref[$current]:-}"
        if [[ -z "$next_parent" || "$next_parent" == "$current" ]]; then
            break
        fi

        current="$next_parent"
        guard=$((guard + 1))
        if (( guard > 128 )); then
            log WARN "Detected potential folder hierarchy loop while resolving chain for ${start_id:-unknown}"
            break
        fi
    done

    local -a chain_entries=()
    local -a path_segments=()

    for (( idx=${#ancestry[@]}-1; idx>=0; idx-- )); do
        local folder_id="${ancestry[idx]}"
        [[ -z "$folder_id" ]] && continue

        local folder_name="${__names_ref[$folder_id]:-}"
        if [[ -z "$folder_name" || "$folder_name" == "null" ]]; then
            continue
        fi

        path_segments+=("$folder_name")

        local folder_path=""
        if ((${#path_segments[@]} > 0)); then
            local IFS='/'
            folder_path="${path_segments[*]}"
        fi

        local entry_json
        if ! entry_json=$(jq -n -c --arg id "$folder_id" --arg name "$folder_name" --arg path "$folder_path" '{id:$id,name:$name,path:$path}'); then
            continue
        fi

        chain_entries+=("$entry_json")
    done

    local chain_json="[]"
    if ((${#chain_entries[@]} > 0)); then
        chain_json="$(printf '%s\n' "${chain_entries[@]}" | jq -s '.')"
    fi

    local relative_path=""
    if ((${#path_segments[@]} > 0)); then
        local IFS='/'
        relative_path="${path_segments[*]}"
    fi

    printf -v "$__chain_ref" '%s' "$chain_json"
    if [[ -n "$__path_ref" ]]; then
        printf -v "$__path_ref" '%s' "$relative_path"
    fi
}

get_workflow_folder_mapping() {
    local container_id="$1"
    local container_credentials_path="${2:-}"
    local result_ref="${3:-}"

    if [[ -z "${n8n_base_url:-}" ]]; then
        log ERROR "n8n API URL not configured. Please set N8N_BASE_URL"
        return 1
    fi

    local projects_response=""
    local workflows_response=""
    local saved_api_key="${n8n_api_key:-}"
    local attempted_session=false

    while true; do
        if $attempted_session; then
            n8n_api_key=""
        else
            n8n_api_key="$saved_api_key"
        fi

        N8N_API_AUTH_MODE=""
        if ! prepare_n8n_api_auth "$container_id" "$container_credentials_path"; then
            if ! $attempted_session; then
                attempted_session=true
                continue
            fi
            log ERROR "Unable to prepare n8n API authentication for workflow mapping"
            n8n_api_key="$saved_api_key"
            return 1
        fi

        local projects_capture=""
        projects_capture=$(mktemp /tmp/n8n-projects-response-XXXXXXXX)
        if ! $attempted_session && [[ -n "${n8n_api_key:-}" ]]; then
            N8N_API_EXPECTED_STATUS="401"
        fi
        if ! n8n_api_get_projects >"$projects_capture"; then
            local status="${N8N_API_LAST_STATUS:-}"
            rm -f "$projects_capture"
            if [[ "$status" == "401" && $attempted_session == false ]]; then
                log INFO "n8n API key rejected for project listing; retrying with session credential"
                finalize_n8n_api_auth
                attempted_session=true
                continue
            fi
            finalize_n8n_api_auth
            n8n_api_key="$saved_api_key"
            return 1
        fi

        projects_response="$(<"$projects_capture")"
        rm -f "$projects_capture"

        local workflows_capture=""
        workflows_capture=$(mktemp /tmp/n8n-workflows-response-XXXXXXXX)
        if ! $attempted_session && [[ -n "${n8n_api_key:-}" ]]; then
            N8N_API_EXPECTED_STATUS="401"
        fi
        if ! n8n_api_get_workflows true >"$workflows_capture"; then
            local status="${N8N_API_LAST_STATUS:-}"
            rm -f "$workflows_capture"
            if [[ "$status" == "401" && $attempted_session == false ]]; then
                log INFO "n8n API key rejected for workflow listing; retrying with session credential"
                finalize_n8n_api_auth
                attempted_session=true
                continue
            fi
            finalize_n8n_api_auth
            n8n_api_key="$saved_api_key"
            return 1
        fi

        workflows_response="$(<"$workflows_capture")"
        rm -f "$workflows_capture"

        break
    done

    n8n_api_key="$saved_api_key"

    projects_response="$(printf '%s' "$projects_response" | tr -d '\r')"
    workflows_response="$(printf '%s' "$workflows_response" | tr -d '\r')"

    log DEBUG "get_workflow_folder_mapping verbose flag: ${verbose:-unset}"

    if [[ "$verbose" == "true" ]]; then
        local projects_preview
        local workflows_preview
        local projects_suffix=""
        local workflows_suffix=""
        projects_preview="$(printf '%s' "$projects_response" | tr '\n' ' ' | head -c 200)"
        workflows_preview="$(printf '%s' "$workflows_response" | tr '\n' ' ' | head -c 200)"
        if (( ${#projects_response} > 200 )); then
            projects_suffix="…"
        fi
        if (( ${#workflows_response} > 200 )); then
            workflows_suffix="…"
        fi
        log DEBUG "Projects response preview: ${projects_preview}${projects_suffix}"
        log DEBUG "Workflows response preview: ${workflows_preview}${workflows_suffix}"
    fi

    if [[ "$verbose" == "true" ]]; then
        log DEBUG "Validating projects response JSON"
    fi

    if ! printf '%s' "$projects_response" | jq empty >/dev/null 2>&1; then
        local sample
        sample="$(printf '%s' "$projects_response" | tr '\n' ' ' | head -c 200)"
        log ERROR "Projects response is not valid JSON (sample: ${sample}...)"
        finalize_n8n_api_auth
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        log DEBUG "Validating workflows response JSON"
    fi

    if ! printf '%s' "$workflows_response" | jq empty >/dev/null 2>&1; then
        local sample
        sample="$(printf '%s' "$workflows_response" | tr '\n' ' ' | head -c 200)"
        log ERROR "Workflows response is not valid JSON (sample: ${sample}...)"
        finalize_n8n_api_auth
        return 1
    fi

    local projects_tmp workflows_tmp
    projects_tmp=$(mktemp /tmp/n8n-projects-XXXXXXXX)
    workflows_tmp=$(mktemp /tmp/n8n-workflows-XXXXXXXX)
    printf '%s' "$projects_response" > "$projects_tmp"
    printf '%s' "$workflows_response" > "$workflows_tmp"

    trap 'rm -f "$projects_tmp" "$workflows_tmp"; trap - RETURN' RETURN

    declare -A project_name_by_id=()
    local default_project_id=""
    local personal_project_id=""
    local -a project_entries=()

    local project_rows
    if ! project_rows=$(jq -r --arg personal "$PERSONAL_PROJECT_TOKEN" '
        (if type == "array" then . else (.data // []) end)
        | map([
            ((.id // "") | tostring),
            (.name // $personal),
            (.type // "")
          ] | @tsv)
        | .[]
    ' "$projects_tmp"); then
        log ERROR "Unable to parse projects while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    if [[ -n "$project_rows" ]]; then
        while IFS=$'\t' read -r raw_id raw_name raw_type; do
            local pid
            pid="$(trim_identifier_value "$raw_id")"
            [[ -z "$pid" ]] && continue

            local pname="${raw_name:-$PERSONAL_PROJECT_TOKEN}"
            if [[ -z "$pname" || "$pname" == "null" ]]; then
                pname="$PERSONAL_PROJECT_TOKEN"
            fi

            project_name_by_id["$pid"]="$pname"

            if [[ -z "$default_project_id" ]]; then
                default_project_id="$pid"
            fi
            if [[ "$raw_type" == "personal" ]]; then
                personal_project_id="$pid"
                remember_personal_project_name "$pname"
                if [[ -z "${project_name:-}" || "$project_name" == "$PERSONAL_PROJECT_TOKEN" || "$project_name" == "%PERSONAL_PROJECT%" || "${project_name,,}" == "personal" ]]; then
                    project_name="$pname"
                fi
                if [[ -z "${N8N_PROJECT:-}" || "$N8N_PROJECT" == "$PERSONAL_PROJECT_TOKEN" || "$N8N_PROJECT" == "%PERSONAL_PROJECT%" || "${N8N_PROJECT,,}" == "personal" ]]; then
                    N8N_PROJECT="$pname"
                fi
            fi

            local project_json
            if project_json=$(jq -n -c \
                --arg id "$pid" \
                --arg name "$pname" \
                --arg type "$raw_type" \
                '{id:$id,name:$name,type:($type // "")}'); then
                project_entries+=("$project_json")
            fi
        done <<<"$project_rows"
    fi

    if [[ -z "$default_project_id" ]]; then
        default_project_id="personal-default"
        local default_name="$PERSONAL_PROJECT_TOKEN"
        remember_personal_project_name "$default_name"
        project_name_by_id["$default_project_id"]="$default_name"
        local fallback_project_json
        if fallback_project_json=$(jq -n -c \
            --arg id "$default_project_id" \
            --arg name "$default_name" \
            '{id:$id,name:$name,type:"personal"}'); then
            project_entries+=("$fallback_project_json")
        fi
    fi

    if [[ -n "$personal_project_id" ]]; then
        default_project_id="$personal_project_id"
    fi

    declare -A folder_name_by_id=()
    declare -A folder_parent_by_id=()
    local -a folder_entries=()

    local folder_rows
    if ! folder_rows=$(jq -r '
        (if type == "array" then . else (.data // []) end)
        | map(select(.resource == "folder"))
        | map([
            ((.id // "") | tostring),
            (.name // "Folder"),
            ((.parentFolderId // (.parentFolder.id // "")) | tostring)
          ] | @tsv)
        | .[]
    ' "$workflows_tmp"); then
        log ERROR "Unable to parse folder entries while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    if [[ -n "$folder_rows" ]]; then
        while IFS=$'\t' read -r raw_id raw_name raw_parent; do
            local fid
            fid="$(trim_identifier_value "$raw_id")"
            [[ -z "$fid" ]] && continue

            local fname
            fname="$(trim_identifier_value "$raw_name")"
            [[ -z "$fname" ]] && continue

            local parent_id
            parent_id="$(trim_identifier_value "$raw_parent")"

            folder_name_by_id["$fid"]="$fname"
            folder_parent_by_id["$fid"]="$parent_id"
        done <<<"$folder_rows"
    fi

    local folder_node_rows
    if ! folder_node_rows=$(jq -r '
        (if type == "array" then . else (.data // []) end)
        | map(select(.resource == "folder") | @base64)
        | .[]?
    ' "$workflows_tmp"); then
        log ERROR "Unable to parse folder node entries while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    if [[ -n "$folder_node_rows" ]]; then
        while IFS= read -r folder_row; do
            [[ -z "$folder_row" ]] && continue
            local decoded_folder
            decoded_folder="$(printf '%s' "$folder_row" | base64 --decode)"

            local fid
            fid="$(trim_identifier_value "$(jq -r '.id // ""' <<<"$decoded_folder")")"
            [[ -z "$fid" ]] && continue

            local fname
            fname=$(jq -r '.name // "Folder"' <<<"$decoded_folder")
            [[ -z "$fname" || "$fname" == "null" ]] && fname="Folder"

            local f_project_id
            f_project_id="$(trim_identifier_value "$(jq -r '(.homeProject.id // .homeProjectId // "") | tostring' <<<"$decoded_folder")")"
            if [[ -z "$f_project_id" ]]; then
                f_project_id="$default_project_id"
            fi
            local f_project_name="${project_name_by_id[$f_project_id]:-${project_name_by_id[$default_project_id]}}"
            if [[ -z "$f_project_name" ]]; then
                f_project_name="${project_name_by_id[$default_project_id]}"
            fi
            if [[ -z "$f_project_name" ]]; then
                f_project_name="$PERSONAL_PROJECT_TOKEN"
            fi

            local parent_id
            parent_id="$(trim_identifier_value "$(jq -r '(.parentFolderId // .parentFolder.id // "") | tostring' <<<"$decoded_folder")")"

            local folder_chain_json="[]"
            local derived_relative_path=""
            build_folder_chain_json "$fid" "true" folder_name_by_id folder_parent_by_id folder_chain_json derived_relative_path
            derived_relative_path="${derived_relative_path#/}"
            derived_relative_path="${derived_relative_path%/}"

            local relative_path="$derived_relative_path"

            local folder_entry_json
            if ! folder_entry_json=$(jq -n -c \
                --arg id "$fid" \
                --arg name "$fname" \
                --arg projectId "$f_project_id" \
                --arg projectName "$f_project_name" \
                --arg pathValue "$derived_relative_path" \
                --arg parentId "$parent_id" \
                '{
                    id: (if $id == "" then null else $id end),
                    name: $name,
                    project: {
                        id: (if $projectId == "" then null else $projectId end),
                        name: $projectName
                    },
                    path: $pathValue,
                    relativePath: $pathValue,
                    parentId: (if $parentId == "" then null else $parentId end)
                }'); then
                continue
            fi
            folder_entries+=("$folder_entry_json")
        done <<<"$folder_node_rows"
    fi

    local workflow_rows
    if ! workflow_rows=$(jq -r '
        (if type == "array" then . else (.data // []) end)
        | map(select((.resource // "") != "folder") | @base64)
        | .[]?
    ' "$workflows_tmp"); then
        log ERROR "Unable to parse workflows while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    if [[ "${verbose:-false}" == "true" ]]; then
        local wf_row_count=0
        if [[ -n "$workflow_rows" ]]; then
            wf_row_count=$(echo "$workflow_rows" | wc -l)
        fi
        log DEBUG "get_workflow_folder_mapping: found $wf_row_count workflow rows"
        local folder_row_count=0
        if [[ -n "$folder_rows" ]]; then
            folder_row_count=$(echo "$folder_rows" | wc -l)
        fi
        log DEBUG "get_workflow_folder_mapping: found $folder_row_count folder rows"
    fi

    local workflow_entries_file
    workflow_entries_file=$(mktemp /tmp/n8n-workflow-entries-XXXXXXXX)
    
    if [[ -n "$workflow_rows" ]]; then
        while IFS= read -r workflow_row; do
            [[ -z "$workflow_row" ]] && continue
            local decoded_row
            decoded_row="$(printf '%s' "$workflow_row" | base64 --decode)"

            local wid
            wid="$(trim_identifier_value "$(jq -r '.id // ""' <<<"$decoded_row")")"
            [[ -z "$wid" ]] && continue

            local wname
            wname="$(jq -r '.name // "Unnamed Workflow"' <<<"$decoded_row")"
            [[ -z "$wname" || "$wname" == "null" ]] && wname="Unnamed Workflow"

            local project_id
            project_id="$(trim_identifier_value "$(jq -r '(.homeProject.id // .homeProjectId // "") | tostring' <<<"$decoded_row")")"
            if [[ -z "$project_id" ]]; then
                project_id="$default_project_id"
            fi
            local project_name="${project_name_by_id[$project_id]:-${project_name_by_id[$default_project_id]}}"
            if [[ -z "$project_name" ]]; then
                project_name="${project_name_by_id[$default_project_id]}"
            fi
            if [[ -z "$project_name" ]]; then
                project_name="$PERSONAL_PROJECT_TOKEN"
            fi

            local parent_id
            parent_id="$(trim_identifier_value "$(jq -r '(.parentFolderId // .parentFolder.id // "") | tostring' <<<"$decoded_row")")"
            if [[ -n "$parent_id" && -z "${folder_name_by_id[$parent_id]:-}" && -z "${folder_parent_by_id[$parent_id]:-}" ]]; then
                if [[ "${verbose:-false}" == "true" ]]; then
                    log DEBUG "Workflow $wid references unknown folder id '$parent_id'; treating as root assignment"
                fi
                parent_id=""
            fi

            local folder_chain_json="[]"
            local folder_relative=""
            build_folder_chain_json "$parent_id" "true" folder_name_by_id folder_parent_by_id folder_chain_json folder_relative

            local workflow_path="$project_name"
            if [[ -n "$folder_relative" ]]; then
                workflow_path+="/$folder_relative"
            fi

            local raw_updated_at
            raw_updated_at=$(jq -r '.updatedAt // ""' <<<"$decoded_row")
            local updated_at="${raw_updated_at:-}"
            local is_active="false"
            local raw_active
            raw_active=$(jq -r '(.active // false) | tostring' <<<"$decoded_row")
            if [[ "${raw_active,,}" =~ ^(true|1)$ ]]; then
                is_active="true"
            fi

            local workflow_json
            if ! workflow_json=$(jq -n -c \
                --arg id "$wid" \
                --arg name "$wname" \
                --arg projectId "$project_id" \
                --arg projectName "$project_name" \
                --arg path "$workflow_path" \
                --arg relativePath "$folder_relative" \
                --arg updatedAt "$updated_at" \
                --arg active "$is_active" \
                --argjson folders "$folder_chain_json" '{
                    id: $id,
                    name: $name,
                    project: {
                        id: (if $projectId == "" then null else $projectId end),
                        name: $projectName
                    },
                    folders: $folders,
                    path: $path,
                    folderPath: $relativePath,
                    relativePath: $relativePath,
                    updatedAt: (if ($updatedAt // "") == "" then null else $updatedAt end),
                    active: ($active == "true")
                }'); then
                log WARN "Failed to assemble workflow entry for ID $wid"
                continue
            fi

            echo "$workflow_json" >> "$workflow_entries_file"
        done <<<"$workflow_rows"
    fi

    local workflows_json_file
    workflows_json_file=$(mktemp /tmp/n8n-workflows-final-XXXXXXXX)
    if [[ -s "$workflow_entries_file" ]]; then
        jq -s '.' "$workflow_entries_file" > "$workflows_json_file"
    else
        echo "[]" > "$workflows_json_file"
    fi
    rm -f "$workflow_entries_file"

    local folders_json_file
    folders_json_file=$(mktemp /tmp/n8n-folders-final-XXXXXXXX)
    if ((${#folder_entries[@]} > 0)); then
        printf '%s\n' "${folder_entries[@]}" | jq -s '.' > "$folders_json_file"
    else
        echo "[]" > "$folders_json_file"
    fi

    local projects_json_file
    projects_json_file=$(mktemp /tmp/n8n-projects-final-XXXXXXXX)
    if ((${#project_entries[@]} > 0)); then
        printf '%s\n' "${project_entries[@]}" | jq -s '.' > "$projects_json_file"
    else
        echo "[]" > "$projects_json_file"
    fi

    local default_project_name="${project_name_by_id[$default_project_id]:-$PERSONAL_PROJECT_TOKEN}"

    local selected_project_source="${project_name_source:-}"
    local selected_project_id="$default_project_id"
    local selected_project_name="$default_project_name"

    if [[ -n "${project_name:-}" ]]; then
        local normalized_target
        normalized_target="$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')"
        for pid in "${!project_name_by_id[@]}"; do
            local candidate_name="${project_name_by_id[$pid]}"
            [[ -z "$candidate_name" ]] && continue
            local candidate_name_normalized
            candidate_name_normalized="$(printf '%s' "$candidate_name" | tr '[:upper:]' '[:lower:]')"
            if [[ "$candidate_name_normalized" == "$normalized_target" ]]; then
                selected_project_id="$pid"
                selected_project_name="$candidate_name"
                break
            fi
        done
    fi

    if [[ -z "$selected_project_id" ]]; then
        selected_project_id="$default_project_id"
    fi

    if [[ -n "$selected_project_id" && -z "$selected_project_name" ]]; then
        selected_project_name="${project_name_by_id[$selected_project_id]:-$default_project_name}"
    fi

    if [[ -z "$selected_project_name" ]]; then
        selected_project_name="$default_project_name"
    fi

    local n8n_path_value="${n8n_path:-}"
    local n8n_path_source_value="${n8n_path_source:-}"

    local mapping_payload=""
    if ! mapping_payload=$(jq -n -c \
        --slurpfile workflows "$workflows_json_file" \
        --slurpfile folders "$folders_json_file" \
        --slurpfile projects "$projects_json_file" \
        --arg defaultId "$default_project_id" \
        --arg defaultName "$default_project_name" \
        --arg selectedId "$selected_project_id" \
        --arg selectedName "$selected_project_name" \
        --arg selectedSource "$selected_project_source" \
        --arg pathValue "$n8n_path_value" \
        --arg pathSource "$n8n_path_source_value" \
        '{
            fetchedAt: (now | todateiso8601),
            defaultProject: {
                id: ($defaultId // empty),
                name: ($defaultName // empty)
            },
            selectedProject: {
                id: ($selectedId // empty),
                name: ($selectedName // empty),
                source: ($selectedSource // empty)
            },
            projects: $projects[0],
            workflows: $workflows[0],
            workflowsById: ($workflows[0] | map({key: .id, value: .}) | from_entries),
            folders: $folders[0],
            foldersById: ($folders[0] | map(select(.id != null) | {key: .id, value: .}) | from_entries),
            filters: {
                n8nPath: ($pathValue // empty),
                n8nPathSource: ($pathSource // empty)
            }
        }'); then
        log ERROR "Failed to construct workflow mapping JSON"
        rm -f "$projects_tmp" "$workflows_tmp" "$workflows_json_file" "$folders_json_file" "$projects_json_file"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    rm -f "$projects_tmp" "$workflows_tmp" "$workflows_json_file" "$folders_json_file" "$projects_json_file"
    trap - RETURN

    finalize_n8n_api_auth

    if ! printf '%s' "$mapping_payload" | jq -e '.workflowsById | type == "object"' >/dev/null 2>&1; then
        log ERROR "Constructed mapping missing workflowsById object"
        local mapping_preview mapping_length
        mapping_preview=$(printf '%s' "$mapping_payload" | head -c 500)
        mapping_length=$(printf '%s' "$mapping_payload" | wc -c | tr -d ' \n')
        mapping_length=${mapping_length:-0}
        log DEBUG "Mapping preview (first 500 chars): ${mapping_preview}$( [ "$mapping_length" -gt 500 ] && echo '…')"
        return 1
    fi

    if [[ -n "$result_ref" ]]; then
        printf -v "$result_ref" '%s' "$mapping_payload"
    else
        printf '%s' "$mapping_payload"
    fi
    return 0
}

snapshot_normalize_scope_path() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\t'/}"
    raw="${raw//$'\n'/}"
    raw="$(printf '%s' "$raw" | sed 's#^/*##;s#/*$##')"
    printf '%s' "$raw"
}

snapshot_trim_path_prefix() {
    local path="${1:-}"
    local prefix="${2:-}"
    path="${path//$'\r'/}"
    path="${path//$'\t'/}"
    path="${path//$'\n'/}"
    path="$(printf '%s' "$path" | sed 's#^/*##;s#/*$##')"
    prefix="${prefix//$'\r'/}"
    prefix="${prefix//$'\t'/}"
    prefix="${prefix//$'\n'/}"
    prefix="$(printf '%s' "$prefix" | sed 's#^/*##;s#/*$##')"

    if [[ -z "$prefix" ]]; then
        printf '%s' "$path"
        return 0
    fi

    if [[ -z "$path" ]]; then
        printf ''
        return 0
    fi

    if [[ "$path" == "$prefix" ]]; then
        printf ''
        return 0
    fi

    if [[ "$path" == "$prefix"/* ]]; then
        printf '%s' "${path#"$prefix"/}"
        return 0
    fi

    printf '%s' "$path"
}

# Global cache for raw workflow mapping payloads (per container id)
declare -gA N8N_SNAPSHOT_MAPPING_CACHE=()

default_snapshot_cache_key() {
    local container_id="${1:-}"
    if [[ -n "$container_id" ]]; then
        printf '%s' "container::$container_id"
        return 0
    fi
    printf 'host'
}

snapshot_ify_path() {
    local raw="${1:-}"
    raw="${raw#/}"
    raw="${raw%/}"

    if [[ -z "$raw" ]]; then
        printf ''
        return 0
    fi

    # Normalize whitespace around segments but keep characters intact
    local cleaned
    cleaned="$(printf '%s' "$raw" | sed 's#//*#/#g' | sed 's#^/##;s#/$##')"
    printf '%s' "$cleaned"
}

snapshot_count_segments() {
    local value="${1:-}"
    value="${value#/}"
    value="${value%/}"
    if [[ -z "$value" ]]; then
        printf '0'
        return 0
    fi

    local IFS='/'
    read -r -a __parts <<<"$value"
    local count=0
    local part
    for part in "${__parts[@]}"; do
        [[ -z "$part" ]] && continue
        count=$((count + 1))
    done
    printf '%d' "$count"
}

snapshot_fetch_mapping() {
    local container_id="${1:-}"
    local cache_key
    cache_key="$(default_snapshot_cache_key "$container_id")"

    local mapping_json=""
    if ! get_workflow_folder_mapping "$container_id" "" mapping_json; then
        return 1
    fi

    N8N_SNAPSHOT_MAPPING_CACHE[$cache_key]="$mapping_json"
    printf '%s' "$mapping_json"
    return 0
}

snapshot_decode_workflow_field() {
    local payload="$1"
    local filter="$2"
    jq -r '
        def normalize_project:
            if (.project | type) == "array" then
                .project = (.project[0] // {})
            elif (.project == null) then
                .project = {}
            else
                .
            end;

        def normalize_folders:
            if (.folders | type) == "object" then
                .folders = []
            elif (.folders == null) then
                .folders = []
            else
                .
            end;

        ((normalize_project | normalize_folders) | '"$filter"') // ""
    ' <<<"$payload"
}

n8n_snapshot_collect() {
    local path_filter_raw="${1:-}"
    local project_filter_raw="${2:-}"
    local depth_filter="${3:-}"
    local result_ref="${4:-}"

    local mapping_json
    if ! mapping_json="$(snapshot_fetch_mapping "${container:-}")"; then
        log ERROR "Unable to collect workspace snapshot; workflow mapping fetch failed"
        return 1
    fi

    # Extract personal project name from mapping and update globals
    # This is necessary because snapshot_fetch_mapping runs in a subshell,
    # so variable updates inside it do not persist.
    local detected_personal_name
    detected_personal_name=$(jq -r '
        (.projects // []) 
        | map(select(.type == "personal")) 
        | first 
        | .name // empty
    ' <<<"$mapping_json")
    
    if [[ -n "$detected_personal_name" ]]; then
        remember_personal_project_name "$detected_personal_name"
    fi

    local scope_path_normalized
    scope_path_normalized="$(snapshot_normalize_scope_path "$path_filter_raw")"

    local scope_project_name=""
    if [[ -n "$project_filter_raw" ]]; then
        scope_project_name="$(trim_identifier_value "$project_filter_raw")"
    else
        scope_project_name="$(jq -r '.selectedProject.name // ""' <<<"$mapping_json")"
    fi

    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "n8n_snapshot_collect: scope_project_name='$scope_project_name', scope_path='$scope_path_normalized'"
        local wf_count
        wf_count=$(jq -r '.workflows | length' <<<"$mapping_json")
        log DEBUG "n8n_snapshot_collect: total workflows in mapping: $wf_count"
        if (( wf_count > 0 )); then
             local sample_wf
             sample_wf=$(jq -c '.workflows[0]' <<<"$mapping_json")
             log DEBUG "n8n_snapshot_collect: sample workflow: $sample_wf"
        fi
    fi

    local depth_limit=-1
    if [[ -n "$depth_filter" && "$depth_filter" =~ ^[0-9]+$ ]]; then
        depth_limit="$depth_filter"
    fi

    local filtered_snapshot
    if ! filtered_snapshot=$(printf '%s' "$mapping_json" | jq -c \
        --arg scopePath "$scope_path_normalized" \
        --arg scopeProject "$scope_project_name" \
        --argjson depth "$depth_limit" '
            def normalize_workflows:
                if (.workflows | type) == "array" then .workflows
                elif (.workflows | type) == "object" then [.workflows]
                else [] end;

            def normalize_folders:
                if (.folders | type) == "array" then .folders
                elif (.folders | type) == "object" then [.folders]
                else [] end;

            def normalize_path($value):
                ($value // "") | gsub("^/+";"") | gsub("/+$";"");

            def match_project($item):
                if $scopeProject == "" then true
                else ((($item.project.name // "") | ascii_downcase) == ($scopeProject | ascii_downcase))
                end;

            def match_path($item):
                if $scopePath == "" then true
                else
                    (normalize_path($item.relativePath) // normalize_path($item.folderPath)) as $rel |
                    if $rel == "" then false
                    elif $rel == $scopePath then true
                    else ($rel | startswith($scopePath + "/"))
                    end
                end;

            def match_depth($item):
                if ($depth | tonumber) < 0 then true
                else
                    (normalize_path($item.relativePath) // normalize_path($item.folderPath)) as $rel |
                    if $rel == "" then ($depth | tonumber) >= 0
                    else
                        ($rel | split("/") | length) as $len |
                        $len <= ($depth | tonumber)
                    end
                end;

            {
                workflows: (normalize_workflows | map(select(match_project(.) and match_path(.) and match_depth(.)))),
                folders: (normalize_folders | map(select(match_project(.) and match_path(.) and match_depth(.))))
            }
        '); then
        log ERROR "Failed to normalize snapshot payload"
        return 1
    fi

    if [[ -n "$result_ref" ]]; then
        printf -v "$result_ref" '%s' "$filtered_snapshot"
    else
        printf '%s' "$filtered_snapshot"
    fi
    return 0
}
