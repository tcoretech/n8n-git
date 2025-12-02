#!/usr/bin/env bash
# =========================================================
# lib/reset/plan.sh - Removal-first reset plan utilities
# =========================================================
# Builds reset plans by capturing the live n8n workspace snapshot,
# preparing removal queues, and presenting confirmation summaries.

# shellcheck disable=SC1091  # dynamic sourcing handled at runtime

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------
# Dependency loading
# ---------------------------------------------------------
if [[ -z "${PROJECT_NAME:-}" ]]; then
    RESET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/utils/common.sh
    [[ -f "$RESET_LIB_DIR/utils/common.sh" ]] && source "$RESET_LIB_DIR/utils/common.sh"
    # shellcheck source=lib/n8n/snapshot.sh
    [[ -f "$RESET_LIB_DIR/n8n/snapshot.sh" ]] && source "$RESET_LIB_DIR/n8n/snapshot.sh"
    # shellcheck source=lib/github/git.sh
    [[ -f "$RESET_LIB_DIR/github/git.sh" ]] && source "$RESET_LIB_DIR/github/git.sh"
fi

# ---------------------------------------------------------
# Plan state
# ---------------------------------------------------------
declare -g RESET_PLAN_ID=""
declare -g RESET_PLAN_BRANCH=""
declare -g RESET_PLAN_MODE="soft"
declare -g RESET_PLAN_TARGET_SHA=""
declare -g RESET_PLAN_TARGET_DISPLAY=""
declare -g RESET_PLAN_TARGET_SOURCE=""
declare -g RESET_PLAN_TARGET_CONTEXT=""
declare -g RESET_PLAN_DRY_RUN="false"

declare -g RESET_PLAN_SCOPE_LABEL="/"
declare -g RESET_PLAN_SNAPSHOT_JSON="{}"
declare -g RESET_PLAN_PULL_SPEC_JSON="{}"
declare -g RESET_PLAN_PLAN_JSON="{}"

declare -ga RESET_PLAN_REMOVE_WORKFLOWS=()
declare -gA RESET_PLAN_WORKFLOW_NAME=()
declare -gA RESET_PLAN_WORKFLOW_DISPLAY=()
declare -gA RESET_PLAN_WORKFLOW_PROJECT=()
declare -gA RESET_PLAN_WORKFLOW_ARCHIVED=()
declare -gA RESET_PLAN_WORKFLOW_MATCH_KEY=()
declare -gA RESET_PLAN_WORKFLOW_FOLDER_PATH=()

declare -ga RESET_PLAN_REMOVE_FOLDERS=()
declare -gA RESET_PLAN_FOLDER_DISPLAY=()
declare -gA RESET_PLAN_FOLDER_PROJECT=()
declare -gA RESET_PLAN_FOLDER_PROJECT_ID=()
declare -gA RESET_PLAN_FOLDER_DEPTH=()
declare -gA RESET_PLAN_FOLDER_PATH=()

declare -ga RESET_PLAN_PRESERVE_REQUESTED_IDS=()
declare -ga RESET_PLAN_PRESERVED_WORKFLOWS=()
declare -gA RESET_PLAN_PRESERVED_LOOKUP=()

declare -ga RESET_PLAN_WARNINGS=()

declare -ga RESET_PLAN_INCOMING_WORKFLOWS=()
declare -gA RESET_PLAN_INCOMING_MATCH_KEYS=()
declare -gA RESET_PLAN_INCOMING_WORKFLOW_NAMES=()
declare -gA RESET_PLAN_INCOMING_FOLDER_LOOKUP=()
declare -gA RESET_PLAN_REMOVAL_MATCH_TYPES=()

declare -g RESET_PLAN_REMOVAL_COUNT_WORKFLOWS=0
declare -g RESET_PLAN_REMOVAL_COUNT_FOLDERS=0

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------
reset_plan_clear_state() {
    RESET_PLAN_REMOVE_WORKFLOWS=()
    RESET_PLAN_WORKFLOW_NAME=()
    RESET_PLAN_WORKFLOW_DISPLAY=()
    RESET_PLAN_WORKFLOW_PROJECT=()
    RESET_PLAN_WORKFLOW_ARCHIVED=()
    RESET_PLAN_WORKFLOW_MATCH_KEY=()
    RESET_PLAN_WORKFLOW_FOLDER_PATH=()

    RESET_PLAN_REMOVE_FOLDERS=()
    RESET_PLAN_FOLDER_DISPLAY=()
    RESET_PLAN_FOLDER_PROJECT=()
    RESET_PLAN_FOLDER_PROJECT_ID=()
    RESET_PLAN_FOLDER_DEPTH=()
    RESET_PLAN_FOLDER_PATH=()

    RESET_PLAN_PRESERVE_REQUESTED_IDS=()
    RESET_PLAN_PRESERVED_WORKFLOWS=()
    RESET_PLAN_PRESERVED_LOOKUP=()

    RESET_PLAN_REMOVAL_COUNT_WORKFLOWS=0
    RESET_PLAN_REMOVAL_COUNT_FOLDERS=0

    RESET_PLAN_INCOMING_WORKFLOWS=()
    RESET_PLAN_INCOMING_MATCH_KEYS=()
    RESET_PLAN_INCOMING_WORKFLOW_NAMES=()
    RESET_PLAN_INCOMING_FOLDER_LOOKUP=()
    RESET_PLAN_REMOVAL_MATCH_TYPES=()
}

register_incoming_workflow_ids() {
    RESET_PLAN_PRESERVE_REQUESTED_IDS=()
    local id
    for id in "$@"; do
        [[ -z "$id" ]] && continue
        RESET_PLAN_PRESERVE_REQUESTED_IDS+=("$id")
    done
}

add_plan_warning() {
    local message="${1:-}"
    [[ -z "$message" ]] && return 0
    RESET_PLAN_WARNINGS+=("$message")
}

preserve_workflows() {
    local -a ids=("$@")
    ((${#ids[@]} == 0)) && return 0

    declare -A lookup=()
    local identifier
    for identifier in "${ids[@]}"; do
        [[ -z "$identifier" ]] && continue
        lookup["$identifier"]=1
    done

    local -a retained=()
    for identifier in "${RESET_PLAN_REMOVE_WORKFLOWS[@]}"; do
        if [[ -n "${lookup[$identifier]:-}" ]]; then
            if [[ -z "${RESET_PLAN_PRESERVED_LOOKUP[$identifier]:-}" ]]; then
                RESET_PLAN_PRESERVED_LOOKUP["$identifier"]=1
                RESET_PLAN_PRESERVED_WORKFLOWS+=("$identifier")
            fi
            continue
        fi
        retained+=("$identifier")
    done

    RESET_PLAN_REMOVE_WORKFLOWS=("${retained[@]}")
    RESET_PLAN_REMOVAL_COUNT_WORKFLOWS=${#RESET_PLAN_REMOVE_WORKFLOWS[@]}
}

reset_plan_scope_label_from_snapshot() {
    local snapshot_json="$1"
    local project_hint
    if [[ -n "${RESET_PLAN_PROJECT_NAME:-}" ]]; then
        project_hint="${RESET_PLAN_PROJECT_NAME}"
    else
        project_hint="$(effective_project_name "${project_name:-}")"
    fi
    local path_hint="${n8n_path:-/}"

    path_hint="${path_hint#/}"
    path_hint="${path_hint%/}"

    local scope_label=""
    if [[ -n "$project_hint" ]]; then
        scope_label="$project_hint"
    fi

    if [[ -n "$path_hint" ]]; then
        if [[ -z "$scope_label" ]]; then
            scope_label="/$path_hint"
        else
            scope_label="$scope_label/$path_hint"
        fi
    fi

    if [[ -z "$scope_label" ]]; then
        scope_label="/"
    fi

    printf '%s' "$scope_label"
}

reset_plan_log_snapshot_overview() {
    local snapshot_json="$1"
    local scope_label="$2"

    local workflow_count
    local folder_count
    workflow_count=$(jq -r '.workflows | length' <<<"$snapshot_json" 2>/dev/null || echo "0")
    folder_count=$(jq -r '.folders | length' <<<"$snapshot_json" 2>/dev/null || echo "0")

    local path_label
    local project_label
    local depth_label
    path_label="${n8n_path:-/}"
    project_label="${project_name:-all}"
    if [[ -z "$project_label" || "$project_label" == "$PERSONAL_PROJECT_TOKEN" || "$project_label" == "%PERSONAL_PROJECT%" || "${project_label,,}" == "personal" || "${project_label,,}" == "all" ]]; then
        project_label="$(resolve_personal_project_name)"
        if [[ ( "$project_label" == "$PERSONAL_PROJECT_TOKEN" || "$project_label" == "%PERSONAL_PROJECT%" || -z "$project_label" || "${project_label,,}" == "personal" ) && -n "${N8N_PROJECTS_LAST_SUCCESS_JSON:-}" ]]; then
            local derived_personal
            derived_personal=$(printf '%s' "$N8N_PROJECTS_LAST_SUCCESS_JSON" | jq -r '
                (if type == "array" then . else (.data // []) end)
                | map(select((.type // "") == "personal") | .name // empty)
                | map(select(. != "" and . != "null"))
                | first // empty
            ' 2>/dev/null || echo "")
            if [[ -n "$derived_personal" ]]; then
                project_label="$derived_personal"
                remember_personal_project_name "$derived_personal"
                project_name="$derived_personal"
                RESET_PLAN_PROJECT_NAME="$derived_personal"
                export N8N_PROJECT="$derived_personal"
            fi
        fi
    fi
    depth_label="${n8n_depth:-infinite}"

    local log_path="$path_label"
    [[ -z "$log_path" ]] && log_path="/"

    log DEBUG "Building live snapshot for n8n-path='${log_path}' (project='${project_label}', depth=${depth_label})"
    log DEBUG "Snapshot includes: ${workflow_count} workflow(s), ${folder_count} folder(s) under '${scope_label}'"
}

reset_plan_capture_project_hint() {
    local snapshot_json="$1"
    if [[ -z "$snapshot_json" || "$snapshot_json" == "[]" || "$snapshot_json" == "{}" ]]; then
        return 0
    fi

    local derived_name=""
    derived_name=$(printf '%s' "$snapshot_json" | jq -r '
        [
          .workflows[]?
          | (.project.name // .projectName // empty)
          | select(. != "" and . != "null")
        ]
        | first // empty
    ' 2>/dev/null || echo "")

    if [[ -n "$derived_name" && "$derived_name" != "null" ]]; then
        # Sanitize project name to match file system representation
        derived_name="$(sanitize_filename_component "$derived_name")"
        remember_personal_project_name "$derived_name"
        RESET_PLAN_PROJECT_NAME="$derived_name"
    fi
}

reset_plan_update_pull_spec() {
    local github_raw="${github_path:-}"
    local github_rendered
    github_rendered="$(render_github_path_with_tokens "$github_raw")"
    local github_prefix="$github_rendered"
    if [[ -z "$github_prefix" ]]; then
        github_prefix="/"
    fi
    local preserve_flag=false
    local no_overwrite_flag=false
    if [[ "${restore_preserve_ids:-false}" == "true" ]]; then
        preserve_flag=true
    fi
    if [[ "${restore_no_overwrite:-false}" == "true" ]]; then
        no_overwrite_flag=true
    fi

    local scoped_n8n_path="${n8n_path:-/}"
    if [[ -z "$scoped_n8n_path" ]]; then
        scoped_n8n_path="/"
    fi

    RESET_PLAN_PULL_SPEC_JSON=$(jq -n \
        --arg n8nPath "$scoped_n8n_path" \
        --arg githubPath "$github_prefix" \
        --arg mode "${RESET_PLAN_MODE}" \
        --argjson preserve $preserve_flag \
        --argjson noOverwrite $no_overwrite_flag \
        '{
            n8nPath: ($n8nPath // "/"),
            githubPath: ($githubPath // "/"),
            mode: $mode,
            preserveIds: $preserve,
            noOverwrite: $noOverwrite
        }'
    )
}

reset_plan_format_display_path() {
    local project_label="$1"
    local folder_path="$2"
    local workflow_name="$3"

    if [[ -z "$project_label" ]]; then
        project_label="Personal"
    fi

    local display="[$project_label]"
    if [[ -n "$folder_path" ]]; then
        display+="/$folder_path"
    fi
    if [[ -n "$workflow_name" ]]; then
        display+="/$workflow_name"
    fi
    printf '%s' "$display"
}

reset_plan_extract_folder_from_display() {
    local display="$1"
    local project_label="$2"
    local workflow_name="$3"

    if [[ -z "$display" ]]; then
        printf ''
        return 0
    fi

    local trimmed="$display"
    trimmed="${trimmed#"[${project_label}]"}"
    trimmed="${trimmed#/}"
    if [[ -z "$trimmed" ]]; then
        printf ''
        return 0
    fi

    if [[ "$trimmed" == "$workflow_name" ]]; then
        printf ''
        return 0
    fi

    if [[ -n "$workflow_name" && "$trimmed" == */"$workflow_name" ]]; then
        trimmed="${trimmed%"/$workflow_name"}"
    fi

    printf '%s' "$trimmed"
}

reset_plan_collect_incoming_inventory() {
    RESET_PLAN_INCOMING_WORKFLOWS=()
    RESET_PLAN_INCOMING_FOLDER_LOOKUP=()

    local target_sha="${RESET_PLAN_TARGET_SHA:-}"
    if [[ -z "$target_sha" ]]; then
        return 0
    fi

    local repo_root="${RESET_REPO_PATH:-${GIT_WORK_TREE:-}}"
    if [[ -z "$repo_root" ]]; then
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
            repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
        fi
    fi

    if [[ -z "$repo_root" || ! -d "$repo_root/.git" ]]; then
        return 0
    fi

    local pull_json="$RESET_PLAN_PULL_SPEC_JSON"
    local repo_scope=""
    if [[ -n "$pull_json" && "$pull_json" != "{}" ]]; then
        repo_scope="$(jq -r '.githubPath // ""' <<<"$pull_json")"
        [[ "$repo_scope" == "null" ]] && repo_scope=""
    fi

    local normalized_scope
    normalized_scope="$(normalize_repo_subpath "$repo_scope")"

    local tree_listing=""
    if ! git_list_tree_paths "$repo_root" "$target_sha" "$normalized_scope" tree_listing; then
        if [[ -n "$GIT_LAST_STDERR" ]]; then
            log DEBUG "git ls-tree: $GIT_LAST_STDERR"
        fi
        return 0
    fi

    if [[ -z "$tree_listing" ]]; then
        return 0
    fi
    local credentials_dir="${credentials_folder_name:-.credentials}"
    credentials_dir="${credentials_dir#/}"
    credentials_dir="${credentials_dir%/}"

    local addition_project_label
    addition_project_label="$(reset_plan_scope_project_label)"

    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ "$path" != *.json ]] && continue

        local lower_path="${path,,}"
        if [[ -n "$credentials_dir" ]]; then
            local lower_cred="${credentials_dir,,}"
            case "$lower_path" in
                "$lower_cred"|"$lower_cred"/*|*/"$lower_cred"|*/"$lower_cred"/*)
                    continue
                    ;;
            esac
        fi

        if [[ "$lower_path" == */credentials.json || "$lower_path" == credentials.json ]]; then
            continue
        fi

        local relative="$path"
        if [[ -n "$normalized_scope" ]]; then
            relative="${relative#"$normalized_scope"/}"
        fi
        relative="${relative#/}"
        relative="${relative%/}"
        [[ -z "$relative" ]] && continue

        local without_ext="${relative%.json}"

        local saved_ifs="$IFS"
        IFS='/' read -r -a parts <<<"$without_ext"
        IFS="$saved_ifs"

        local part_count=${#parts[@]}
        (( part_count == 0 )) && continue

        local workflow_index=$(( part_count - 1 ))
        local workflow_name="${parts[$workflow_index]}"
        workflow_name="$(reset_plan_sanitize_token "$workflow_name")"

        local -a folder_parts=()
        if (( part_count > 1 )); then
            folder_parts=("${parts[@]:0:workflow_index}")
        fi

        local folder_path=""
        if (( ${#folder_parts[@]} > 0 )); then
            folder_path="$(IFS=/; printf '%s' "${folder_parts[*]}")"
        fi
        folder_path="$(reset_plan_sanitize_token "$folder_path")"
        folder_path="$(normalize_repo_folder_path "$folder_path" "$workflow_name")"

        local project_label="$addition_project_label"
        local display_path
        display_path="$(reset_plan_format_display_path "$project_label" "$folder_path" "$workflow_name")"
        local storage_folder="$folder_path"
        if [[ -z "$storage_folder" ]]; then
            storage_folder="/"
        fi

        local encoded_entry
        if ! encoded_entry=$(jq -n -c --arg project "$project_label" --arg folder "$storage_folder" --arg workflow "$workflow_name" --arg file "$relative" '{project:$project,folder:$folder,workflow:$workflow,file:$file}' 2>/dev/null); then
            log DEBUG "Unable to encode incoming workflow entry '$workflow_name' ($relative); skipping"
            continue
        fi

        RESET_PLAN_INCOMING_WORKFLOWS+=("$encoded_entry")

        local match_key
        match_key="$workflow_name"
        if [[ -n "$folder_path" ]]; then
            match_key="${folder_path%/}/$workflow_name"
        fi
        RESET_PLAN_INCOMING_MATCH_KEYS["$match_key"]=1
        RESET_PLAN_INCOMING_WORKFLOW_NAMES["$workflow_name"]=1

        local folder_match="$folder_path"
        [[ -z "$folder_match" ]] && folder_match="/"
        RESET_PLAN_INCOMING_FOLDER_LOOKUP["$folder_match"]=1
    done <<<"$tree_listing"

    log DEBUG "Collected ${#RESET_PLAN_INCOMING_WORKFLOWS[@]} incoming workflow(s) from repository snapshot"

    return 0
}

reset_plan_classify_removal_actions() {
    RESET_PLAN_REMOVAL_MATCH_TYPES=()

    local identifier
    for identifier in "${RESET_PLAN_REMOVE_WORKFLOWS[@]}"; do
        local match_key="${RESET_PLAN_WORKFLOW_MATCH_KEY[$identifier]:-}"
        local workflow_name="${RESET_PLAN_WORKFLOW_NAME[$identifier]:-}"
        if [[ -n "$match_key" && -n "${RESET_PLAN_INCOMING_MATCH_KEYS[$match_key]:-}" ]]; then
            RESET_PLAN_REMOVAL_MATCH_TYPES["$identifier"]="replace"
        elif [[ -n "$workflow_name" && -n "${RESET_PLAN_INCOMING_WORKFLOW_NAMES[$workflow_name]:-}" ]]; then
            RESET_PLAN_REMOVAL_MATCH_TYPES["$identifier"]="replace"
        else
            RESET_PLAN_REMOVAL_MATCH_TYPES["$identifier"]="remove"
        fi
    done

    # Filter folders
    local -a kept_folders=()
    for folder_id in "${RESET_PLAN_REMOVE_FOLDERS[@]}"; do
        local f_path="${RESET_PLAN_FOLDER_PATH[$folder_id]:-}"
        local lookup_key="$f_path"
        [[ -z "$lookup_key" ]] && lookup_key="/"
        
        if [[ -n "${RESET_PLAN_INCOMING_FOLDER_LOOKUP[$lookup_key]:-}" ]]; then
            # Folder exists in repo, keep it (do not delete)
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Preserving folder $f_path (ID: $folder_id) as it exists in target"
            fi
        else
            kept_folders+=("$folder_id")
        fi
    done
    RESET_PLAN_REMOVE_FOLDERS=("${kept_folders[@]}")
    RESET_PLAN_REMOVAL_COUNT_FOLDERS=${#RESET_PLAN_REMOVE_FOLDERS[@]}
}


reset_plan_build_plan_json() {
    local workflows_json='[]'
    local folders_json='[]'

    if ((${#RESET_PLAN_REMOVE_WORKFLOWS[@]} > 0)); then
        workflows_json=$(printf '%s\n' "${RESET_PLAN_REMOVE_WORKFLOWS[@]}" | jq -R . | jq -s '.')
    fi
    if ((${#RESET_PLAN_REMOVE_FOLDERS[@]} > 0)); then
        folders_json=$(printf '%s\n' "${RESET_PLAN_REMOVE_FOLDERS[@]}" | jq -R . | jq -s '.')
    fi

    RESET_PLAN_PLAN_JSON=$(jq -n \
        --arg mode "${RESET_PLAN_MODE}" \
        --argjson pull "$RESET_PLAN_PULL_SPEC_JSON" \
        --argjson removalWorkflows "$workflows_json" \
        --argjson removalFolders "$folders_json" \
        '{
            mode: $mode,
            pull: $pull,
            removalWorkflows: $removalWorkflows,
            removalFolders: $removalFolders
        }'
    )
}

# ---------------------------------------------------------
# Plan generation
# ---------------------------------------------------------
init_reset_plan() {
    local branch="$1"
    local mode="$2"
    local target_sha="$3"
    local target_display="$4"
    local target_source="$5"
    local dry_run="${6:-false}"
    local target_context="${7:-}"

    RESET_PLAN_ID="reset-$(date +%Y%m%d-%H%M%S)-$$"
    RESET_PLAN_BRANCH="$branch"
    RESET_PLAN_MODE="$mode"
    RESET_PLAN_TARGET_SHA="$target_sha"
    RESET_PLAN_TARGET_DISPLAY="$target_display"
    RESET_PLAN_TARGET_SOURCE="$target_source"
    RESET_PLAN_DRY_RUN="$dry_run"
    RESET_PLAN_TARGET_CONTEXT="$target_context"

    RESET_PLAN_WARNINGS=()
    RESET_PLAN_PLAN_JSON="{}"
    RESET_PLAN_PULL_SPEC_JSON="{}"
    RESET_PLAN_SCOPE_LABEL="/"
    RESET_PLAN_SNAPSHOT_JSON="{}"
    reset_plan_clear_state

    log DEBUG "Initialized reset plan: $RESET_PLAN_ID"
    echo "$RESET_PLAN_ID"
}

compute_workflow_diff() {
    local mode="${1:-soft}"
    local target_sha="${2:-}"
    RESET_PLAN_MODE="$mode"
    RESET_PLAN_TARGET_SHA="$target_sha"

    local snapshot_json=""
    if ! n8n_snapshot_collect "${n8n_path:-}" "" "" snapshot_json; then
        log ERROR "Failed to collect workspace snapshot for reset plan"
        return 1
    fi

    # shellcheck disable=SC2034  # exported for apply phase consumption
    RESET_PLAN_SNAPSHOT_JSON="$snapshot_json"
    reset_plan_capture_project_hint "$snapshot_json"
    local resolved_personal
    resolved_personal="$(resolve_personal_project_name)"
    local default_project_name="Personal"
    if [[ -n "$resolved_personal" && "$resolved_personal" != "$PERSONAL_PROJECT_TOKEN" && "$resolved_personal" != "%PERSONAL_PROJECT%" ]]; then
        project_name="$resolved_personal"
        RESET_PLAN_PROJECT_NAME="$resolved_personal"
        export N8N_PROJECT="$resolved_personal"
        default_project_name="$resolved_personal"
    fi
    RESET_PLAN_SCOPE_LABEL="$(reset_plan_scope_label_from_snapshot "$snapshot_json")"
    reset_plan_clear_state
    reset_plan_log_snapshot_overview "$snapshot_json" "$RESET_PLAN_SCOPE_LABEL"

    local workflow_row
    while IFS= read -r workflow_row; do
        [[ -z "$workflow_row" || "$workflow_row" == "null" ]] && continue
        local workflow_id
        workflow_id=$(jq -r '.id // empty' <<<"$workflow_row")
        if [[ -z "$workflow_id" || "$workflow_id" == "null" ]]; then
            if [[ "${verbose:-false}" == "true" ]]; then
                log DEBUG "Skipping workflow with missing id (snapshot entry: $workflow_row)"
            fi
            continue
        fi

        local workflow_name
        workflow_name=$(jq -r '.name // "Workflow"' <<<"$workflow_row")
        local project_name_raw
        project_name_raw=$(jq -r '.project.name // .projectName // empty' <<<"$workflow_row")
        if [[ -z "$project_name_raw" || "$project_name_raw" == "Personal" || "$project_name_raw" == "personal" ]]; then
            project_name_raw="$default_project_name"
        fi

        local relative_path
        relative_path=$(jq -r '.folderPath // .relativePath // .path // empty' <<<"$workflow_row")
        if [[ "$relative_path" == "null" ]]; then
            relative_path=""
        fi
        if [[ -z "$relative_path" ]]; then
            relative_path=$(jq -r '((.folders // []) | map(.name // empty) | map(select(length>0)) | join("/"))' <<<"$workflow_row" 2>/dev/null || printf '')
        fi
        if [[ -n "$relative_path" && "$relative_path" == "$project_name_raw" ]]; then
            relative_path=""
        elif [[ -n "$relative_path" && "$relative_path" == "$project_name_raw"/* ]]; then
            relative_path="${relative_path#"$project_name_raw"/}"
        fi
        relative_path="${relative_path#/}"
        relative_path="${relative_path%/}"
        
        local project_name
        project_name="$(sanitize_filename_component "$project_name_raw")"

        local archived_flag
        archived_flag=$(jq -r '((.archived // .isArchived // false) | tostring)' <<<"$workflow_row")

        local display_label="[$project_name]"
        if [[ -n "$relative_path" ]]; then
            display_label+="/$relative_path"
        fi
        if [[ -n "$workflow_name" ]]; then
            display_label+="/$workflow_name"
        fi
        display_label="${display_label//\/\//\/}"

        RESET_PLAN_REMOVE_WORKFLOWS+=("$workflow_id")
        RESET_PLAN_WORKFLOW_NAME["$workflow_id"]="$workflow_name"
        RESET_PLAN_WORKFLOW_DISPLAY["$workflow_id"]="$display_label"
        # shellcheck disable=SC2034  # exported for reporting
        RESET_PLAN_WORKFLOW_PROJECT["$workflow_id"]="$project_name"
        RESET_PLAN_WORKFLOW_ARCHIVED["$workflow_id"]="$archived_flag"
        local match_key="$workflow_name"
        if [[ -n "$relative_path" ]]; then
            match_key="${relative_path%/}/$workflow_name"
        fi
        RESET_PLAN_WORKFLOW_MATCH_KEY["$workflow_id"]="$match_key"
        RESET_PLAN_WORKFLOW_FOLDER_PATH["$workflow_id"]="$relative_path"

        if [[ "${verbose:-false}" == "true" ]]; then
            local log_path="/"
            if [[ -n "$relative_path" ]]; then
                log_path="/$relative_path/"
            fi
            log DEBUG "Evaluating workflow ${log_path}${workflow_name} (ID: ${workflow_id})"
        fi
    done < <(jq -c '.workflows[]?' <<<"$snapshot_json")

    local folder_row
    while IFS= read -r folder_row; do
        [[ -z "$folder_row" || "$folder_row" == "null" ]] && continue
        local folder_id
        folder_id=$(jq -r '.id // empty' <<<"$folder_row")
        [[ -z "$folder_id" ]] && continue
        
        local folder_path
        folder_path=$(jq -r '.path // .relativePath // empty' <<<"$folder_row")
        local folder_name
        folder_name=$(jq -r '.name // "Folder"' <<<"$folder_row")
        
        # Normalize path
        folder_path="${folder_path#/}"
        folder_path="${folder_path%/}"
        
        local project_name
        project_name=$(jq -r '.project.name // .projectName // empty' <<<"$folder_row")
        if [[ -z "$project_name" || "$project_name" == "Personal" || "$project_name" == "personal" ]]; then
            project_name="$default_project_name"
        fi
        # Sanitize project name to match file system representation
        project_name="$(sanitize_filename_component "$project_name")"

        RESET_PLAN_REMOVE_FOLDERS+=("$folder_id")
        RESET_PLAN_FOLDER_PATH["$folder_id"]="$folder_path"
        RESET_PLAN_FOLDER_DISPLAY["$folder_id"]="[$project_name]/$folder_path"
        RESET_PLAN_FOLDER_PROJECT["$folder_id"]="$project_name"
        RESET_PLAN_FOLDER_PROJECT_ID["$folder_id"]=$(jq -r '.project.id // empty' <<<"$folder_row")
        
        if [[ "${verbose:-false}" == "true" ]]; then
             log DEBUG "Evaluating folder /$folder_path (ID: $folder_id)"
        fi
    done < <(jq -c '.folders[]?' <<<"$snapshot_json")

    RESET_PLAN_REMOVAL_COUNT_WORKFLOWS=${#RESET_PLAN_REMOVE_WORKFLOWS[@]}
    RESET_PLAN_REMOVAL_COUNT_FOLDERS=${#RESET_PLAN_REMOVE_FOLDERS[@]}

    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "Enumerated ${RESET_PLAN_REMOVAL_COUNT_WORKFLOWS} workflows"
        log DEBUG "Enumerated ${RESET_PLAN_REMOVAL_COUNT_FOLDERS} folders"
    fi
    log DEBUG "Removal candidates: ${RESET_PLAN_REMOVAL_COUNT_WORKFLOWS} workflow(s), ${RESET_PLAN_REMOVAL_COUNT_FOLDERS} folder(s)"

    if ((${#RESET_PLAN_PRESERVE_REQUESTED_IDS[@]} > 0)); then
        preserve_workflows "${RESET_PLAN_PRESERVE_REQUESTED_IDS[@]}"
        if ((${#RESET_PLAN_PRESERVED_WORKFLOWS[@]} > 0)); then
            # TO DO: need to do this for folders as well
            log DEBUG "Preserving ${#RESET_PLAN_PRESERVED_WORKFLOWS[@]} workflow(s) by ID; to remove: ${RESET_PLAN_REMOVAL_COUNT_WORKFLOWS}"
        else
            log WARN "Requested workflow preservation did not match any scoped workflow IDs"
        fi
    fi

    reset_plan_update_pull_spec
    reset_plan_collect_incoming_inventory
    reset_plan_classify_removal_actions
    reset_plan_build_plan_json
    log INFO "Plan created: pull + removal(${RESET_PLAN_REMOVAL_COUNT_WORKFLOWS} workflow(s), ${RESET_PLAN_REMOVAL_COUNT_FOLDERS} folder(s)) [mode=${RESET_PLAN_MODE}]"
    return 0
}

get_action_counts() {
    local warning_count=${#RESET_PLAN_WARNINGS[@]}
    jq -n \
        --argjson workflows ${#RESET_PLAN_REMOVE_WORKFLOWS[@]} \
        --argjson folders ${#RESET_PLAN_REMOVE_FOLDERS[@]} \
        --argjson warnings "$warning_count" \
        '{
            removal: {
                workflows: $workflows,
                folders: $folders
            },
            warnings: $warnings
        }'
}

get_reset_plan_json() {
    printf '%s' "$RESET_PLAN_PLAN_JSON"
}

# ---------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------
display_plan_header() {
    log HEADER "RESET PLAN"
}

display_target_info() {
    local plan_sha="${RESET_PLAN_TARGET_SHA:-${RESOLVED_TARGET_SHA:-}}"
    local plan_display="${RESET_PLAN_TARGET_DISPLAY:-${RESOLVED_TARGET_DISPLAY:-"(not set)"}}"
    local plan_source="${RESET_PLAN_TARGET_SOURCE:-${RESOLVED_TARGET_SOURCE:-"(unknown)"}}"
    local plan_branch="${RESET_PLAN_BRANCH:-$(get_current_branch)}"
    local scope_label_resolved
    scope_label_resolved="$(reset_plan_resolved_scope_label)"

    log INFO "${BOLD}Source:${NC}"
    if [[ -n "$plan_sha" ]]; then
        log INFO "  SHA:      ${BLUE}${plan_sha:0:12}...${NC}"
    else
        log INFO "  SHA:      ${YELLOW}(unknown)${NC}"
    fi
    log INFO "  Display:  $plan_display"
    log INFO "  Source:   $plan_source"
    log INFO "  Branch:   ${plan_branch:-"(detached)"}"
    log INFO "  Scope:    ${scope_label_resolved}"

    if [[ -z "$RESET_PLAN_TARGET_CONTEXT" && -n "${RESOLVED_TARGET_CONTEXT:-}" ]]; then
        RESET_PLAN_TARGET_CONTEXT="$RESOLVED_TARGET_CONTEXT"
    fi
    if [[ -n "$RESET_PLAN_TARGET_CONTEXT" ]]; then
        log INFO "  Context:  $RESET_PLAN_TARGET_CONTEXT"
    fi

    local pull_json="$RESET_PLAN_PULL_SPEC_JSON"
    if [[ -n "$pull_json" && "$pull_json" != "{}" ]]; then
        local resolved_project_label
        resolved_project_label="${RESET_PLAN_PROJECT_NAME:-$(resolve_personal_project_name)}"
        # Sanitize project name to match file system representation
        resolved_project_label="$(sanitize_filename_component "$resolved_project_label")"
        if [[ "$resolved_project_label" == "$PERSONAL_PROJECT_TOKEN" || "$resolved_project_label" == "%PERSONAL_PROJECT%" ]]; then
            resolved_project_label="Personal"
        fi

        local repo_scope
        repo_scope=$(jq -r '.githubPath // ""' <<<"$pull_json")
        [[ "$repo_scope" == "null" ]] && repo_scope=""

        local n8n_scope
        n8n_scope=$(jq -r '.n8nPath // ""' <<<"$pull_json")
        [[ "$n8n_scope" == "null" ]] && n8n_scope=""

        local preserve_flag
        preserve_flag=$(jq -r '.preserveIds // false' <<<"$pull_json")
        local no_overwrite_flag
        no_overwrite_flag=$(jq -r '.noOverwrite // false' <<<"$pull_json")

        local repo_slug="${github_repo:-}"
        if [[ -z "$repo_slug" ]]; then
            repo_slug="local-backup:${local_backup_path:-$HOME/n8n-backup}"
        fi

        local scope_display="/"
        local rendered_scope
        rendered_scope="$(render_github_path_with_tokens "$repo_scope")"
        rendered_scope="$(normalize_github_path_prefix "$rendered_scope")"
        if [[ "$rendered_scope" == *"%PERSONAL_PROJECT%"* || "$rendered_scope" == *"%PROJECT%"* ]]; then
            rendered_scope="${rendered_scope//%PERSONAL_PROJECT%/$resolved_project_label}"
            rendered_scope="${rendered_scope//%PROJECT%/$resolved_project_label}"
        elif [[ "${rendered_scope,,}" == "personal" || "${rendered_scope,,}" == "personal/" ]]; then
            rendered_scope="$resolved_project_label"
        fi
        local tree_scope="${rendered_scope#/}"
        tree_scope="${tree_scope%/}"
        if [[ -n "$tree_scope" ]]; then
            scope_display="$tree_scope/"
        fi

        local workspace_display="/"
        if [[ -n "$n8n_scope" && "$n8n_scope" != "/" ]]; then
            workspace_display="$n8n_scope"
            if [[ "$workspace_display" == *"%PERSONAL_PROJECT%"* || "$workspace_display" == *"%PROJECT%"* ]]; then
                workspace_display="${workspace_display//%PERSONAL_PROJECT%/$resolved_project_label}"
                workspace_display="${workspace_display//%PROJECT%/$resolved_project_label}"
            elif [[ "${workspace_display,,}" == "personal" || "${workspace_display,,}" == "personal/" ]]; then
                workspace_display="$resolved_project_label"
            fi
        fi

        log INFO "  Repository: ${repo_slug}"
        log INFO "  Repository scoped to: \"${scope_display}\""
        log INFO "  Into workspace: ${workspace_display}"
        log INFO "  Options: preserve IDs=$(format_reset_bool_label "$preserve_flag"), skip overwrite=$(format_reset_bool_label "$no_overwrite_flag")"
    fi
    echo ""
}

display_mode_info() {
    local mode_value="${RESET_PLAN_MODE:-soft}"
    local mode_color="$GREEN"
    if [[ "$mode_value" == "hard" ]]; then
        mode_color="$RED"
        mode_value+=" (DESTRUCTIVE)"
    fi
    log INFO "${BOLD}Reset Mode:${NC} ${mode_color}${mode_value}${NC}"

    if [[ "$RESET_PLAN_DRY_RUN" == "true" ]]; then
        log INFO "${BOLD}Dry Run:${NC} ${YELLOW}YES (no changes will be made)${NC}"
    fi
    echo ""
}

format_reset_bool_label() {
    local raw="${1:-false}"
    case "${raw,,}" in
        true|1|yes|y)
            printf 'yes'
            ;;
        *)
            printf 'no'
            ;;
    esac
}

format_workflow_line() {
    local identifier="$1"
    local display="${RESET_PLAN_WORKFLOW_DISPLAY[$identifier]:-}" 
    local archived="${RESET_PLAN_WORKFLOW_ARCHIVED[$identifier]:-false}"
    if [[ -n "$display" ]]; then
        printf '    - %s (id: %s, archived: %s)\n' "$display" "$identifier" "$archived"
    else
        printf '    - id: %s (archived: %s)\n' "$identifier" "$archived"
    fi
}

format_folder_line() {
    local identifier="$1"
    local display="${RESET_PLAN_FOLDER_DISPLAY[$identifier]:-}"
    if [[ -z "$display" ]]; then
        display="Folder $identifier"
    fi
    printf '    - %s (id: %s)\n' "$display" "$identifier"
}

display_plan_tree() {
    log INFO "${BOLD}Tree:${NC}"
    render_plan_diff_tree
}

render_plan_diff_tree() {
    local addition_project_label
    addition_project_label="$(reset_plan_scope_project_label)"

    declare -A tree_add_workflows=()
    declare -A tree_del_workflows=()
    declare -A tree_del_folders=()
    declare -A tree_projects_seen=()
    declare -A tree_folder_keys=()

    local entry
    for entry in "${RESET_PLAN_INCOMING_WORKFLOWS[@]}"; do
        [[ -z "$entry" ]] && continue

        local project_hint folder_path workflow_name repo_relative
        project_hint=$(jq -r '.project // ""' <<<"$entry" 2>/dev/null || printf '')
        folder_path=$(jq -r '.folder // ""' <<<"$entry" 2>/dev/null || printf '')
        workflow_name=$(jq -r '.workflow // ""' <<<"$entry" 2>/dev/null || printf '')
        repo_relative=$(jq -r '.file // ""' <<<"$entry" 2>/dev/null || printf '')

        if [[ -z "$workflow_name" ]]; then
            log DEBUG "Skipping malformed incoming workflow entry: $entry"
            continue
        fi

        folder_path="$(reset_plan_sanitize_token "$folder_path")"
        if [[ "$folder_path" == "/" ]]; then
            folder_path=""
        fi

        local project_key="$addition_project_label"
        if [[ -n "$project_hint" ]]; then
            # Sanitize project name to match file system representation
            project_key="$(sanitize_filename_component "$project_hint")"
        fi

        local composite="$project_key|$folder_path"
        tree_add_workflows["$composite"]+=$workflow_name$'\t'$repo_relative$'\n'
        tree_projects_seen["$project_key"]=1
        tree_folder_keys["$composite"]=1

        if [[ "${verbose:-false}" == "true" ]]; then
            local folder_label="$folder_path"
            [[ -z "$folder_label" ]] && folder_label="/"
            log DEBUG "Tree ingest add → project='${project_key}', folder='${folder_label}', workflow='${workflow_name}', file='${repo_relative}'"
        fi
    done

    local identifier
    for identifier in "${RESET_PLAN_REMOVE_WORKFLOWS[@]}"; do
        [[ -z "$identifier" ]] && continue
        local display_path="${RESET_PLAN_WORKFLOW_DISPLAY[$identifier]:-}"
        local workflow_name="${RESET_PLAN_WORKFLOW_NAME[$identifier]:-Workflow $identifier}"
        local archived_flag="${RESET_PLAN_WORKFLOW_ARCHIVED[$identifier]:-false}"

        local project_label="Workspace"
        if [[ -n "${RESET_PLAN_WORKFLOW_PROJECT[$identifier]:-}" ]]; then
            project_label="${RESET_PLAN_WORKFLOW_PROJECT[$identifier]}"
        elif [[ "$display_path" == \[*\]* ]]; then
            project_label="${display_path#[}"
            project_label="${project_label%%]*}"
        fi
        # Sanitize project name to match file system representation
        project_label="$(sanitize_filename_component "$project_label")"

        local folder_path="${RESET_PLAN_WORKFLOW_FOLDER_PATH[$identifier]:-}"
        if [[ -z "$folder_path" ]]; then
            local match_key_hint="${RESET_PLAN_WORKFLOW_MATCH_KEY[$identifier]:-}"
            if [[ -n "$match_key_hint" && "$match_key_hint" == */* ]]; then
                folder_path="${match_key_hint%/*}"
            else
                folder_path="$(reset_plan_extract_folder_from_display "$display_path" "$project_label" "$workflow_name")"
            fi
        fi
        folder_path="$(reset_plan_sanitize_token "$folder_path")"

        local composite="$project_label|$folder_path"
        tree_del_workflows["$composite"]+=$workflow_name$'	'$identifier$'	'$archived_flag$'\n'
        tree_projects_seen["$project_label"]=1
        tree_folder_keys["$composite"]=1
    done

    local folder_id
    for folder_id in "${RESET_PLAN_REMOVE_FOLDERS[@]}"; do
        [[ -z "$folder_id" ]] && continue
        
        local project_label="Workspace"
        if [[ -n "${RESET_PLAN_FOLDER_PROJECT[$folder_id]:-}" ]]; then
             project_label="${RESET_PLAN_FOLDER_PROJECT[$folder_id]}"
        else
             local display_path="${RESET_PLAN_FOLDER_DISPLAY[$folder_id]:-}"
             if [[ "$display_path" == \[*\]* ]]; then
                project_label="${display_path#[}"
                project_label="${project_label%%]*}"
             fi
        fi
        # Sanitize project name to match file system representation
        project_label="$(sanitize_filename_component "$project_label")"
        
        local folder_path
        if [[ -n "${RESET_PLAN_FOLDER_PATH[$folder_id]:-}" ]]; then
             folder_path="${RESET_PLAN_FOLDER_PATH[$folder_id]}"
        else
             local display_path="${RESET_PLAN_FOLDER_DISPLAY[$folder_id]:-}"
             local raw_folder="${display_path#*]}"
             raw_folder="${raw_folder#/}"
             raw_folder="${raw_folder%/}"
             folder_path="$raw_folder"
        fi
        folder_path="$(reset_plan_sanitize_token "$folder_path")"

        local composite="$project_label|$folder_path"
        tree_del_folders["$composite"]+=$folder_id$'\n'
        tree_projects_seen["$project_label"]=1
        tree_folder_keys["$composite"]=1
    done

    if (( ${#tree_projects_seen[@]} == 0 )); then
        log INFO "  (workspace already matches staged repository)"
        return 0
    fi

    declare -a tree_projects=()
    mapfile -t tree_projects < <(printf '%s
' "${!tree_projects_seen[@]}" | LC_ALL=C sort)

    local project
    for project in "${tree_projects[@]}"; do
        local display_project
        # Sanitize project name to match file system representation
        display_project="$(sanitize_filename_component "$project")"
        log INFO "    Project: ${BOLD}[${display_project}]${NC}"
        
        declare -a folders=()
        local composite
        for composite in "${!tree_folder_keys[@]}"; do
            if [[ "${composite%%|*}" == "$project" ]]; then
                folders+=("${composite#*|}")
            fi
        done
        if ((${#folders[@]} == 0)); then
            folders+=("")
        fi
        mapfile -t folders < <(printf '%s
' "${folders[@]}" | LC_ALL=C sort -u)

        local folder_path
        for folder_path in "${folders[@]}"; do
            local composite="$project|$folder_path"
            local add_blob="${tree_add_workflows["$composite"]:-}"
            local del_blob="${tree_del_workflows["$composite"]:-}"
            local folder_blob="${tree_del_folders["$composite"]:-}"

            render_plan_tree_folder_section "$folder_path" "$add_blob" "$del_blob" "$folder_blob"
        done
    done
}

render_plan_tree_folder_section() {
    local folder_path="$1"
    local add_blob="$2"
    local del_blob="$3"
    local folder_blob="$4"

    local folder_label
    folder_label="$(format_plan_tree_folder_label "$folder_path")"

    local folder_id_hint=""
    if [[ -n "$folder_blob" ]]; then
        local joined=""
        while IFS= read -r folder_id; do
            [[ -z "$folder_id" ]] && continue
            if [[ -z "$joined" ]]; then
                joined="$folder_id"
            else
                joined+=", $folder_id"
            fi
        done <<<"$folder_blob"
        folder_id_hint=" ${DIM}<${joined}>${NC}"
    fi

    local base_indent="      "
    local child_indent="        "

    local has_add="false"
    local has_folder_delete="false"
    [[ -n "$add_blob" ]] && has_add="true"
    [[ -n "$folder_blob" ]] && has_folder_delete="true"
    local show_neutral="false"
    if [[ -n "$folder_path" && "$has_add" == true && "$has_folder_delete" == true ]]; then
        show_neutral="true"
    fi

    log INFO ""

    if [[ "$show_neutral" == "true" ]]; then
        log INFO "${base_indent}${BOLD}${folder_label}${NC}${folder_id_hint}"
    else
        local printed_header=false
        if [[ -n "$folder_path" && -n "$add_blob" ]]; then
            log INFO "${GREEN}${base_indent}[+] ${BOLD}${folder_label}${NC}"
            printed_header=true
        fi
        if [[ -n "$folder_path" && ( -n "$del_blob" || -n "$folder_blob" ) ]]; then
            log INFO "${RED}${base_indent}[-] ${BOLD}${folder_label}${NC}${folder_id_hint}"
            printed_header=true
        elif [[ -z "$folder_path" && -n "$folder_blob" ]]; then
            log INFO "${RED}${base_indent}[-] ${BOLD}/${NC}${folder_id_hint}"
            printed_header=true
        fi
        if [[ "$printed_header" == false ]]; then
            log INFO "${base_indent}${BOLD}${folder_label}${NC}${folder_id_hint}"
        fi
    fi

    local add_indent="$base_indent"
    local del_indent="$base_indent"
    if [[ -n "$folder_path" ]]; then
        add_indent="$child_indent"
        del_indent="$child_indent"
    fi

    render_plan_tree_workflow_lines "$add_blob" "$GREEN" "[+]" "add" "$add_indent"
    render_plan_tree_workflow_lines "$del_blob" "$RED" "[-]" "del" "$del_indent"
}

render_plan_tree_workflow_lines() {
    local blob="$1"
    local color="$2"
    local symbol="$3"
    local mode="$4"
    local indent="${5:-      }"

    [[ -z "$blob" ]] && return 0

    declare -a lines=()
    mapfile -t lines < <(printf '%s' "$blob" | awk 'NF')
    local line
    for line in "${lines[@]}"; do
        local saved_ifs="$IFS"
        IFS=$'	'
        if [[ "$mode" == "add" ]]; then
            local wf_label repo_relative
            read -r wf_label repo_relative <<<"$line"
            IFS="$saved_ifs"
            # Sanitize project name to match file system representation
            wf_label="$(sanitize_filename_component "$wf_label")"
            repo_relative="$(sanitize_filename_component "$repo_relative")"
            local entry_label="$repo_relative"
            [[ -z "$entry_label" ]] && entry_label="$wf_label"
            entry_label="${entry_label%.json}"
            entry_label="${entry_label##*/}"
            log INFO "${color}${indent}${symbol} ${entry_label}${NC}"
        else
            local wf_label wf_id archived_flag
            read -r wf_label wf_id archived_flag <<<"$line"
            IFS="$saved_ifs"
            # Sanitize project name to match file system representation
            wf_label="$(sanitize_filename_component "$wf_label")"
            local id_hint=""
            if [[ -n "$wf_id" ]]; then
                id_hint=" ${DIM}<${wf_id}>${NC}"
            fi
            local archived_hint=""
            if [[ "$archived_flag" == "true" ]]; then
                archived_hint=" ${DIM}[archived]${NC}"
            fi
            log INFO "${color}${indent}${symbol} ${wf_label}${id_hint}${archived_hint}${NC}"
        fi
    done
}

reset_plan_scope_project_label() {
    local snapshot_json="${RESET_PLAN_SNAPSHOT_JSON:-}" 
    local project=""
    if [[ -n "$project_name" ]]; then
        project="$project_name"
    fi
    if [[ -z "$project" ]]; then
        local scope="${RESET_PLAN_SCOPE_LABEL#/}"
        scope="${scope%/}"
        project="${scope%%/*}"
    fi
    if [[ -z "$project" && ${#RESET_PLAN_WORKFLOW_PROJECT[@]} -gt 0 ]]; then
        for identifier in "${!RESET_PLAN_WORKFLOW_PROJECT[@]}"; do
            local candidate="${RESET_PLAN_WORKFLOW_PROJECT[$identifier]}"
            if [[ -n "$candidate" ]]; then
                project="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$project" || "$project" == "/" ]]; then
        project="$(project_display_label)"
    fi
    local resolved_personal
    resolved_personal="$(resolve_personal_project_name)"
    if [[ "${project,,}" == "personal" || "$project" == "$PERSONAL_PROJECT_TOKEN" || "$project" == "%PERSONAL_PROJECT%" ]]; then
        project="$resolved_personal"
    fi
    # Sanitize project name to match file system representation
    project="$(sanitize_filename_component "$project")"
    printf '%s' "$project"
}

format_plan_tree_folder_label() {
    local folder_path="${1:-}"
    folder_path="${folder_path#/}"
    folder_path="${folder_path%/}"

    if [[ -z "$folder_path" ]]; then
        printf '/'
    else
        printf '%s/' "$folder_path"
    fi
}

reset_plan_sanitize_token() {
    local token="${1:-}"
    token="${token//$'\r'/}"
    token="${token//$'\n'/}"
    token="${token//$'\t'/ }"
    printf '%s' "$token"
}

reset_plan_resolved_scope_label() {
    local label="${RESET_PLAN_SCOPE_LABEL:-/}"
    local scope_project_resolved="${RESET_PLAN_PROJECT_NAME:-$(resolve_personal_project_name)}"
    # Sanitize project name to match file system representation
    scope_project_resolved="$(sanitize_filename_component "$scope_project_resolved")"
    if [[ "$scope_project_resolved" == "$PERSONAL_PROJECT_TOKEN" || "$scope_project_resolved" == "%PERSONAL_PROJECT%" ]]; then
        scope_project_resolved="Personal"
    fi
    if [[ "$label" == *"%PERSONAL_PROJECT%"* || "$label" == *"%PROJECT%"* ]]; then
        label="${label//%PERSONAL_PROJECT%/$scope_project_resolved}"
        label="${label//%PROJECT%/$scope_project_resolved}"
    fi
    if [[ "${label,,}" == "personal" || "${label,,}" == "personal/" ]]; then
        label="$scope_project_resolved"
        label="${label%/}"
    fi
    if [[ -z "$label" ]]; then
        label="/"
    fi
    printf '%s' "$label"
}

display_plan_warnings() {
    local warning_count=${#RESET_PLAN_WARNINGS[@]}
    ((warning_count == 0)) && return 0
    log WARN "${BOLD}⚠ Warnings:${NC}"
    local warning
    for warning in "${RESET_PLAN_WARNINGS[@]}"; do
        log WARN "  • $warning"
    done
    echo ""
}

display_reset_plan() {
    display_plan_header
    display_target_info
    display_mode_info
    log INFO "${BOLD}Scope:${NC} $(reset_plan_resolved_scope_label)"
    display_plan_tree
    display_plan_warnings
}

prompt_for_confirmation() {
    if [[ "$RESET_PLAN_DRY_RUN" == "true" ]]; then
        log DRYRUN "Dry-run mode: skipping execution"
        return 2
    fi

    local has_destructive=false
    if [[ "$RESET_PLAN_MODE" == "hard" ]]; then
        has_destructive=true
    fi

    if [[ "${assume_defaults:-false}" == "true" ]]; then
        if [[ "$has_destructive" == true ]]; then
            log WARN "Assume-defaults enabled: auto-confirming destructive reset"
        else
            log INFO "Assume-defaults enabled: auto-confirming reset"
        fi
        return 0
    fi
    echo ""

    if [[ "$has_destructive" == true ]]; then
        log WARN "${BOLD}Hard reset: ${RED}DESTRUCTIVE OPERATION${NC}"
        log WARN "This action will permanently delete workflows and folders."
        echo ""
    fi
    
    log INFO "${BOLD}Proceed with reset?${NC} [y/N]: "
    local response=""
    read -r response
    case "${response,,}" in
        y|yes)
            log INFO "Reset confirmed by user"
            return 0
            ;;
        *)
            log WARN "Reset aborted by user"
            return 130
            ;;
    esac
}

display_reset_summary() {
    local exit_code="${1:-0}"
    log HEADER "Reset Summary"

    if [[ $exit_code -eq 0 ]]; then
        if [[ -n "$RESET_PLAN_TARGET_SHA" ]]; then
            log INFO "Target:  ${RESET_PLAN_TARGET_DISPLAY:-${RESET_PLAN_TARGET_SHA:0:12}} (${RESET_PLAN_TARGET_SHA:0:12})"
        else
            log INFO "Target:  ${RESET_PLAN_TARGET_DISPLAY:-current}"
        fi
        log INFO "Mode:    ${RESET_PLAN_MODE}"
        log INFO "Scope:   $(reset_plan_resolved_scope_label)"
        echo ""
        log INFO "Completed actions:"
        log INFO "  • Removed workflows: ${RESET_PLAN_REMOVAL_COUNT_WORKFLOWS}"
        log INFO "  • Removed folders:   ${RESET_PLAN_REMOVAL_COUNT_FOLDERS}"
        if ((${#RESET_PLAN_PRESERVED_WORKFLOWS[@]} > 0)); then
            log INFO "  • Preserved by ID: ${RESET_PLAN_PRESERVED_WORKFLOWS[*]}"
        fi
    elif [[ $exit_code -eq 130 ]]; then
        log INFO "Reset aborted by user - no changes made"
    elif [[ $exit_code -eq 2 ]]; then
        log ERROR "Reset failed during validation"
    else
        log ERROR "Reset failed during execution (exit code: $exit_code)"
        log INFO "Review workspace state before retrying."
    fi
}

get_exit_status_message() {
    local exit_code="$1"
    case $exit_code in
        0) echo "Success" ;;
        1) echo "Execution failure" ;;
        2) echo "Validation failure" ;;
        130) echo "User aborted" ;;
        *) echo "Unknown error (code: $exit_code)" ;;
    esac
}

# ---------------------------------------------------------
# Exported functions
# ---------------------------------------------------------
export -f init_reset_plan
export -f compute_workflow_diff
export -f get_action_counts
export -f get_reset_plan_json
export -f register_incoming_workflow_ids
export -f preserve_workflows
export -f add_plan_warning
export -f display_reset_plan
export -f prompt_for_confirmation
export -f display_reset_summary
export -f get_exit_status_message
