#!/usr/bin/env bash

# shellcheck disable=SC2034

WORKFLOW_COUNT_FILTER=$(cat <<'JQ'
def to_array:
    if type == "array" then .
    elif type == "object" then
        if (has("data") and (.data | type == "array")) then .data
        elif (has("workflows") and (.workflows | type == "array")) then .workflows
        elif (has("items") and (.items | type == "array")) then .items
        else [.] end
    else [] end;
to_array
| map(select(
        (type == "object") and (
            (((.resource // .type // "") | tostring | ascii_downcase) == "workflow")
            or (.nodes? | type == "array")
        )
    ))
| length
JQ
)
readonly WORKFLOW_COUNT_FILTER

capture_existing_workflow_snapshot() {
    local container_id="$1"
    local keep_session_alive="${2:-false}"
    local existing_path="${3:-}"
    local is_dry_run="${4:-false}"
    local result_ref="${5:-}"

    local result="$existing_path"
    local status=0

    if [[ "$is_dry_run" == "true" ]]; then
        status=0
    elif [[ -n "$existing_path" && -f "$existing_path" ]]; then
        status=0
    else
        SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
        if snapshot_existing_workflows "$container_id" "" "$keep_session_alive"; then
            result="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
            status=0
        else
            result=""
            status=1
        fi
    fi

    if [[ -n "$result_ref" ]]; then
        printf -v "$result_ref" '%s' "$result"
    else
        printf '%s' "$result"
    fi

    return "$status"
}

find_workflow_directory() {
    local candidate
    for candidate in "$@"; do
        if [[ -z "$candidate" || ! -d "$candidate" ]]; then
            continue
        fi
        if [[ -n "$(find "$candidate" -type f -name "*.json" \
            ! -path "*/.credentials/*" \
            ! -path "*/archive/*" \
            ! -name "credentials.json" \
            ! -name "workflows.json" \
            -print -quit 2>/dev/null)" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

locate_workflow_artifacts() {
    local base_dir="$1"
    local repo_root="$2"
    local storage_relative="$3"
    local result_workflows_ref="$4"
    local result_directory_ref="$5"

    log DEBUG "locate_workflow_artifacts called with base_dir='$base_dir' repo_root='$repo_root'"

    local -n __workflows_out="$result_workflows_ref"
    local -n __directory_out="$result_directory_ref"

    __workflows_out=""
    __directory_out=""

    if [[ -n "$base_dir" && -f "$base_dir/workflows.json" ]]; then
        __workflows_out="$base_dir/workflows.json"
    elif [[ -n "$repo_root" && -f "$repo_root/workflows.json" ]]; then
        __workflows_out="$repo_root/workflows.json"
    fi

    local -a structure_candidates=()
    if [[ -n "$storage_relative" ]]; then
        local trimmed_storage
        trimmed_storage="${storage_relative#/}"
        trimmed_storage="${trimmed_storage%/}"
        if [[ -n "$trimmed_storage" ]]; then
            structure_candidates+=("$base_dir/$trimmed_storage")
            if [[ -n "$repo_root" ]]; then
                structure_candidates+=("$repo_root/$trimmed_storage")
            fi
            structure_candidates+=("$base_dir/$trimmed_storage/workflows")
            if [[ -n "$repo_root" ]]; then
                structure_candidates+=("$repo_root/$trimmed_storage/workflows")
            fi
        fi
    fi

    structure_candidates+=("$base_dir/workflows")
    if [[ -n "$repo_root" ]]; then
        structure_candidates+=("$repo_root/workflows")
    fi

    structure_candidates+=("$base_dir")
    if [[ -n "$repo_root" ]]; then
        structure_candidates+=("$repo_root")
    fi

    local detected_dir
    if detected_dir=$(find_workflow_directory "${structure_candidates[@]}"); then
        __directory_out="$detected_dir"
    else
        log DEBUG "locate_workflow_artifacts: No directory found in candidates: ${structure_candidates[*]}"
    fi
}

locate_credentials_artifact() {
    local base_dir="$1"
    local repo_root="$2"
    local credentials_dir_relative="$3"
    local credentials_file_relative="${4:-}"
    local result_ref="$5"
    local result_type_ref="${6:-}"

    local -n __credentials_out="$result_ref"
    __credentials_out=""

    local has_type_ref=false
    if [[ -n "$result_type_ref" ]]; then
        has_type_ref=true
        # shellcheck disable=SC2178  # indirect reference used intentionally
        local -n __credentials_type_out="$result_type_ref"
        __credentials_type_out=""
    fi

    local -a dir_candidates=()
    if [[ -n "$credentials_dir_relative" ]]; then
        dir_candidates+=("$base_dir/$credentials_dir_relative")
        if [[ -n "$repo_root" ]]; then
            dir_candidates+=("$repo_root/$credentials_dir_relative")
        fi
    fi

    local candidate
    for candidate in "${dir_candidates[@]}"; do
        if [[ -z "$candidate" ]]; then
            continue
        fi
        candidate="${candidate%/}"
        if [[ -d "$candidate" ]]; then
            __credentials_out="$candidate"
            if $has_type_ref; then
                __credentials_type_out="directory"
            fi
            return 0
        fi
    done

    local -a file_candidates=()
    if [[ -n "$credentials_file_relative" ]]; then
        file_candidates+=("$base_dir/$credentials_file_relative")
        if [[ -n "$repo_root" ]]; then
            file_candidates+=("$repo_root/$credentials_file_relative")
        fi
    else
        file_candidates+=("$base_dir/credentials.json")
        if [[ -n "$repo_root" ]]; then
            file_candidates+=("$repo_root/credentials.json")
        fi
    fi

    for candidate in "${file_candidates[@]}"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            __credentials_out="$candidate"
            if $has_type_ref; then
                __credentials_type_out="file"
            fi
            return 0
        fi
    done

    return 1
}

bundle_credentials_directory() {
    local source_dir="$1"
    local output_file="$2"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Credential directory not found: ${source_dir:-<empty>}"
        return 1
    fi

    if [[ -z "$output_file" ]]; then
        log ERROR "Output file path required to bundle credentials"
        return 1
    fi

    mapfile -t credential_files < <(find "$source_dir" -maxdepth 1 -type f -name '*.json' -print | sort)

    local tmp_output
    tmp_output=$(mktemp /tmp/n8n-credential-bundle-XXXXXXXX)

    if ((${#credential_files[@]} == 0)); then
        printf '[]' >"$tmp_output"
    else
        if ! jq -s '.' "${credential_files[@]}" >"$tmp_output" 2>/dev/null; then
            log ERROR "Failed to assemble credentials from $source_dir"
            rm -f "$tmp_output"
            return 1
        fi
    fi

    if ! mv "$tmp_output" "$output_file"; then
        log ERROR "Unable to persist credential bundle to $output_file"
        rm -f "$tmp_output"
        return 1
    fi

    chmod 600 "$output_file" 2>/dev/null || true
    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "Bundled ${#credential_files[@]} credential file(s) from $source_dir"
    fi
    return 0
}

persist_manifest_debug_copy() {
    local source_path="$1"
    local target_path="$2"
    local description="${3:-manifest}"

    if [[ -z "$target_path" || -z "$source_path" || ! -f "$source_path" ]]; then
        return 0
    fi

    if cp "$source_path" "$target_path" 2>/dev/null; then
        log DEBUG "Persisted ${description} to $target_path"
    else
        log DEBUG "Unable to persist ${description} to $target_path"
    fi
    return 0
}

append_sanitized_note() {
    local existing="${1:-}"
    local addition="${2:-}"

    if [[ -z "$addition" ]]; then
        printf '%s\n' "$existing"
        return 0
    fi

    if [[ -z "$existing" ]]; then
        printf '%s\n' "$addition"
        return 0
    fi

    local needle=";$addition;"
    local haystack=";$existing;"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '%s\n' "$existing"
        return 0
    fi

    printf '%s\n' "${existing};${addition}"
    return 0
}

normalize_entry_identifier() {
    local value="${1:-}"
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf ''
        return
    fi

    value="$(printf '%s' "$value" | tr -d '\r\n\t')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"

    case "$value" in
        0)
            printf ''
            return
            ;;
    esac

    local lowered
    lowered=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    if [[ "$lowered" == "root" ]]; then
        printf ''
        return
    fi

    printf '%s' "$value"
}
