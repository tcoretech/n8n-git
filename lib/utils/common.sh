#!/usr/bin/env bash
# =========================================================
# lib/utils/common.sh - Common utilities for n8n-git
# =========================================================
# Core utilities: logging, configuration, dependencies, Git helpers
# Used by all other modules in the n8n-git system

set -Eeuo pipefail
IFS=$'\n\t'

# --- Global variables ---
: "${PROJECT_NAME:=n8n Git}"
export PROJECT_NAME
: "${VERSION:=1.0.0}"
export VERSION
DEBUG_TRACE=${DEBUG_TRACE:-false} # Set to true for trace debugging

git_commit_name="${git_commit_name:-}"
git_commit_email="${git_commit_email:-}"

# Default location for storing credentials inside Git repositories
: "${credentials_folder_name:=.credentials}"

# Ensure configuration source trackers exist even when scripts source this module standalone
: "${workflows_source:=unset}"
: "${credentials_source:=unset}"
: "${local_backup_path_source:=unset}"
: "${dry_run_source:=unset}"
: "${assume_defaults:=}"
: "${folder_structure_source:=unset}"
: "${credentials_encrypted_source:=unset}"
: "${assume_defaults_source:=unset}"
: "${container_source:=unset}"
: "${environment_source:=unset}"
: "${github_path_source:=unset}"
: "${n8n_path_source:=unset}"
: "${project_name_source:=unset}"
: "${CONFIG_MODE_BYPASS_LOG_FILE:=false}"
: "${ACTIVE_CONFIG_PATH:=}"

# Suggested default log file path (user-writable)
DEFAULT_LOG_FILE_PATH="${XDG_STATE_HOME:-$HOME/.local/state}/n8n-git/n8n-git.log"
LOG_FILE_SUGGESTED_PATH="$DEFAULT_LOG_FILE_PATH"

PERSONAL_PROJECT_TOKEN="%PERSONAL_PROJECT%"
personal_project_hint="${personal_project_hint:-}"

project_name="${project_name:-$PERSONAL_PROJECT_TOKEN}"

github_path="${github_path:-}"
n8n_path="${n8n_path:-}"
: "${N8N_GIT_DOCKER_BIN:=}"

# ANSI colors for better UI (using printf for robustness)
# Using TrueColor (24-bit) ANSI escape codes based on user specification
printf -v BLUE    '\033[38;2;97;175;239m'  # INFO: #61AFEF
printf -v RED     '\033[38;2;224;108;117m' # ERROR: #E06C75
printf -v GREEN   '\033[38;2;152;195;121m' # SUCCESS: #98C379
printf -v YELLOW  '\033[38;2;229;192;123m' # WARNING: #E5C07B
printf -v CYAN    '\033[38;2;86;182;194m'  # TEST: #56B6C2
printf -v MAGENTA '\033[38;2;86;182;194m'  # DRYRUN (Mapped to TEST color)
printf -v NORMAL  '\033[38;2;233;236;236m' # NORMAL: #E9ECEC
printf -v NC      '\033[0m'                # Reset
printf -v BOLD    '\033[1m'
printf -v DIM     '\033[2m'

if [[ -z "${SESSION_DATE:-}" ]]; then
    SESSION_DATE="$(date +%Y-%m-%d)"
fi
if [[ -z "${SESSION_DATETIME:-}" ]]; then
    SESSION_DATETIME="$(date +%Y-%m-%d_%H-%M-%S)"
fi
if [[ -z "${SESSION_YEAR:-}" ]]; then
    SESSION_YEAR="$(date +%Y)"
fi
if [[ -z "${SESSION_YEAR_SHORT:-}" ]]; then
    SESSION_YEAR_SHORT="$(date +%y)"
fi
if [[ -z "${SESSION_MONTH:-}" ]]; then
    SESSION_MONTH="$(date +%m)"
fi
if [[ -z "${SESSION_DAY:-}" ]]; then
    SESSION_DAY="$(date +%d)"
fi
if [[ -z "${SESSION_HOUR:-}" ]]; then
    SESSION_HOUR="$(date +%H)"
fi
if [[ -z "${SESSION_MINUTE:-}" ]]; then
    SESSION_MINUTE="$(date +%M)"
fi
if [[ -z "${SESSION_SECOND:-}" ]]; then
    SESSION_SECOND="$(date +%S)"
fi
export SESSION_DATE SESSION_DATETIME SESSION_YEAR SESSION_YEAR_SHORT SESSION_MONTH SESSION_DAY SESSION_HOUR SESSION_MINUTE SESSION_SECOND

# --- Git Helper Functions ---
# These functions isolate Git operations to avoid parse errors
git_add() {
    local repo_dir="$1"
    local target="$2"
    git -C "$repo_dir" add "$target"
    return $?
}

git_commit() {
    local repo_dir="$1"
    local message="$2"
    git -C "$repo_dir" commit -m "$message"
    return $?
}

git_push() {
    local repo_dir="$1"
    local remote="$2"
    local branch="$3"
    git -C "$repo_dir" push -u "$remote" "$branch"
    return $?
}

# --- Storage Value Formatting ---
format_storage_value() {
    local value="$1"
    case "$value" in
        0) echo "disabled" ;;
        1) echo "local" ;;
        2) echo "remote" ;;
        *) echo "unknown" ;;
    esac
}

normalize_boolean_option() {
    local raw_value="${1:-false}"
    raw_value=$(printf '%s' "$raw_value" | tr '[:upper:]' '[:lower:]')
    case "$raw_value" in
        true|1|yes|y|on)
            printf 'true'
            ;;
        *)
            printf 'false'
            ;;
    esac
}

cleanup_temp_path() {
    local target="${1:-}"
    [[ -z "$target" ]] && return 0

    if [[ -d "$target" || -f "$target" ]]; then
        rm -rf "$target" 2>/dev/null
        return $?
    fi

    return 0
}

# --- Debug/Trace Function ---
trace_cmd() {
    if $DEBUG_TRACE; then
        echo -e "\033[0;35m[TRACE] Running command: $*\033[0m" >&2
        "$@"
        local ret=$?
        echo -e "\033[0;35m[TRACE] Command returned: $ret\033[0m" >&2
        return $ret
    else
        "$@"
        return $?
    fi
}

# Simplified and sanitized log function to avoid command not found errors
log() {
    # Define parameters
    local level="$1"
    local message="$2"
: "${LOG_FILE_DISABLED:=true}"
    
    # Skip debug messages if verbose is not enabled
    if [ "$level" = "DEBUG" ] && [ "${verbose:-false}" != "true" ]; then 
        return 0;
    fi
    
    # Set color based on level
    local color=""
    local prefix=""
    local to_stderr=false
    
    if [ "$level" = "DEBUG" ]; then
        color="$DIM"
        prefix="⚙ "
        to_stderr=true
    elif [ "$level" = "INFO" ]; then
        color="$BLUE"
        prefix="  "
    elif [ "$level" = "WARN" ]; then
        color="$YELLOW"
        prefix="⚠ "
        to_stderr=true
    elif [ "$level" = "SECURITY" ]; then
        color="$YELLOW"
        prefix="🔒 "
        to_stderr=true
    elif [ "$level" = "ERROR" ]; then
        color="$RED"
        prefix="✖ "
        to_stderr=true
    elif [ "$level" = "SUCCESS" ]; then
        color="$GREEN"
        prefix="✔ "
    elif [ "$level" = "TEST" ]; then
        color="$CYAN"
        prefix="🔍 "
    elif [ "$level" = "HEADER" ]; then
        color="$BLUE$BOLD"
        # Calculate padding for centered text (target width ~60 chars)
        local target_width=60
        local msg_len=${#message}
        local pad_len=$(( (target_width - msg_len - 2) / 2 )) # -2 for spaces
        if [ $pad_len -lt 2 ]; then pad_len=2; fi # Minimum padding

        local padding
        padding=$(printf '%0.s═' $(seq 1 $pad_len))
        local extra_pad=""
        # Adjust for odd lengths to ensure total width is even if possible, or just balanced
        if [ $(( pad_len * 2 + msg_len + 2 )) -lt $target_width ]; then extra_pad="═"; fi
        
        message="\n${padding} ${message} ${padding}${extra_pad}\n"
        prefix=""
    elif [ "$level" = "DRYRUN" ]; then
        color="$CYAN"
        prefix="🔍"
    else
        prefix="[$level]"
    fi
    
    # Format message
    local formatted
    if [ -n "$prefix" ]; then
        if [ "$level" = "DEBUG" ] || [ "$level" = "ERROR" ]; then
            formatted="${color}${prefix} ${message}${NC}"
        else
            formatted="${color}${prefix} ${message}${NC}"
        fi
    else
        formatted="${color}${message}${NC}"
    fi
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
    local plain="${timestamp} ${prefix} ${message}"
    
    # Output
    if [ "$to_stderr" = "true" ]; then
        echo -e "$formatted" >&2
    else
        echo -e "$formatted"
    fi
    
    # Log to file if specified (skip for sensitive messages)
    if [ -n "${log_file:-}" ] && [ "${LOG_FILE_DISABLED}" != "true" ] && [ "$level" != "SECURITY" ]; then
        if ! echo "$plain" >> "$log_file" 2>/dev/null; then
            LOG_FILE_DISABLED=true
            printf '%s\n' "WARN: log file is not writable at '$log_file'. Disabling file logging for this run." >&2
        fi
    fi
    
    return 0
}

# --- Docker CLI Detection ---

_n8n_git_resolve_docker_cli() {
    if [[ -n "${N8N_GIT_DOCKER_BIN:-}" ]]; then
        return 0
    fi

    local -a candidates=()

    if [[ -n "${N8N_GIT_DOCKER_BIN_OVERRIDE:-}" ]]; then
        candidates+=("$N8N_GIT_DOCKER_BIN_OVERRIDE")
    fi

    local running_in_wsl=false
    if grep -qi microsoft /proc/version 2>/dev/null; then
        running_in_wsl=true
    fi

    if $running_in_wsl; then
        candidates+=("docker.exe" "docker")
    else
        candidates+=("docker" "docker.exe")
    fi

    local candidate
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue

        local candidate_path=""
        if [[ "$candidate" == */* || "$candidate" == *\\* ]]; then
            candidate_path="$candidate"
        else
            candidate_path=$(type -P "$candidate" 2>/dev/null || true)
        fi
        [[ -z "$candidate_path" ]] && continue

        if "$candidate_path" --version >/dev/null 2>&1 || "$candidate_path" version >/dev/null 2>&1; then
            N8N_GIT_DOCKER_BIN="$candidate_path"
            export N8N_GIT_DOCKER_BIN
            return 0
        fi
    done

    log ERROR "Docker CLI not found or not reachable. Install Docker Desktop / dockerd and ensure it is running."
    return 1
}

docker() {
    if ! _n8n_git_resolve_docker_cli; then
        return 1
    fi

    command "$N8N_GIT_DOCKER_BIN" "$@"
}

ensure_docker_available() {
    if ! _n8n_git_resolve_docker_cli; then
        return 1
    fi

    if [[ "${N8N_GIT_DOCKER_READY:-}" == "1" ]]; then
        return 0
    fi

    local docker_output=""
    if ! docker ps -q >/dev/null 2>&1; then
        docker_output=$(docker ps -q 2>&1 || true)
        log ERROR "Docker daemon is unavailable (docker ps failed)."
        log INFO "Docker output: ${docker_output:-<none>}"
        log INFO "Ensure Docker Desktop/dockerd is running and accessible from this shell."
        log INFO "For WSL users, enable Docker Desktop → Settings → Resources → WSL Integration for this distro."
        return 1
    fi

    N8N_GIT_DOCKER_READY=1
    return 0
}

# --- Filename Utilities ---
sanitize_filename_component() {
    local input="$1"
    local max_len="${2:-152}"

    local cleaned
    cleaned="$(printf '%s' "$input" | tr -d '\000')"
    cleaned="$(printf '%s' "$cleaned" | tr '\r\n\t' '   ')"
    # Replace < with [ and > with ] for better readability
    cleaned="$(printf '%s' "$cleaned" | sed -e 's/</[/g' -e 's/>/]/g')"
    cleaned="$(printf '%s' "$cleaned" | sed -e 's/[[:cntrl:]]//g' -e 's#[\\/:*?"|]#-#g')"
    cleaned="$(printf '%s' "$cleaned" | sed -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"

    while [[ "$cleaned" =~ [[:space:].]$ ]]; do
        cleaned="${cleaned%?}"
    done

    if (( max_len > 0 && ${#cleaned} > max_len )); then
        cleaned="${cleaned:0:max_len}"
        while [[ "$cleaned" =~ [[:space:].]$ ]]; do
            cleaned="${cleaned%?}"
        done
    fi

    printf '%s\n' "$cleaned"
}

format_project_path_label() {
    local raw_name="${1-}"
    local trimmed_name
    trimmed_name="$(printf '%s' "$raw_name" | tr -d '\r')"
    trimmed_name="$(printf '%s' "$trimmed_name" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"

    local name_only="$trimmed_name"
    local email_part=""
    if [[ "$trimmed_name" == *'<'*'>'* ]]; then
        name_only="$(printf '%s' "$trimmed_name" | sed 's/<[^>]*>//g')"
        name_only="$(printf '%s' "$name_only" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"
        email_part="$(printf '%s' "$trimmed_name" | awk -F'[<>]' 'NF>=3 {print $2}' | head -n1)"
    fi

    if [[ -z "$name_only" ]]; then
        name_only="$trimmed_name"
    fi

    local domain_label=""
    if [[ -n "$email_part" ]]; then
        # Prefer deriving a host label from configured n8n base URL (hostname part)
        # so that project labels reflect the instance host rather than the
        # contributor's email domain. Fall back to email domain if base URL
        # not available or unparsable.
        local host_label=""
        if [[ -n "${n8n_base_url:-}" ]]; then
            # Extract hostname from URL (strip scheme and port)
            host_label="$(printf '%s' "$n8n_base_url" | sed -E 's#^[a-zA-Z]+://##; s#/.*##; s/:.*$//')"
        elif [[ -n "${N8N_BASE_URL:-}" ]]; then
            host_label="$(printf '%s' "$N8N_BASE_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*##; s/:.*$//')"
        fi

        if [[ -n "$host_label" && "$host_label" != "null" ]]; then
            domain_label="$host_label"
        else
            domain_label="${email_part#*@}"
            if [[ "$domain_label" == "$email_part" ]]; then
                domain_label=""
            fi
        fi
    fi

    local label=""
    if [[ -n "$domain_label" ]]; then
        label="($domain_label)"
        if [[ -n "$name_only" ]]; then
            label+=" $name_only"
        fi
    else
        label="$name_only"
    fi

    if [[ -z "$label" ]]; then
        label="$raw_name"
    fi

    label="$(printf '%s' "$label" | sed 's#[\\/:*?"<>|]#-#g')"
    label="$(printf '%s' "$label" | sed 's/[[:space:]]\+/ /g')"
    label="$(printf '%s' "$label" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"

    printf '%s' "$label"
}

is_personal_project_token() {
    local candidate="${1:-}"
    if [[ -z "$candidate" ]]; then
        return 1
    fi
    [[ "${candidate^^}" == "${PERSONAL_PROJECT_TOKEN^^}" ]]
}

resolve_personal_project_name() {
    local hint="${personal_project_hint:-}"
    if [[ -z "$hint" && -n "${N8N_PERSONAL_PROJECT_NAME:-}" ]]; then
        hint="$N8N_PERSONAL_PROJECT_NAME"
    fi

    if [[ -z "$hint" || "$hint" == "$PERSONAL_PROJECT_TOKEN" || "$hint" == "%PERSONAL_PROJECT%" || "${hint,,}" == "personal" ]]; then
        local derived=""
        if [[ -z "$derived" && -n "${N8N_PROJECTS_LAST_SUCCESS_JSON:-}" ]]; then
            derived=$(printf '%s' "$N8N_PROJECTS_LAST_SUCCESS_JSON" | jq -r '
                (if type == "array" then . else (.data // []) end)
                | map(select((.type // "") == "personal") | .name // empty)
                | map(select(. != "" and . != "null"))
                | first // empty
            ' 2>/dev/null || echo "")
        fi
        if [[ -z "$derived" && -n "${N8N_PROJECTS_CACHE_JSON:-}" ]]; then
            derived=$(printf '%s' "$N8N_PROJECTS_CACHE_JSON" | jq -r '
                (if type == "array" then . else (.data // []) end)
                | map(select((.type // "") == "personal") | .name // empty)
                | map(select(. != "" and . != "null"))
                | first // empty
            ' 2>/dev/null || echo "")
        fi
        if [[ -z "$derived" && -n "${N8N_PROJECT:-}" && "${N8N_PROJECT}" != "$PERSONAL_PROJECT_TOKEN" && "${N8N_PROJECT}" != "%PERSONAL_PROJECT%" ]]; then
            derived="$N8N_PROJECT"
        fi
        if [[ -n "$derived" ]]; then
            hint="$derived"
            remember_personal_project_name "$hint"
        fi
    fi

    hint="$(printf '%s' "$hint" | tr -d '\r')"
    hint="$(printf '%s' "$hint" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"

    if [[ -n "$hint" ]]; then
        printf '%s\n' "$hint"
    else
        printf '%s\n' "$PERSONAL_PROJECT_TOKEN"
    fi
}

effective_project_name() {
    local candidate="${1:-}"
    if is_personal_project_token "$candidate" || [[ -z "$candidate" ]]; then
        resolve_personal_project_name
        return
    fi
    printf '%s\n' "$candidate"
}

project_effective_name() {
    effective_project_name "${project_name:-$PERSONAL_PROJECT_TOKEN}"
}

project_display_label() {
    local name
    name="$(project_effective_name)"
    printf '%s\n' "$name"
}

remember_personal_project_name() {
    local candidate="${1:-}"
    candidate="$(printf '%s' "$candidate" | tr -d '\r')"
    candidate="$(printf '%s' "$candidate" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"
    if [[ -z "$candidate" || "$candidate" == "null" ]]; then
        return 0
    fi

    personal_project_hint="$candidate"
    if [[ -z "${project_name:-}" || "${project_name}" == "$PERSONAL_PROJECT_TOKEN" || "${project_name}" == "%PERSONAL_PROJECT%" ]]; then
        project_name="$candidate"
    fi

    # Update N8N_PROJECT if it contains the token
    if [[ "${N8N_PROJECT:-}" == *"${PERSONAL_PROJECT_TOKEN}"* || "${N8N_PROJECT:-}" == *"%PERSONAL_PROJECT%"* ]]; then
        N8N_PROJECT="${N8N_PROJECT//${PERSONAL_PROJECT_TOKEN}/$candidate}"
        # Also handle literal %PERSONAL_PROJECT% if token differs (though it shouldn't)
        if [[ "${N8N_PROJECT}" == *"%PERSONAL_PROJECT%"* ]]; then
            N8N_PROJECT="${N8N_PROJECT//%PERSONAL_PROJECT%/$candidate}"
        fi
    elif [[ -z "${N8N_PROJECT:-}" ]]; then
        N8N_PROJECT="$candidate"
    fi

    # Update GITHUB_PATH if it contains the token
    if [[ "${GITHUB_PATH:-}" == *"${PERSONAL_PROJECT_TOKEN}"* || "${GITHUB_PATH:-}" == *"%PERSONAL_PROJECT%"* ]]; then
        GITHUB_PATH="${GITHUB_PATH//${PERSONAL_PROJECT_TOKEN}/$candidate}"
        if [[ "${GITHUB_PATH}" == *"%PERSONAL_PROJECT%"* ]]; then
            GITHUB_PATH="${GITHUB_PATH//%PERSONAL_PROJECT%/$candidate}"
        fi
    fi
}

sanitize_workflow_filename_part() {
    local raw="$1"
    local fallback="$2"

    local sanitized
    sanitized="$(sanitize_filename_component "$raw" 152)"

    if [[ -z "$sanitized" ]]; then
        local fallback_value="Workflow ${fallback:-}";
        sanitized="$(sanitize_filename_component "$fallback_value" 152)"
    fi

    if [[ -z "$sanitized" ]]; then
        sanitized="Workflow"
    fi

    printf '%s\n' "$sanitized"
}

sanitize_credential_filename_part() {
    local raw="$1"
    local fallback="$2"

    local sanitized
    sanitized="$(sanitize_filename_component "$raw" 152)"

    if [[ -z "$sanitized" ]]; then
        local fallback_value="Credential ${fallback:-}";
        sanitized="$(sanitize_filename_component "$fallback_value" 152)"
    fi

    if [[ -z "$sanitized" ]]; then
        sanitized="Credential"
    fi

    printf '%s\n' "$sanitized"
}

generate_unique_credential_filename() {
    local destination_dir="$1"
    local credential_id="$2"
    local credential_name="$3"
    local registry_name="$4"

    if [[ -z "$destination_dir" ]]; then
        return 1
    fi

    # shellcheck disable=SC2178
    local -n registry_ref="$registry_name"

    local base_name
    base_name="$(sanitize_credential_filename_part "$credential_name" "$credential_id")"
    local original_base="$base_name"

    local suffix=0
    local candidate_filename=""

    while true; do
        local suffix_text=""
        if (( suffix > 0 )); then
            suffix_text=" (${suffix})"
        fi

        local allowed_length=$((152 - ${#suffix_text}))
        if (( allowed_length <= 0 )); then
            allowed_length=1
        fi

        local candidate_base="$base_name"
        if (( ${#candidate_base} > allowed_length )); then
            candidate_base="${candidate_base:0:allowed_length}"
            while [[ "$candidate_base" =~ [[:space:].]$ ]]; do
                candidate_base="${candidate_base%?}"
            done
            if [[ -z "$candidate_base" ]]; then
                candidate_base="${original_base:0:allowed_length}"
                while [[ "$candidate_base" =~ [[:space:].]$ ]]; do
                    candidate_base="${candidate_base%?}"
                done
                if [[ -z "$candidate_base" ]]; then
                    candidate_base="Credential"
                fi
            fi
        fi

        local candidate="$candidate_base$suffix_text"
        candidate_filename="$candidate.json"
        local candidate_path="$destination_dir/$candidate_filename"

        local existing_id=""
        if [[ -f "$candidate_path" ]]; then
            existing_id=$(jq -r '.id // empty' "$candidate_path" 2>/dev/null)
        fi

        if [[ -n "$credential_id" && "$existing_id" == "$credential_id" ]]; then
            registry_ref["$candidate_path"]=1
            printf '%s\n' "$candidate_filename"
            return 0
        fi

        if [[ ! -e "$candidate_path" && -z "${registry_ref[$candidate_path]+set}" ]]; then
            registry_ref["$candidate_path"]=1
            printf '%s\n' "$candidate_filename"
            return 0
        fi

        suffix=$((suffix + 1))
    done
}

push_trim_trailing_spaces_and_dots() {
    local value="$1"
    while [[ "$value" =~ [[:space:].]$ ]]; do
        value="${value%?}"
    done
    printf '%s\n' "$value"
}

push_generate_unique_workflow_filename() {
    local destination_dir="$1"
    local workflow_id="$2"
    local workflow_name="$3"
    local registry_name="$4"

    if [[ -z "$destination_dir" ]]; then
        return 1
    fi

    # shellcheck disable=SC2178
    local -n registry_ref="$registry_name"

    local base_name
    base_name="$(sanitize_workflow_filename_part "$workflow_name" "$workflow_id")"
    local original_base="$base_name"

    local suffix=0
    local candidate_filename=""

    while true; do
        local suffix_text=""
        if (( suffix > 0 )); then
            suffix_text=" (${suffix})"
        fi

        local allowed_length=$((152 - ${#suffix_text}))
        if (( allowed_length <= 0 )); then
            allowed_length=1
        fi

        local candidate_base="$base_name"
        if (( ${#candidate_base} > allowed_length )); then
            candidate_base="${candidate_base:0:allowed_length}"
            candidate_base="$(push_trim_trailing_spaces_and_dots "$candidate_base")"
            if [[ -z "$candidate_base" ]]; then
                candidate_base="${original_base:0:allowed_length}"
                candidate_base="$(push_trim_trailing_spaces_and_dots "$candidate_base")"
                if [[ -z "$candidate_base" ]]; then
                    candidate_base="Workflow"
                fi
            fi
        fi

        local candidate="$candidate_base$suffix_text"
        candidate_filename="$candidate.json"
        local candidate_path="$destination_dir/$candidate_filename"

        local existing_id=""
        if [[ -f "$candidate_path" ]]; then
            existing_id=$(jq -r '.id // empty' "$candidate_path" 2>/dev/null)
        fi

        if [[ -n "$workflow_id" && "$existing_id" == "$workflow_id" ]]; then
            registry_ref["$candidate_path"]=1
            printf '%s\n' "$candidate_filename"
            return 0
        fi

        if [[ ! -e "$candidate_path" && -z "${registry_ref[$candidate_path]+set}" ]]; then
            registry_ref["$candidate_path"]=1
            printf '%s\n' "$candidate_filename"
            return 0
        fi

        suffix=$((suffix + 1))
    done
}

push_prettify_json_file() {
    local file_path="$1"
    local is_dry_run="${2:-false}"

    if [[ ! -f "$file_path" ]]; then
        return 0
    fi

    if [[ "$is_dry_run" == "true" ]]; then
        log DEBUG "Skipping JSON prettify (dry run): $file_path"
        return 0
    fi

    local file_dir
    file_dir="$(dirname "$file_path")"

    local tmp_file
    tmp_file=$(mktemp "$file_dir/.n8n-pretty-json.XXXXXXXX") 2>/dev/null || {
        log WARN "Failed to allocate temp file for prettifying: $file_path"
        return 1
    }

    local original_mode=""
    if stat -c '%a' "$file_path" >/dev/null 2>&1; then
        original_mode=$(stat -c '%a' "$file_path" 2>/dev/null || true)
    elif stat -f '%Lp' "$file_path" >/dev/null 2>&1; then
        original_mode=$(stat -f '%Lp' "$file_path" 2>/dev/null || true)
    fi

    if ! jq '.' "$file_path" >"$tmp_file" 2>/dev/null; then
        log WARN "jq failed to prettify JSON file: $file_path"
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv "$tmp_file" "$file_path" 2>/dev/null; then
        if ! cat "$tmp_file" >"$file_path"; then
            log WARN "Failed to write prettified JSON back to file: $file_path"
            rm -f "$tmp_file"
            return 1
        fi
        rm -f "$tmp_file"
    fi

    if [[ -n "$original_mode" ]]; then
        chmod "$original_mode" "$file_path" 2>/dev/null || true
    fi

    log DEBUG "Prettified JSON file: $file_path"
    return 0
}

push_prettify_json_tree() {
    local root_dir="$1"
    local is_dry_run="${2:-false}"

    if [[ ! -d "$root_dir" ]]; then
        return 0
    fi

    if [[ "$is_dry_run" == "true" ]]; then
        log DEBUG "Skipping JSON tree prettify (dry run): $root_dir"
        return 0
    fi

    local all_success=true
    while IFS= read -r -d '' json_file; do
        if ! push_prettify_json_file "$json_file" "$is_dry_run"; then
            all_success=false
        fi
    done < <(find "$root_dir" -type f -name '*.json' -print0)

    if [[ "$all_success" != "true" ]]; then
        log WARN "Completed JSON prettify with warnings under: $root_dir"
        return 1
    fi

    return 0
}

render_credentials_bundle_to_directory() {
    local bundle_path="$1"
    local target_dir="$2"
    local is_dry_run="${3:-false}"
    local description="${4:-credentials}"

    if [[ -z "$target_dir" ]]; then
        log ERROR "Missing target directory for credential rendering"
        return 1
    fi

    if [[ "$is_dry_run" == "true" ]]; then
        log DRYRUN "Would render ${description} into directory: $target_dir"
        return 0
    fi

    if [[ ! -f "$bundle_path" ]]; then
        log WARN "Credential bundle not found at $bundle_path"
        return 1
    fi

    if ! jq empty "$bundle_path" >/dev/null 2>&1; then
        log WARN "Credential bundle is not valid JSON: $bundle_path"
        return 1
    fi

    if ! mkdir -p "$target_dir"; then
        log ERROR "Unable to create credential directory: $target_dir"
        return 1
    fi
    chmod 700 "$target_dir" 2>/dev/null || true

    find "$target_dir" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | while IFS= read -r -d '' old_file; do
        rm -f "$old_file"
    done

    declare -A credential_filename_registry=()
    local rendered_count=0

    while IFS= read -r credential_entry; do
        if [[ -z "$credential_entry" ]]; then
            continue
        fi

        local credential_id
        local credential_name
        credential_id=$(jq -r '.id // empty' <<<"$credential_entry")
        credential_name=$(jq -r '.name // .displayName // empty' <<<"$credential_entry")

        local credential_filename
        credential_filename=$(generate_unique_credential_filename "$target_dir" "$credential_id" "$credential_name" credential_filename_registry)
        local credential_path="$target_dir/$credential_filename"

        if ! printf '%s' "$credential_entry" | jq '.' >"$credential_path" 2>/dev/null; then
            log WARN "Failed to write credential file: $credential_path"
            rm -f "$credential_path"
            continue
        fi

        chmod 600 "$credential_path" 2>/dev/null || true
        rendered_count=$((rendered_count + 1))
    done < <(jq -c 'if type == "array" then .[] else empty end' "$bundle_path")

    if (( rendered_count == 0 )); then
        log INFO "No credentials to render for $description"
    else
        log SUCCESS "Rendered $rendered_count credential file(s) for $description"
    fi

    return 0
}

set_project_from_path() {
    local raw_input="$1"
    raw_input="$(printf '%s' "$raw_input" | tr -d '\r')"
    raw_input="$(printf '%s' "$raw_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$raw_input" ]]; then
        raw_input="$PERSONAL_PROJECT_TOKEN"
    fi

    project_name="$raw_input"
}

set_n8n_path() {
    local raw_input="$1"
    local source_label="$2"

    if [[ -z "$raw_input" ]]; then
        n8n_path=""
    else
        local normalized
        normalized="$(normalize_github_path_prefix "$raw_input")"
        if [[ -z "$normalized" ]]; then
            if [[ "$raw_input" != "/" && -n "$raw_input" ]]; then
                log WARN "Configured N8N_PATH '$raw_input' contained no usable characters after normalization; treating as repository root."
            fi
            n8n_path=""
        else
            if [[ "$normalized" != "${raw_input#/}" && "${verbose:-false}" == "true" ]]; then
                log DEBUG "Normalized N8N_PATH from '$raw_input' to '$normalized'"
            fi
            n8n_path="$normalized"
        fi
    fi

    if [[ -n "$source_label" ]]; then
        n8n_path_source="$source_label"
    fi
}

set_project_from_path "$project_name"

ensure_session_hostname() {
    if [[ -n "${SESSION_HOSTNAME:-}" ]]; then
        return 0
    fi

    local raw_host=""
    if raw_host="$(hostname -s 2>/dev/null)" && [[ -n "$raw_host" ]]; then
        :
    elif raw_host="$(hostname 2>/dev/null)" && [[ -n "$raw_host" ]]; then
        :
    elif raw_host="$(uname -n 2>/dev/null)" && [[ -n "$raw_host" ]]; then
        :
    else
        raw_host="host"
    fi

    raw_host="$(sanitize_filename_component "$raw_host" 96)"
    if [[ -z "$raw_host" ]]; then
        raw_host="host"
    fi

    SESSION_HOSTNAME="$raw_host"
    export SESSION_HOSTNAME
}

render_path_tokens() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        printf '%s\n' ""
        return
    fi

    ensure_session_hostname

    local rendered="$raw"
    rendered="${rendered//%DATE%/$SESSION_DATE}"
    rendered="${rendered//%DATETIME%/$SESSION_DATETIME}"
    rendered="${rendered//%TIME%/$SESSION_DATETIME}"
    rendered="${rendered//%YYYY%/$SESSION_YEAR}"
    rendered="${rendered//%YY%/$SESSION_YEAR_SHORT}"
    rendered="${rendered//%MM%/$SESSION_MONTH}"
    rendered="${rendered//%DD%/$SESSION_DAY}"
    rendered="${rendered//%HH%/$SESSION_HOUR}"
    rendered="${rendered//%mm%/$SESSION_MINUTE}"
    rendered="${rendered//%ss%/$SESSION_SECOND}"
    rendered="${rendered//%HOSTNAME%/$SESSION_HOSTNAME}"

    local personal_label
    personal_label="$(resolve_personal_project_name)"
    rendered="${rendered//%PERSONAL_PROJECT%/$personal_label}"

    printf '%s\n' "$rendered"
}

normalize_repo_subpath() {
    local raw_input="$1"
    if [[ -z "$raw_input" ]]; then
        printf '%s\n' ""
        return
    fi
    local normalized
    normalized="$(normalize_github_path_prefix "$raw_input")"
    printf '%s\n' "$normalized"
}

render_github_path_with_tokens() {
    local raw_value="${1-}"
    if [[ -z "$raw_value" ]]; then
        printf '%s\n' ""
        return
    fi

    local rendered
    rendered="$(render_path_tokens "$raw_value")"

    local effective_name
    effective_name="$(effective_project_name "${project_name:-}")"
    if [[ -z "$effective_name" ]]; then
        effective_name="$PERSONAL_PROJECT_TOKEN"
    fi

    rendered="${rendered//%PROJECT%/$effective_name}"
    rendered="${rendered//%PROJECT_LABEL%/$effective_name}"
    rendered="${rendered//%PROJECT_NAME%/$effective_name}"

    rendered="$(normalize_github_path_prefix "$rendered")"

    printf '%s\n' "$rendered"
}

effective_repo_prefix() {
    if [[ -n "$github_path" ]]; then
        render_github_path_with_tokens "$github_path"
    else
        printf '%s\n' ""
    fi
}

resolve_repo_base_prefix() {
    effective_repo_prefix
}

compose_repo_storage_path() {
    local relative_path="$1"
    local sanitized_relative
    sanitized_relative="${relative_path#/}"
    sanitized_relative="${sanitized_relative%/}"

    local effective_relative="$sanitized_relative"

    local base_prefix
    base_prefix="$(resolve_repo_base_prefix)"

    if [[ -z "$base_prefix" ]]; then
        printf '%s\n' "$effective_relative"
        return
    fi

    if [[ -z "$effective_relative" ]]; then
        printf '%s\n' "$base_prefix"
        return
    fi

    local normalized_base="$base_prefix"
    normalized_base="${normalized_base#/}"
    normalized_base="${normalized_base%/}"

    if [[ -z "$normalized_base" ]]; then
        printf '%s\n' "$effective_relative"
        return
    fi

    if [[ "$effective_relative" == "$normalized_base" ]]; then
        printf '%s\n' "$effective_relative"
        return
    fi

    if [[ "$effective_relative" == "$normalized_base"/* ]]; then
        printf '%s\n' "$effective_relative"
        return
    fi

    printf '%s/%s\n' "$normalized_base" "$effective_relative"
}

normalize_repo_folder_path() {
    local raw_folder="${1:-}"
    raw_folder="${raw_folder#/}"
    raw_folder="${raw_folder%/}"
    printf '%s' "$raw_folder"
}

normalize_github_path_prefix() {
    local raw_input="$1"
    if [[ -z "$raw_input" ]]; then
        printf '%s\n' ""
        return
    fi

    local cleaned
    cleaned="${raw_input//\\//}"
    cleaned="$(printf '%s' "$cleaned" | tr -d '\r\n\t')"
    cleaned="$(printf '%s' "$cleaned" | sed 's#[[:space:]]\+# #g')"
    cleaned="$(printf '%s' "$cleaned" | sed 's#^ *##;s# *$##')"
    cleaned="$(printf '%s' "$cleaned" | tr -s '/')"
    cleaned="${cleaned#/}"
    cleaned="${cleaned%/}"

    local -a sanitized_parts=()
    local -a parts=()
    if [[ -n "$cleaned" ]]; then
        IFS='/' read -r -a parts <<< "$cleaned"
        local segment
        for segment in "${parts[@]}"; do
            if [[ -z "$segment" || "$segment" == "." || "$segment" == ".." ]]; then
                continue
            fi
            local normalized_segment
            if [[ "$segment" =~ %[^%]+% ]]; then
                normalized_segment="$segment"
            else
                normalized_segment="$(sanitize_filename_component "$segment" 96)"
                # Preserve spaces in folder names (don't convert to hyphens)
                normalized_segment="${normalized_segment//--/-}"
                normalized_segment="${normalized_segment//__/_}"
                # Allow @, [, ] in addition to standard safe characters
                normalized_segment="${normalized_segment//[^A-Za-z0-9._ ()@\[\]-]/}"
                normalized_segment="$(printf '%s' "$normalized_segment" | sed 's/^-\+//;s/-\+$//')"
            fi
            if [[ -z "$normalized_segment" || "$normalized_segment" == "." || "$normalized_segment" == ".." ]]; then
                continue
            fi
            sanitized_parts+=("$normalized_segment")
        done
    fi

    if ((${#sanitized_parts[@]} == 0)); then
        printf '%s\n' ""
    else
        (IFS=/; printf '%s\n' "${sanitized_parts[*]}")
    fi
}

apply_github_path_prefix() {
    local relative="$1"
    local trimmed="${relative#/}"
    trimmed="${trimmed%/}"

    local prefix
    prefix="$(effective_repo_prefix)"

    if [[ -n "$prefix" ]]; then
        if [[ "$trimmed" == "$prefix" || "$trimmed" == "$prefix"/* ]]; then
            printf '%s\n' "$trimmed"
            return
        fi
        if [[ -n "$trimmed" ]]; then
            printf '%s/%s\n' "$prefix" "$trimmed"
        else
            printf '%s\n' "$prefix"
        fi
    else
        printf '%s\n' "$trimmed"
    fi
}

strip_github_path_prefix() {
    local path_value="$1"
    local normalized="${path_value#/}"
    normalized="${normalized%/}"

    local prefix
    prefix="$(effective_repo_prefix)"

    if [[ -z "$prefix" ]]; then
        printf '%s\n' "$normalized"
        return
    fi

    if [[ "$normalized" == "$prefix" ]]; then
        printf '%s\n' ""
        return
    fi

    if [[ "$normalized" == "$prefix"/* ]]; then
        local remainder="${normalized#"${prefix}/"}"
        printf '%s\n' "$remainder"
        return
    fi

    printf '%s\n' "$normalized"
}

path_matches_github_prefix() {
    local candidate="$1"
    local normalized="${candidate#/}"
    normalized="${normalized%/}"

    local prefix
    prefix="$(effective_repo_prefix)"

    if [[ -z "$prefix" ]]; then
        return 0
    fi

    if [[ "$normalized" == "$prefix" ]] || [[ "$normalized" == "$prefix"/* ]]; then
        return 0
    fi

    return 1
}

resolve_github_storage_root() {
    local base_dir="$1"
    local prefix
    prefix="$(effective_repo_prefix)"

    if [[ -z "$prefix" ]]; then
        printf '%s\n' "${base_dir%/}"
        return
    fi

    if [[ -z "$base_dir" ]]; then
        printf '%s\n' "$prefix"
        return
    fi
    local normalized_base="${base_dir%/}"
    local trimmed_prefix="${prefix#/}"
    trimmed_prefix="${trimmed_prefix%/}"

    if [[ -z "$trimmed_prefix" ]]; then
        printf '%s\n' "$normalized_base"
        return
    fi

    if [[ "$normalized_base" == "$trimmed_prefix" ]]; then
        printf '%s\n' "$normalized_base"
        return
    fi

    local suffix="/$trimmed_prefix"
    if [[ "$normalized_base" == *"$suffix" ]]; then
        printf '%s\n' "$normalized_base"
        return
    fi

    printf '%s/%s\n' "$normalized_base" "$trimmed_prefix"
}

strip_repo_scope_prefix() {
    local raw_path="${1:-}"
    raw_path="$(render_path_tokens "$raw_path")"
    raw_path="${raw_path//\\/\/}"
    raw_path="$(printf '%s' "$raw_path" | tr -d '\r\n\t')"
    raw_path="$(printf '%s' "$raw_path" | sed 's#^/*##;s#/*$##')"

    local base_prefix
    base_prefix="$(resolve_repo_base_prefix)"
    base_prefix="${base_prefix//\\/\/}"
    base_prefix="$(printf '%s' "$base_prefix" | tr -d '\r\n\t')"
    base_prefix="$(printf '%s' "$base_prefix" | sed 's#^/*##;s#/*$##')"

    if [[ -z "$raw_path" ]]; then
        printf '%s\n' ""
        return 0
    fi

    if [[ -z "$base_prefix" ]]; then
        printf '%s\n' "$raw_path"
        return 0
    fi

    IFS='/' read -r -a path_segments <<< "$raw_path"
    IFS='/' read -r -a base_segments <<< "$base_prefix"

    local drop_count=0
    local path_len=${#path_segments[@]}
    local base_len=${#base_segments[@]}

    while (( drop_count < base_len && drop_count < path_len )); do
        local base_segment="${base_segments[$drop_count]}"
        local path_segment="${path_segments[$drop_count]}"
        if [[ -z "$base_segment" ]]; then
            drop_count=$((drop_count + 1))
            continue
        fi
        if [[ "${base_segment,,}" == "${path_segment,,}" ]]; then
            drop_count=$((drop_count + 1))
            continue
        fi
        break
    done

    if (( drop_count >= path_len )); then
        printf '%s\n' ""
        return 0
    fi

    local -a remaining_segments
    remaining_segments=( "${path_segments[@]:drop_count}" )

    local result=""
    local idx
    for (( idx=0; idx<${#remaining_segments[@]}; idx++ )); do
        local segment="${remaining_segments[$idx]}"
        [[ -z "$segment" ]] && continue
        if [[ -z "$result" ]]; then
            result="$segment"
        else
            result="$result/$segment"
        fi
    done

    printf '%s\n' "$result"
}

native_path_for_host_tools() {
    local original_path="${1:-}"

    if [[ -z "$original_path" ]]; then
        printf '%s' ""
        return 0
    fi

    case "${OSTYPE:-}" in
        msys*|cygwin*|mingw*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -m "$original_path"
                return 0
            fi
            ;;
    esac

    printf '%s' "$original_path"
    return 0
}

posix_path_for_host_shell() {
    local original_path="${1:-}"

    if [[ -z "$original_path" ]]; then
        printf '%s' ""
        return 0
    fi

    local converted=""
    if [[ "$original_path" =~ ^[[:alpha:]]:[/\\] ]] || [[ "$original_path" == \\\\* ]] || [[ "$original_path" == //* ]]; then
        if command -v wslpath >/dev/null 2>&1; then
            if converted=$(wslpath -u "$original_path" 2>/dev/null); then
                printf '%s' "$converted"
                return 0
            fi
        fi
        if command -v cygpath >/dev/null 2>&1; then
            if converted=$(cygpath -u "$original_path" 2>/dev/null); then
                printf '%s' "$converted"
                return 0
            fi
        fi
    fi

    case "${OSTYPE:-}" in
        msys*|cygwin*|mingw*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -u "$original_path"
                return 0
            fi
            ;;
    esac

    printf '%s' "$original_path"
    return 0
}

detect_docker_client_os() {
    if [[ -n "${DOCKER_CLIENT_OS_CACHE:-}" ]]; then
        return 0
    fi

    local client_os=""
    if command -v docker >/dev/null 2>&1; then
        client_os=$(docker version --format '{{.Client.Os}}' 2>/dev/null | tr -d '\r' || true)
    fi

    if [[ -z "$client_os" ]]; then
        local docker_bin
        docker_bin=$(command -v docker 2>/dev/null || true)
        if [[ "$docker_bin" == *".exe" ]]; then
            client_os="windows"
        elif [[ -n "$docker_bin" && -x "$docker_bin" ]]; then
            if command -v file >/dev/null 2>&1; then
                if file "$docker_bin" | grep -iq 'pe32'; then
                    client_os="windows"
                fi
            fi
        fi
    fi

    if [[ -z "$client_os" ]]; then
        client_os="unknown"
    fi

    DOCKER_CLIENT_OS_CACHE="$client_os"
}

docker_cli_requires_windows_paths() {
    detect_docker_client_os
    local normalized="${DOCKER_CLIENT_OS_CACHE,,}"
    if [[ "$normalized" == "windows" ]]; then
        return 0
    fi

    local docker_bin
    docker_bin=$(command -v docker 2>/dev/null || true)
    if [[ "$docker_bin" == *".exe" ]]; then
        return 0
    fi

    return 1
}

resolve_windows_temp_posix() {
    if [[ -n "${WINDOWS_TEMP_POSIX_CACHE:-}" ]]; then
        printf '%s\n' "$WINDOWS_TEMP_POSIX_CACHE"
        return 0
    fi

    local win_tmp=""
    if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        local raw_tmp
        raw_tmp=$(cmd.exe /C "echo %TEMP%" 2>/dev/null | tr -d '\r')
        if [[ -n "$raw_tmp" ]]; then
            win_tmp=$(wslpath -u "$raw_tmp" 2>/dev/null || true)
        fi
    fi

    WINDOWS_TEMP_POSIX_CACHE="$win_tmp"
    printf '%s\n' "$win_tmp"
}

ensure_portable_tmp_base() {
    if [[ -n "${PORTABLE_TMP_BASE:-}" ]]; then
        printf '%s\n' "$PORTABLE_TMP_BASE"
        return 0
    fi

    local base="${TMPDIR:-/tmp}"
    if docker_cli_requires_windows_paths; then
        local win_tmp
        win_tmp=$(resolve_windows_temp_posix)
        if [[ -n "$win_tmp" ]]; then
            base="$win_tmp"
        fi
    fi

    mkdir -p "$base" 2>/dev/null || true
    PORTABLE_TMP_BASE="$base"
    printf '%s\n' "$PORTABLE_TMP_BASE"
}

portable_mktemp_dir() {
    local prefix="${1:-n8n-portable}"
    local base
    base=$(ensure_portable_tmp_base)
    mktemp -d "$base/${prefix}.XXXXXX"
}

portable_mktemp_file() {
    local prefix="${1:-n8n-portable}"
    local base
    base=$(ensure_portable_tmp_base)
    mktemp "$base/${prefix}.XXXXXX"
}

convert_path_for_docker_cp() {
    local host_path="${1:-}"
    local converted=""
    if [[ -z "$host_path" ]]; then
        printf '%s' ""
        return 0
    fi

    if docker_cli_requires_windows_paths; then
        if command -v wslpath >/dev/null 2>&1; then
            if converted=$(wslpath -w "$host_path" 2>/dev/null); then
                printf '%s' "$converted"
                return 0
            fi
        fi
        printf '%s' "$(native_path_for_host_tools "$host_path")"
        return 0
    fi

    printf '%s' "$host_path"
    return 0
}

initialize_host_temp_root() {
    local configured_tmp="${TMPDIR:-}"
    local default_tmp="/tmp"

    if [[ -z "$configured_tmp" ]]; then
        configured_tmp="$default_tmp"
    fi

    local native_tmp
    native_tmp="$(native_path_for_host_tools "$configured_tmp")"
    if [[ -z "$native_tmp" ]]; then
        native_tmp="$configured_tmp"
    fi

    if [[ ! -d "$native_tmp" ]]; then
        mkdir -p "$native_tmp" 2>/dev/null || true
    fi

    HOST_TEMP_ROOT_NATIVE="$native_tmp"
    HOST_TEMP_ROOT_POSIX="$(posix_path_for_host_shell "$native_tmp")"

    if [[ -z "$HOST_TEMP_ROOT_POSIX" ]]; then
        HOST_TEMP_ROOT_POSIX="$configured_tmp"
    fi

    export HOST_TEMP_ROOT_NATIVE
    export HOST_TEMP_ROOT_POSIX
    export TMPDIR="$native_tmp"
}

initialize_host_temp_root

# --- Helper Functions (using new log function) ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_host_dependencies() {
    log INFO "Checking host dependencies..."
    local missing_deps=""
    if ! command_exists git; then missing_deps="$missing_deps git"; fi
    if ! command_exists curl; then missing_deps="$missing_deps curl"; fi
    if ! command_exists jq; then missing_deps="$missing_deps jq"; fi

    if [ -n "$missing_deps" ]; then
        log ERROR "Missing required host dependencies:$missing_deps"
        log INFO "Please install the missing dependencies and try again."
        exit 1
    fi

    local execution_env_found=false
    
    # Check for local n8n
    if command_exists n8n; then
        execution_env_found=true
    fi

    # Check for Docker
    if command_exists docker; then
        # Check if docker is available. Suppress output if we already have n8n,
        # as we might not need docker.
        if [ "$execution_env_found" = "true" ]; then
            if ensure_docker_available >/dev/null 2>&1; then
                : # Docker is available too, good.
            fi
        else
            # If no n8n, we MUST have docker working
            if ! ensure_docker_available; then
                exit 1
            fi
            execution_env_found=true
        fi
    fi

    if [ "$execution_env_found" = "false" ]; then
        log ERROR "Neither Docker nor local n8n found."
        log INFO "Please install Docker (and ensure it's running) OR install n8n locally."
        exit 1
    fi

    log SUCCESS "Dependencies check passed"
}

load_config() {
    local file_to_load=""
    local config_found=false
    local skip_config=false
    local explicit_config=false
    local original_config_request=""

    if [[ -n "${config_file:-}" ]]; then
        explicit_config=true
        case "${config_file,,}" in
            null|none|off|false)
                skip_config=true
                log DEBUG "Configuration loading disabled via --config ${config_file}."
                ;;
            /dev/null)
                skip_config=true
                log DEBUG "Configuration loading disabled via --config /dev/null."
                ;;
            *)
                original_config_request="$config_file"
                ;;
        esac
    fi

    if ! $skip_config; then
        # Priority: explicit config → local config → user config
        if [[ -n "$original_config_request" ]]; then
            file_to_load="$original_config_request"
        elif [[ -f "$LOCAL_CONFIG_FILE" ]]; then
            file_to_load="$LOCAL_CONFIG_FILE"
        elif [[ -f "$USER_CONFIG_FILE" ]]; then
            file_to_load="$USER_CONFIG_FILE"
        fi

        # Expand tilde if present
        if [[ -n "$file_to_load" ]]; then
            file_to_load="${file_to_load/#\~/$HOME}"
        fi

        if [[ -n "$file_to_load" && -f "$file_to_load" ]]; then
            config_found=true
            log INFO "Loading configuration from: ${NORMAL}${file_to_load}${NC}"

            # Source the config file safely (normalize CRLF and filter out comments and empty lines)
            # shellcheck disable=SC1090  # dynamic config path sanitized above
            if ! source <(tr -d '\r' < "$file_to_load" | grep -vE '^\s*(#|$)' 2>/dev/null || true); then
                log ERROR "Failed to load configuration from: $file_to_load"
                return 1
            fi
            ACTIVE_CONFIG_PATH="$file_to_load"
        elif $explicit_config && [[ -n "$original_config_request" ]]; then
            log WARN "Configuration file specified but not found: '$original_config_request'"
        else
            log DEBUG "No configuration file found. Checked: '$LOCAL_CONFIG_FILE' and '$USER_CONFIG_FILE'"
        fi
    else
        log DEBUG "Configuration loading skipped by explicit request."
    fi

    # === GITHUB SETTINGS ===
    # Apply config values to global variables (use config file values if runtime vars not set)
    if [[ -z "$github_token" && -n "${GITHUB_TOKEN:-}" ]]; then
        github_token="$GITHUB_TOKEN"
    fi

    if [[ -z "$github_repo" && -n "${GITHUB_REPO:-}" ]]; then
        github_repo="$GITHUB_REPO"
    fi

    if [[ -z "$github_branch" && -n "${GITHUB_BRANCH:-}" ]]; then
        github_branch="$GITHUB_BRANCH"
    else
        github_branch="${github_branch:-main}"  # Set default if not configured anywhere
    fi

    # === CONTAINER SETTINGS ===
    if [[ -z "$container" && -n "${N8N_CONTAINER:-}" ]]; then
        container="$N8N_CONTAINER"
        container_source="config"
    fi

    # Keep reference to default container from config
    if [[ -n "${N8N_CONTAINER:-}" ]]; then
        # shellcheck disable=SC2034  # exposed for other modules via sourcing
        default_container="$N8N_CONTAINER"
        if [[ "$container_source" == "unset" ]]; then
            container_source="config"
        fi
    fi

    # === STORAGE SETTINGS ===
    # Handle workflows storage with flexible input (numeric or descriptive)
    if [[ -z "$workflows" && -n "${WORKFLOWS:-}" ]]; then
        local workflows_config="$WORKFLOWS"
        # Clean up the value - remove quotes and whitespace
        workflows_config=$(echo "$workflows_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)

        if [[ "$workflows_config" == "0" || "$workflows_config" == "disabled" ]]; then
            workflows=0
            workflows_source="config"
        elif [[ "$workflows_config" == "1" || "$workflows_config" == "local" ]]; then
            workflows=1
            workflows_source="config"
        elif [[ "$workflows_config" == "2" || "$workflows_config" == "remote" ]]; then
            workflows=2
            workflows_source="config"
        else
            log WARN "Invalid WORKFLOWS value in config: '$workflows_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 1 (local)"
            workflows=1
            workflows_source="default"
        fi
    fi

    # Handle credentials storage with flexible input (numeric or descriptive)
    if [[ -z "$credentials" && -n "${CREDENTIALS:-}" ]]; then
        local credentials_config="$CREDENTIALS"
        # Clean up the value - remove quotes and whitespace
        credentials_config=$(echo "$credentials_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)

        if [[ "$credentials_config" == "0" || "$credentials_config" == "disabled" ]]; then
            credentials=0
            credentials_source="config"
        elif [[ "$credentials_config" == "1" || "$credentials_config" == "local" ]]; then
            credentials=1
            credentials_source="config"
        elif [[ "$credentials_config" == "2" || "$credentials_config" == "remote" ]]; then
            credentials=2
            credentials_source="config"
        else
            log WARN "Invalid CREDENTIALS value in config: '$credentials_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 1 (local)"
            credentials=1
            credentials_source="default"
        fi
    fi

    # Handle environment storage with flexible input (numeric or descriptive)
    if [[ -z "$environment" && -n "${ENVIRONMENT:-}" ]]; then
        local environment_config="$ENVIRONMENT"
        environment_config=$(echo "$environment_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)

        if [[ "$environment_config" == "0" || "$environment_config" == "disabled" ]]; then
            environment=0
            environment_source="config"
        elif [[ "$environment_config" == "1" || "$environment_config" == "local" ]]; then
            environment=1
            environment_source="config"
        elif [[ "$environment_config" == "2" || "$environment_config" == "remote" ]]; then
            environment=2
            environment_source="config"
        else
            log WARN "Invalid ENVIRONMENT value in config: '$environment_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 0 (disabled)"
            environment=0
            environment_source="default"
        fi
    fi

    # === BOOLEAN SETTINGS ===
    # Handle folder_structure boolean config
    if [[ -z "$folder_structure" && -n "${FOLDER_STRUCTURE:-}" ]]; then
        local folder_structure_config="$FOLDER_STRUCTURE"
        # Clean up the value - remove quotes and whitespace
        folder_structure_config=$(echo "$folder_structure_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$folder_structure_config" == "true" || "$folder_structure_config" == "1" || "$folder_structure_config" == "yes" || "$folder_structure_config" == "on" ]]; then
            folder_structure=true
            folder_structure_source="config"
        elif [[ "$folder_structure_config" == "false" || "$folder_structure_config" == "0" || "$folder_structure_config" == "no" || "$folder_structure_config" == "off" ]]; then
            folder_structure=false
            folder_structure_source="config"
        else
            log WARN "Invalid FOLDER_STRUCTURE value in config: '$folder_structure_config'. Must be true/false. Using default: false"
            folder_structure=false
            folder_structure_source="default"
        fi
    fi

    # Handle verbose boolean config
    if [[ -z "${verbose:-}" && -n "${VERBOSE:-}" ]]; then
        local verbose_config="$VERBOSE"
        # Clean up the value - remove quotes and whitespace
        verbose_config=$(echo "$verbose_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$verbose_config" == "true" || "$verbose_config" == "1" || "$verbose_config" == "yes" || "$verbose_config" == "on" ]]; then
            verbose=true
        elif [[ "$verbose_config" == "false" || "$verbose_config" == "0" || "$verbose_config" == "no" || "$verbose_config" == "off" ]]; then
            verbose=false
        else
            log WARN "Invalid VERBOSE value in config: '$verbose_config'. Must be true/false. Using default: false"
            verbose=false
        fi
    fi

    # Handle restore preserve ID toggle
    if [[ -z "$restore_preserve_ids" && -n "${RESTORE_PRESERVE_ID:-}" ]]; then
        local preserve_cfg="$RESTORE_PRESERVE_ID"
        preserve_cfg=$(echo "$preserve_cfg" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$preserve_cfg" == "true" || "$preserve_cfg" == "1" || "$preserve_cfg" == "yes" || "$preserve_cfg" == "on" ]]; then
            restore_preserve_ids=true
            restore_preserve_ids_source="config"
        elif [[ "$preserve_cfg" == "false" || "$preserve_cfg" == "0" || "$preserve_cfg" == "no" || "$preserve_cfg" == "off" ]]; then
            restore_preserve_ids=false
            restore_preserve_ids_source="config"
        else
            log WARN "Invalid RESTORE_PRESERVE_ID value in config: '$preserve_cfg'. Must be true/false. Using default: false"
            restore_preserve_ids=false
            # shellcheck disable=SC2034  # tracked elsewhere for reporting
            restore_preserve_ids_source="default"
        fi
    fi

    if [[ -z "$restore_no_overwrite" && -n "${RESTORE_NO_OVERWRITE:-}" ]]; then
        local no_overwrite_cfg="$RESTORE_NO_OVERWRITE"
        no_overwrite_cfg=$(echo "$no_overwrite_cfg" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$no_overwrite_cfg" == "true" || "$no_overwrite_cfg" == "1" || "$no_overwrite_cfg" == "yes" || "$no_overwrite_cfg" == "on" ]]; then
            restore_no_overwrite=true
            restore_no_overwrite_source="config"
        elif [[ "$no_overwrite_cfg" == "false" || "$no_overwrite_cfg" == "0" || "$no_overwrite_cfg" == "no" || "$no_overwrite_cfg" == "off" ]]; then
            restore_no_overwrite=false
            restore_no_overwrite_source="config"
        else
            log WARN "Invalid RESTORE_NO_OVERWRITE value in config: '$no_overwrite_cfg'. Must be true/false. Using default: false"
            restore_no_overwrite=false
            # shellcheck disable=SC2034  # tracked elsewhere for reporting
            restore_no_overwrite_source="default"
        fi
    fi

    # Handle dry_run boolean config
    if [[ -z "$dry_run" && -n "${DRY_RUN:-}" ]]; then
        local dry_run_config="$DRY_RUN"
        # Clean up the value - remove quotes and whitespace
        dry_run_config=$(echo "$dry_run_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$dry_run_config" == "true" || "$dry_run_config" == "1" || "$dry_run_config" == "yes" || "$dry_run_config" == "on" ]]; then
            dry_run=true
            dry_run_source="config"
        elif [[ "$dry_run_config" == "false" || "$dry_run_config" == "0" || "$dry_run_config" == "no" || "$dry_run_config" == "off" ]]; then
            dry_run=false
            dry_run_source="config"
        else
            log WARN "Invalid DRY_RUN value in config: '$dry_run_config'. Must be true/false. Using default: false"
            dry_run=false
            dry_run_source="default"
        fi
    fi

    # Handle credentials_encrypted boolean config (loaded from DECRYPT_CREDENTIALS with inverted logic)
    if [[ -z "$credentials_encrypted" && -n "${DECRYPT_CREDENTIALS:-}" ]]; then
        local decrypt_credentials_config="$DECRYPT_CREDENTIALS"
        decrypt_credentials_config=$(echo "$decrypt_credentials_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$decrypt_credentials_config" == "true" || "$decrypt_credentials_config" == "1" || "$decrypt_credentials_config" == "yes" || "$decrypt_credentials_config" == "on" ]]; then
            credentials_encrypted=false
            credentials_encrypted_source="config"
        elif [[ "$decrypt_credentials_config" == "false" || "$decrypt_credentials_config" == "0" || "$decrypt_credentials_config" == "no" || "$decrypt_credentials_config" == "off" ]]; then
            credentials_encrypted=true
            credentials_encrypted_source="config"
        else
            log WARN "Invalid DECRYPT_CREDENTIALS value in config: '$decrypt_credentials_config'. Must be true/false. Using default: false (encrypted)"
            credentials_encrypted=true
            credentials_encrypted_source="default"
        fi
    fi

    if [[ -z "$assume_defaults" && -n "${ASSUME_DEFAULTS:-}" ]]; then
        local assume_defaults_config="$ASSUME_DEFAULTS"
        assume_defaults_config=$(echo "$assume_defaults_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$assume_defaults_config" == "true" || "$assume_defaults_config" == "1" || "$assume_defaults_config" == "yes" || "$assume_defaults_config" == "on" ]]; then
            assume_defaults=true
            assume_defaults_source="config"
        elif [[ "$assume_defaults_config" == "false" || "$assume_defaults_config" == "0" || "$assume_defaults_config" == "no" || "$assume_defaults_config" == "off" ]]; then
            assume_defaults=false
            assume_defaults_source="config"
        else
            log WARN "Invalid ASSUME_DEFAULTS value in config: '$assume_defaults_config'. Must be true/false. Using default: false"
            assume_defaults=false
            assume_defaults_source="default"
        fi
    fi

    # Handle alternate credentials folder name for Git push/pull operations
    if [[ -n "${CREDENTIALS_FOLDER_NAME:-}" ]]; then
        local credentials_folder_config="$CREDENTIALS_FOLDER_NAME"
        credentials_folder_config=$(echo "$credentials_folder_config" | tr -d '"\047' | xargs)
        credentials_folder_config="${credentials_folder_config%%/}"
        if [[ -z "$credentials_folder_config" ]]; then
            log WARN "CREDENTIALS_FOLDER_NAME in config is empty after normalization. Using default: .credentials"
            credentials_folder_name=".credentials"
        else
            credentials_folder_name="$credentials_folder_config"
            log DEBUG "Using configured credentials folder: $credentials_folder_name"
        fi
    fi

    # === PATH SETTINGS ===
    if [[ -z "$local_backup_path" && -n "${LOCAL_BACKUP_PATH:-}" ]]; then
        local_backup_path="$LOCAL_BACKUP_PATH"
        local_backup_path_source="config"
    fi

    if [[ "$github_path_source" != "cli" && "$github_path_source" != "interactive" && -z "$github_path" && -n "${GITHUB_PATH:-}" ]]; then
        local raw_github_path="$GITHUB_PATH"
        local normalized_github_path
        normalized_github_path="$(normalize_github_path_prefix "$raw_github_path")"
        local should_ignore_github_path=false

        if [[ -f "$raw_github_path" && ! -d "$raw_github_path" ]]; then
            should_ignore_github_path=true
        fi
        if [[ "${GITHUB_ACTIONS:-}" == "true" && "$raw_github_path" == *"_runner_file_commands"* ]]; then
            should_ignore_github_path=true
        fi

        if [[ "$should_ignore_github_path" == true ]]; then
            log WARN "Ignoring system GITHUB_PATH value '${raw_github_path}' (not a workflow directory)"
            normalized_github_path=""
        fi

        if [[ -z "$normalized_github_path" ]]; then
            if [[ -n "$raw_github_path" && "$should_ignore_github_path" == false ]]; then
                log WARN "Configured GITHUB_PATH '$raw_github_path' contained no usable characters after normalization; ignoring."
            fi
            github_path=""
        else
            if [[ "$normalized_github_path" != "${raw_github_path#/}" && "${verbose:-false}" == "true" ]]; then
                log DEBUG "Normalized GITHUB_PATH from '$raw_github_path' to '$normalized_github_path'"
            fi
            github_path="$normalized_github_path"
            github_path_source="config"
        fi
    fi

    if [[ "${n8n_path_source:-unset}" == "unset" || "${n8n_path_source:-unset}" == "default" ]]; then
        if [[ -n "${N8N_PATH:-}" ]]; then
            set_n8n_path "$N8N_PATH" "config"
        fi
    fi

    if [[ -n "${N8N_PROJECT:-}" ]]; then
        if [[ -z "$project_name_source" || "$project_name_source" == "unset" || "$project_name_source" == "default" ]]; then
            set_project_from_path "$N8N_PROJECT"
            project_name_source="config"
        fi
    fi

    # === N8N API SETTINGS ===
    if [[ -z "$n8n_base_url" && -n "${N8N_BASE_URL:-}" ]]; then
        n8n_base_url="$N8N_BASE_URL"
    fi

    if [[ -z "$n8n_api_key" && -n "${N8N_API_KEY:-}" ]]; then
        n8n_api_key="$N8N_API_KEY"
    fi

    if [[ -z "$n8n_session_credential" ]]; then
        if [[ -n "${N8N_LOGIN_CREDENTIAL_NAME:-}" ]]; then
            n8n_session_credential="$N8N_LOGIN_CREDENTIAL_NAME"
        elif [[ -n "${N8N_LOGIN_CREDENTIAL_NAME_NAME:-}" ]]; then
            n8n_session_credential="$N8N_LOGIN_CREDENTIAL_NAME_NAME"
        fi
    fi

    if [[ -z "$git_commit_name" && -n "${GIT_COMMIT_NAME:-}" ]]; then
        git_commit_name="$GIT_COMMIT_NAME"
    fi

    if [[ -z "$git_commit_email" && -n "${GIT_COMMIT_EMAIL:-}" ]]; then
        git_commit_email="$GIT_COMMIT_EMAIL"
    fi

    # Backward compatibility: allow direct email/password configuration if still provided
    if [[ -z "$n8n_email" && -n "${N8N_EMAIL:-}" ]]; then
        n8n_email="$N8N_EMAIL"
    fi

    if [[ -z "$n8n_password" && -n "${N8N_PASSWORD:-}" ]]; then
        n8n_password="$N8N_PASSWORD"
    fi

    # === OTHER SETTINGS ===
    if [[ -z "$restore_type" && -n "${RESTORE_TYPE:-}" ]]; then
        restore_type="$RESTORE_TYPE"
    fi

    if [[ -z "$log_file" && -n "${LOG_FILE:-}" ]]; then
        log_file="$LOG_FILE"
    fi

    # === SET DEFAULTS FOR UNSET VALUES ===
    # Only set defaults if no value was provided via command line or config
    
    # Set storage defaults
    if [[ -z "$workflows" ]]; then
        workflows=1  # Default to local
        if [[ "$workflows_source" == "unset" ]]; then
            workflows_source="default"
        fi
    fi
    
    if [[ -z "$credentials" ]]; then
        credentials=1  # Default to local
        if [[ "$credentials_source" == "unset" ]]; then
            credentials_source="default"
        fi
    fi
    
    # Set path defaults
    if [[ -z "$local_backup_path" ]]; then
        local_backup_path="$HOME/n8n-backup"
        if [[ "$local_backup_path_source" == "unset" ]]; then
            local_backup_path_source="default"
        fi
    fi
    
    if [[ -z "$project_name" ]]; then
        set_project_from_path "$PERSONAL_PROJECT_TOKEN"
        if [[ "$project_name_source" == "unset" ]]; then
            project_name_source="default"
        fi
    else
        # Ensure prefix segments reflect the resolved project value when not set via setter yet
        if [[ -z "$project_name_source" || "$project_name_source" == "unset" || "$project_name_source" == "default" ]]; then
            set_project_from_path "$project_name"
        fi
    fi

    if [[ "$github_path_source" == "unset" ]]; then
        github_path_source="default"
    fi

    if [[ "$n8n_path_source" == "unset" ]]; then
        n8n_path_source="default"
    fi
    
    # Set other defaults
    if [[ -z "$restore_type" ]]; then
        restore_type="all"
    fi
    
    if [[ -z "$github_branch" ]]; then
        github_branch="main"
    fi

    if [[ -z "$git_commit_name" ]]; then
        git_commit_name="n8n-git push"
    fi

    if [[ -z "$git_commit_email" ]]; then
        local base_domain raw_domain
        raw_domain="${n8n_base_url:-}"
        if [[ -n "$raw_domain" ]]; then
            base_domain=$(echo "$raw_domain" | sed -E 's#^[a-zA-Z]+://##' | sed 's#/.*$##')
            base_domain="${base_domain%%:*}"
            base_domain=$(echo "$base_domain" | tr '[:upper:]' '[:lower:]')
            base_domain="${base_domain:-n8n.local}"
        else
            base_domain="n8n.local"
        fi
        git_commit_email="push@${base_domain}"
    fi

    if [[ -z "$dry_run" ]]; then
        dry_run=false
        if [[ "$dry_run_source" == "unset" ]]; then
            dry_run_source="default"
        fi
    fi

    if [[ -z "$folder_structure" ]]; then
        folder_structure=false
        if [[ "$folder_structure_source" == "unset" ]]; then
            folder_structure_source="default"
        fi
    fi

    # Default to encrypted credential exports unless explicitly disabled
    if [[ -z "${credentials_encrypted:-}" ]]; then
        credentials_encrypted=true
        log DEBUG "Defaulting to encrypted credential exports: credentials_encrypted=true"
        if [[ "$credentials_encrypted_source" == "unset" ]]; then
            credentials_encrypted_source="default"
        fi
    fi
    
    # === LOG FILE VALIDATION ===
    if [[ "$CONFIG_MODE_BYPASS_LOG_FILE" == "true" ]]; then
        log_file=""
        LOG_FILE_DISABLED=true
    elif [[ -z "$log_file" ]]; then
        LOG_FILE_DISABLED=true
        log DEBUG "File logging disabled. Set LOG_FILE or --log-file to enable (e.g. $LOG_FILE_SUGGESTED_PATH)"
    else
        if [[ "$log_file" == "auto" ]]; then
            log_file="$LOG_FILE_SUGGESTED_PATH"
        fi
        # Ensure log file path is absolute
        if [[ "$log_file" != /* ]]; then
            log WARN "Log file path '$log_file' is not absolute. Converting to absolute path."
            log_file="$(pwd)/$log_file"
        fi
        
        # Ensure log file directory exists and is writable
        local log_dir
        log_dir="$(dirname "$log_file")"
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            log WARN "Cannot create directory for log file: '$log_dir' (logging will be disabled)"
            log_file=""
            LOG_FILE_DISABLED=true
        elif ! touch "$log_file" 2>/dev/null; then
            log WARN "Log file is not writable: '$log_file' (logging will be disabled)"
            log_file=""
            LOG_FILE_DISABLED=true
        else
            LOG_FILE_DISABLED=false
            log INFO "Logging output to: $log_file"
        fi
    fi
    
    # === DEBUG OUTPUT ===
    if [[ "$config_found" == "true" ]]; then
        log DEBUG "Configuration loaded successfully"
        log DEBUG "Storage: workflows=($workflows) $(format_storage_value "$workflows"), credentials=($credentials) $(format_storage_value "$credentials")"
        local effective_prefix
        effective_prefix="$(effective_repo_prefix)"
        if [[ -n "$effective_prefix" ]]; then
            log DEBUG "GitHub path prefix: $effective_prefix"
        else
            log DEBUG "GitHub path prefix: <repository root>"
        fi
    else
        log DEBUG "No configuration file loaded, using defaults"
        local effective_prefix
        effective_prefix="$(effective_repo_prefix)"
        if [[ -n "$effective_prefix" ]]; then
            log DEBUG "GitHub path prefix: $effective_prefix"
        else
            log DEBUG "GitHub path prefix: <repository root>"
        fi
    fi

    if [[ "${n8n_path_source:-default}" != "default" && "${n8n_path_source:-unset}" != "unset" ]]; then
        if [[ -n "$n8n_path" ]]; then
            log DEBUG "Default GitHub path (N8N_PATH): $n8n_path"
        else
            log DEBUG "Default GitHub path (N8N_PATH): <repository root>"
        fi
    fi
}

# Utility functions that other modules need
check_github_access() {
    local token="$1"
    local repo="$2"
    
    log DEBUG "Testing GitHub access to repository: $repo"
    
    local response
    if ! response=$(curl -s -w "%{http_code}" -H "Authorization: token $token" \
                          "https://api.github.com/repos/$repo" 2>/dev/null); then
        return 1
    fi
    
    local http_code="${response: -3}"
    
    case "$http_code" in
        200) 
            log DEBUG "GitHub access test successful"
            return 0 ;;
        404)
            log ERROR "Repository '$repo' not found or not accessible with provided token"
            return 1 ;;
        401|403)
            log ERROR "GitHub access denied. Check your token permissions."
            return 1 ;;
        *)
            log ERROR "GitHub API returned HTTP $http_code"
            return 1 ;;
    esac
}

n8n_exec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local output=""
    local exit_code=0

    if $is_dry_run; then
        if [[ -n "$container_id" ]]; then
            log DRYRUN "Would execute in container $container_id: $cmd"
        else
            log DRYRUN "Would execute locally: $cmd"
        fi
        return 0
    fi

    if [[ -n "$container_id" ]]; then
        log DEBUG "Executing in container $container_id: $cmd"
        local -a exec_cmd=("docker" "exec")
        if [[ -n "${DOCKER_EXEC_USER:-}" ]]; then
            exec_cmd+=("--user" "$DOCKER_EXEC_USER")
        fi
        exec_cmd+=("$container_id" "sh" "-c" "$cmd")
        output=$("${exec_cmd[@]}" 2>&1) || exit_code=$?
    else
        log DEBUG "Executing locally: $cmd"
        output=$(sh -c "$cmd" 2>&1) || exit_code=$?
    fi

    local filtered_output=""
    if [ -n "$output" ]; then
        filtered_output=$(echo "$output" | grep -vE 'OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS|N8N_BLOCK_ENV_ACCESS_IN_NODE|Error tracking disabled|DB_SQLITE_POOL_SIZE|N8N_RUNNERS_ENABLED|N8N_GIT_NODE_DISABLE_BARE_REPOS|There are deprecations related to your environment variables|Could not find workflow' || true)
    fi
    
    if [ "${verbose:-false}" = "true" ] && [ -n "$filtered_output" ]; then
        log DEBUG $'Output:\n  '"${filtered_output//$'\n'/$'\n  '}"
    fi
    
    if [ $exit_code -ne 0 ]; then
        log ERROR "Command failed (Exit Code: $exit_code): $cmd"
        if [ "${verbose:-false}" != "true" ] && [ -n "$filtered_output" ]; then
            log ERROR $'Output:\n  '"${filtered_output//$'\n'/$'\n  '}"
        fi
        return 1
    fi
    
    return 0
}

n8n_exec_root() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local output=""
    local exit_code=0

    if $is_dry_run; then
        if [[ -n "$container_id" ]]; then
            log DRYRUN "Would execute as root in container $container_id: $cmd"
        else
            log DRYRUN "Would execute locally (as current user): $cmd"
        fi
        return 0
    fi

    if [[ -n "$container_id" ]]; then
        log DEBUG "Executing as root in container $container_id: $cmd"
        local -a exec_cmd=("docker" "exec" "--user" "root" "$container_id" "sh" "-c" "$cmd")
        output=$("${exec_cmd[@]}" 2>&1) || exit_code=$?
    else
        log DEBUG "Executing locally: $cmd"
        output=$(sh -c "$cmd" 2>&1) || exit_code=$?
    fi

    if [ "${verbose:-false}" = "true" ] && [ -n "$output" ]; then
        log DEBUG $'Output:\n  '"${output//$'\n'/$'\n  '}"
    fi

    if [ $exit_code -ne 0 ]; then
        log ERROR "Command failed (Exit Code: $exit_code): $cmd"
        if [ "${verbose:-false}" != "true" ] && [ -n "$output" ]; then
            log ERROR $'Output:\n  '"${output//$'\n'/$'\n  '}"
        fi
        return 1
    fi
    
    return 0
}

n8n_check_path() {
    local container_id="$1"
    local path="$2"
    local type="${3:-f}" # f for file, d for directory

    if [[ -n "$container_id" ]]; then
        docker exec "$container_id" sh -c "[ -$type '$path' ]"
    else
        [ -$type "$path" ]
    fi
}

copy_from_n8n() {
    local source_path="$1"
    local dest_path="$2"
    local container_id="$3"
    
    if [[ -n "$container_id" ]]; then
        log DEBUG "Copying from container $container_id:$source_path to $dest_path"
        docker cp "${container_id}:${source_path}" "$dest_path"
    else
        log DEBUG "Copying locally from $source_path to $dest_path"
        cp -r "$source_path" "$dest_path"
    fi
}

copy_to_n8n() {
    local source_path="$1"
    local dest_path="$2"
    local container_id="$3"
    
    if [[ -n "$container_id" ]]; then
        log DEBUG "Copying from $source_path to container $container_id:$dest_path"
        docker cp "$source_path" "${container_id}:${dest_path}"
    else
        log DEBUG "Copying locally from $source_path to $dest_path"
        cp -r "$source_path" "$dest_path"
    fi
}


timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
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

# Generate workflow manifest from directory structure
# Args: source_dir, output_manifest_path
# Returns: 0 on success, 1 on failure
generate_workflow_manifest() {
    local source_dir="$1"
    local output_manifest_path="$2"
    
    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Invalid source directory for manifest generation: ${source_dir:-<empty>}"
        return 1
    fi
    
    # Ensure source_dir has no trailing slash for consistent substitution
    source_dir="${source_dir%/}"
    
    : > "$output_manifest_path"
    
    local processed=0
    
    while IFS= read -r -d '' workflow_file; do
        local workflow_json
        if ! workflow_json=$(cat "$workflow_file" 2>/dev/null); then
            continue
        fi
        
        # Extract metadata
        local workflow_id workflow_name
        workflow_id=$(printf '%s' "$workflow_json" | jq -r '.id // ""' 2>/dev/null)
        workflow_name=$(printf '%s' "$workflow_json" | jq -r '.name // ""' 2>/dev/null)
        
        # Calculate relative path
        local relative_path="${workflow_file#"${source_dir}/"}"
        
        # Create manifest entry
        local manifest_entry
        manifest_entry=$(jq -nc \
            --arg id "$workflow_id" \
            --arg name "$workflow_name" \
            --arg path "$relative_path" \
            '{
                id: (if $id == "" then null else $id end),
                name: $name,
                storagePath: $path
            }')
        
        printf '%s\n' "$manifest_entry" >> "$output_manifest_path"
        processed=$((processed + 1))
        
    done < <(find "$source_dir" -type f -name "*.json" \
        ! -path "*/.credentials/*" \
        ! -name "credentials.json" \
        -print0 2>/dev/null)
        
    log DEBUG "Generated manifest with $processed workflows from $source_dir"
    return 0
}
