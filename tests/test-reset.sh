#!/usr/bin/env bash
# =========================================================
# n8n Git - Combined Hard/Soft Reset Regression
# =========================================================
# Integration coverage summary (all stages assume three commits: baseline → mid → head):
#   • Stage 0: Resolver unit smoke tests (interactive picker + time window).
#   • Stage 1: Hard reset → HEAD seeds all workflows; validates shared folder + inactive state.
#   • Stage 2: Hard reset → MID deletes Gamma; ensures Beta stays active and Alpha in root.
#   • Stage 3: Soft reset → BASELINE archives Beta while keeping Alpha active; REST confirms archival.
#   • Stage 4: Hard reset → HEAD with --github-path rehydrates Teams/Support slice without touching root assets.
#   • Stage 5: Hard reset → HEAD with custom N8N_PATH mirrors repo structure under a new folder prefix.
# Every stage asserts workflow counts, IDs, folder assignments, and REST visibility to catch regressions.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/tests}"
MANAGER_SCRIPT="$ROOT_DIR/n8n-git.sh"
source "$SCRIPT_DIR/utils/n8n-testbed.sh"
# Resolver helpers for lightweight unit coverage
source "$ROOT_DIR/lib/utils/common.sh"
source "$ROOT_DIR/lib/utils/interactive.sh"
source "$ROOT_DIR/lib/reset/common.sh"
source "$ROOT_DIR/lib/reset/resolve.sh"
source "$ROOT_DIR/lib/reset/time_window.sh"

CONTAINER_NAME="n8n-reset-regression"
CONTAINER_BASE_PORT=${CONTAINER_BASE_PORT:-5682}
CONTAINER_PORT=""
TEST_EMAIL="${TEST_EMAIL:-$(testbed_default_owner_email)}"
TEST_PASSWORD="${TEST_PASSWORD:-$(testbed_default_owner_password)}"
TEST_FIRST_NAME="${TEST_FIRST_NAME:-$(testbed_default_owner_first)}"
TEST_LAST_NAME="${TEST_LAST_NAME:-$(testbed_default_owner_last)}"

TEST_VERBOSE=${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}

test_apply_msys_overrides

log HEADER "n8n-git Reset Tests"

if ! test_configure_docker_cli test_run_with_msys; then
  exit 1
fi

TEMP_HOME=$(mktemp -d)
SESSION_COOKIES="$TEMP_HOME/session.cookies"
: >"$SESSION_COOKIES"
TEST_REPO_DIR=$(mktemp -d "$TEMP_HOME/reset-repo-XXXXXX")
WORKFLOWS_DIR="$TEST_REPO_DIR/workflows"
REST_BASE_URL=""

cleanup() {
  log INFO "Cleaning up test environment..."
  testbed_docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ -d "$TEMP_HOME" ]]; then
    if test_should_keep_artifacts; then
      log INFO "Preserving artifacts at $TEMP_HOME"
    else
      rm -rf "$TEMP_HOME"
    fi
  fi
}
trap cleanup EXIT
handle_sigint() {
  log ERROR "Received SIGINT; aborting test early"
  exit 130
}
trap handle_sigint INT

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    log ERROR "$message (expected '$expected', got '$actual')"
    exit 1
  fi
}

run_reset_interactive_picker_tests() {
  log INFO "Running interactive picker resolver unit tests"
  local repo_dir
  repo_dir=$(mktemp -d "$TEMP_HOME/reset-interactive-unit-XXXXXX")
  pushd "$repo_dir" >/dev/null
  git init -q
  git config user.name "Interactive Tester"
  git config user.email "interactive@example.com"

  cp "$SCRIPT_DIR/fixtures/workflows/reset-simple_alpha.json" workflow.json
  git add workflow.json
  GIT_AUTHOR_DATE="2025-10-30T10:00:00Z" \
  GIT_COMMITTER_DATE="2025-10-30T10:00:00Z" \
  git commit -qam "baseline: alpha"
  local commit_one
  commit_one=$(git rev-parse HEAD)

  cp "$SCRIPT_DIR/fixtures/workflows/reset-simple_beta.json" workflow.json
  GIT_AUTHOR_DATE="2025-11-02T15:12:00Z" \
  GIT_COMMITTER_DATE="2025-11-02T15:12:00Z" \
  git commit -qam "midpoint: beta"
  local commit_two
  commit_two=$(git rev-parse HEAD)

  cp "$SCRIPT_DIR/fixtures/workflows/reset-simple_gamma.json" workflow.json
  GIT_AUTHOR_DATE="2025-11-05T09:01:00Z" \
  GIT_COMMITTER_DATE="2025-11-05T09:01:00Z" \
  git commit -qam "head: gamma"
  local commit_three
  commit_three=$(git rev-parse HEAD)
  popd >/dev/null

  pushd "$repo_dir" >/dev/null
  RESET_INTERACTIVE_AUTOPICK=2 launch_interactive_picker >/dev/null
  assert_equals "$commit_two" "${RESOLVED_TARGET_SHA:-}" "Autopick by index should select second commit"
  assert_equals "interactive" "${RESOLVED_TARGET_SOURCE:-}" "Interactive resolver should tag source"

  RESET_INTERACTIVE_AUTOPICK="${commit_one:0:7}" launch_interactive_picker >/dev/null
  assert_equals "$commit_one" "${RESOLVED_TARGET_SHA:-}" "Autopick by prefix should match baseline commit"

  if RESET_INTERACTIVE_AUTOPICK_ACTION=abort launch_interactive_picker >/dev/null; then
    log ERROR "Interactive picker abort should propagate exit code 130"
    exit 1
  else
    local status=$?
    assert_equals "130" "$status" "Interactive picker abort exit code"
  fi
  popd >/dev/null

  rm -rf "$repo_dir"
  unset RESET_INTERACTIVE_AUTOPICK RESET_INTERACTIVE_AUTOPICK_ACTION \
    RESOLVED_TARGET_SHA RESOLVED_TARGET_SOURCE RESOLVED_TARGET_CONTEXT
  log SUCCESS "Interactive picker resolver unit tests passed"
}

run_reset_time_window_tests() {
  log INFO "Running time-window resolver unit tests"
  local repo_dir
  repo_dir=$(mktemp -d "$TEMP_HOME/reset-window-unit-XXXXXX")
  pushd "$repo_dir" >/dev/null
  git init -q
  git config user.name "Window Tester"
  git config user.email "window@example.com"

  echo "alpha" >file.txt
  git add file.txt
  GIT_AUTHOR_DATE="2025-10-25T08:00:00Z" \
  GIT_COMMITTER_DATE="2025-10-25T08:00:00Z" \
  git commit -qam "alpha"
  local commit_early
  commit_early=$(git rev-parse HEAD)

  echo "beta" >file.txt
  GIT_AUTHOR_DATE="2025-11-02T11:00:00Z" \
  GIT_COMMITTER_DATE="2025-11-02T11:00:00Z" \
  git commit -qam "beta"
  local commit_mid
  commit_mid=$(git rev-parse HEAD)

  echo "gamma" >file.txt
  GIT_AUTHOR_DATE="2025-11-05T22:30:00Z" \
  GIT_COMMITTER_DATE="2025-11-05T22:30:00Z" \
  git commit -qam "gamma"
  local commit_late
  commit_late=$(git rev-parse HEAD)

  if parse_time_window "2025-11-01" "2025-11-03"; then
    assert_equals "$commit_mid" "${RESOLVED_TARGET_SHA:-}" "Bounded window should select mid commit"
  else
    log ERROR "parse_time_window failed for valid window"
    exit 1
  fi

  if parse_time_window "2025-11-04" ""; then
    assert_equals "$commit_late" "${RESOLVED_TARGET_SHA:-}" "Open-ended window should select latest commit"
  else
    log ERROR "parse_time_window failed when --until omitted"
    exit 1
  fi

  local empty_status=0
  set +e
  parse_time_window "2025-11-10" "2025-11-11"
  empty_status=$?
  set -e
  if [[ "$empty_status" == "0" ]]; then
    log ERROR "parse_time_window should fail when no commits exist in window"
    exit 1
  else
    assert_equals "2" "$empty_status" "Empty window should exit with validation error"
  fi

  popd >/dev/null
  rm -rf "$repo_dir"
  unset RESOLVED_TARGET_SHA RESOLVED_TARGET_SOURCE RESOLVED_TARGET_CONTEXT
  log SUCCESS "Time-window resolver unit tests passed"
}

run_reset_resolver_unit_tests() {
  run_reset_interactive_picker_tests
  run_reset_time_window_tests
}

RUN_RESET_UNIT_TESTS=${RUN_RESET_UNIT_TESTS:-1}
if [[ "$RUN_RESET_UNIT_TESTS" == "1" ]]; then
  run_reset_resolver_unit_tests
else
  log INFO "Skipping reset resolver unit tests (RUN_RESET_UNIT_TESTS=$RUN_RESET_UNIT_TESTS)"
fi

log_verbose_mode() {
  if test_verbose_enabled; then
    log INFO "Running n8n-git.sh in verbose mode"
  fi
}

create_workflow_repo() {
  log INFO "Creating three-commit workflow timeline"
  mkdir -p "$WORKFLOWS_DIR"
  local previous_dir
  previous_dir=$(pwd)
  cd "$TEST_REPO_DIR"
  git init -q
  git config user.name "Reset Tester"
  git config user.email "reset@example.com"

  cp "$SCRIPT_DIR/fixtures/workflows/reset-root_alpha.json" "$WORKFLOWS_DIR/root_alpha.json"

  git add workflows
  git commit -m "baseline: root workflow" -q
  COMMIT_BASELINE=$(git rev-parse HEAD)
  log INFO "Baseline commit: $COMMIT_BASELINE"

  mkdir -p "$WORKFLOWS_DIR/Teams/Support"

  cp "$SCRIPT_DIR/fixtures/workflows/reset-folder_beta.json" "$WORKFLOWS_DIR/Teams/Support/folder_beta.json"

  git add workflows/Teams/Support/folder_beta.json
  git commit -m "midpoint: add folder workflow beta" -q
  COMMIT_MID=$(git rev-parse HEAD)
  log INFO "Mid commit: $COMMIT_MID"

  cp "$SCRIPT_DIR/fixtures/workflows/reset-folder_gamma.json" "$WORKFLOWS_DIR/Teams/Support/folder_gamma.json"

  git add workflows/Teams/Support/folder_gamma.json
  git commit -m "head: add folder workflow gamma" -q
  COMMIT_HEAD=$(git rev-parse HEAD)
  log INFO "Head commit: $COMMIT_HEAD"
  cd "$previous_dir"
}

authenticate_session() {
  local base_url="http://localhost:${CONTAINER_PORT}"

  log INFO "Completing owner setup via REST"
  if ! testbed_prepare_owner "$CONTAINER_NAME" "$base_url" "$TEST_EMAIL" "$TEST_PASSWORD" "$TEST_FIRST_NAME" "$TEST_LAST_NAME" "$SESSION_COOKIES"; then
    log ERROR "Owner setup failed after retries"
    exit 1
  fi

  log INFO "Establishing authenticated session"
  if ! testbed_login "$base_url" "$TEST_EMAIL" "$TEST_PASSWORD" "$SESSION_COOKIES"; then
    log ERROR "Failed to establish session"
    exit 1
  fi

  REST_BASE_URL="$base_url"
}

rest_get_to_file() {
  local path="$1"
  local dest="$2"
  local status
  status=$(curl -sS --retry 5 --retry-delay 2 --retry-all-errors -b "$SESSION_COOKIES" \
    -H "Accept: application/json" \
    -H "X-Requested-With: XMLHttpRequest" \
    -o "$dest" -w '%{http_code}' "$REST_BASE_URL$path")
  printf '%s' "$status"
}

export_workflows_json() {
  testbed_docker exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/reset-export.json >/dev/null && cat /tmp/reset-export.json'
}

await_workflow_export() {
  local expected_count="$1"
  local label="${2:-export check}"

  local export_json
  export_json=$(export_workflows_json) || {
    log ERROR "Workflow export command failed for $label" >&2
    return 1
  }

  local count
  count=$(printf '%s' "$export_json" | jq 'length' 2>/dev/null || echo "")

  if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
    log ERROR "Unable to determine workflow count for $label" >&2
    printf '%s\n' "$export_json" | jq '.' >&2 || printf '%s\n' "$export_json" >&2
    return 1
  fi

  if [[ -n "$expected_count" && "$count" != "$expected_count" ]]; then
    log ERROR "Workflow count mismatch for $label (expected=$expected_count, actual=$count)" >&2
    printf '%s\n' "$export_json" | jq '.' >&2 || printf '%s\n' "$export_json" >&2
    return 1
  fi

  log INFO "Export ready for $label (count=$count)" >&2
  printf '%s' "$export_json"
}

workflow_id_by_name() {
  local name="$1"
  local export_json="$2"
  printf '%s' "$export_json" | jq -r --arg name "$name" 'map(select(.name == $name) | .id) | first // ""'
}

workflow_ids_by_name_all() {
  local name="$1"
  local export_json="$2"
  printf '%s' "$export_json" | jq -r --arg name "$name" 'map(select(.name == $name) | .id)[]?'
}

require_workflow_id() {
  local name="$1"
  local export_json="$2"
  local id
  id=$(workflow_id_by_name "$name" "$export_json")
  if [[ -z "$id" ]]; then
    log ERROR "Workflow '$name' not present in export"
    printf '%s\n' "$export_json" | jq '.' >&2 || printf '%s\n' "$export_json" >&2
    exit 1
  fi
  printf '%s' "$id"
}

normalise_folder_id() {
  local folder_id="$1"
  if [[ -z "$folder_id" || "$folder_id" == "null" ]]; then
    printf ''
  else
    printf '%s' "$folder_id"
  fi
}

rest_fetch_workflow_folder_id() {
  local workflow_id="$1"
  local label="$2"
  local response_path="$TEMP_HOME/workflow-$workflow_id.json"
  local status
  status=$(rest_get_to_file "/rest/workflows/$workflow_id" "$response_path")
  if [[ "$status" != "200" ]]; then
    log ERROR "Failed to fetch REST payload for $label (status=$status)"
    cat "$response_path" >&2 || true
    exit 1
  fi
  local folder_id
  folder_id=$(jq -r '(
      .data.folderId
      // (.data.folder | objects | .id)
      // .data.parentFolderId
      // (.data.parentFolder | objects | .id)
      // ""
    ) | tostring' "$response_path")
  normalise_folder_id "$folder_id"
}

assert_workflow_in_root_folder() {
  local workflow_id="$1"
  local label="$2"
  local folder_id
  folder_id=$(rest_fetch_workflow_folder_id "$workflow_id" "$label")
  if [[ -n "$folder_id" ]]; then
    log ERROR "$label expected in root but folderId=$folder_id"
    exit 1
  fi
  log SUCCESS "$label resides in root folder"
}

assert_workflow_in_non_root_folder() {
  local workflow_id="$1"
  local label="$2"
  local folder_id
  folder_id=$(rest_fetch_workflow_folder_id "$workflow_id" "$label")
  if [[ -z "$folder_id" ]]; then
    log ERROR "$label expected in non-root folder but folderId empty"
    exit 1
  fi
  log SUCCESS "$label resides in non-root folderId=$folder_id"
}

assert_workflows_share_folder() {
  local first_id="$1"
  local second_id="$2"
  local first_label="$3"
  local second_label="$4"
  local first_folder second_folder
  first_folder=$(rest_fetch_workflow_folder_id "$first_id" "$first_label")
  second_folder=$(rest_fetch_workflow_folder_id "$second_id" "$second_label")
  if [[ -z "$first_folder" || -z "$second_folder" ]]; then
    log ERROR "Folder lookup failed for $first_label or $second_label"
    exit 1
  fi
  if [[ "$first_folder" != "$second_folder" ]]; then
    log ERROR "$first_label and $second_label should share folder but differ ($first_folder vs $second_folder)"
    exit 1
  fi
  log SUCCESS "$first_label and $second_label share folderId=$first_folder"
}

verify_folder_structure() {
  local expected_path="$1"

  local projects_json="$TEMP_HOME/reset-projects.json"
  local folders_json="$TEMP_HOME/reset-folders.json"
  local workflows_json="$TEMP_HOME/reset-workflows.json"

  local status
  log INFO "Fetching projects for folder verification"
  status=$(rest_get_to_file "/rest/projects?skip=0&take=250" "$projects_json")
  if [[ "$status" != "200" ]]; then
    log ERROR "Failed to fetch projects for folder verification (status=$status)"
    cat "$projects_json" >&2 || true
    exit 1
  fi

  local project_id
  project_id=$(jq -r '.data[]? | select((.type // "") == "personal") | .id' "$projects_json" | head -n1)
  if [[ -z "$project_id" ]]; then
    log ERROR "Unable to determine personal project identifier from projects payload"
    cat "$projects_json" >&2
    exit 1
  fi

  log INFO "Fetching folders for project $project_id"
  status=$(rest_get_to_file "/rest/projects/$project_id/folders?skip=0&take=1000" "$folders_json")
  if [[ "$status" != "200" ]]; then
    log ERROR "Failed to fetch folders for project $project_id"
    cat "$folders_json" >&2 || true
    exit 1
  fi

  log INFO "Fetching workflows with folder metadata"
  status=$(rest_get_to_file "/rest/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=2000&sortBy=updatedAt%3Adesc" "$workflows_json")
  if [[ "$status" != "200" ]]; then
    log ERROR "Failed to fetch workflows with folder metadata"
    cat "$workflows_json" >&2 || true
    exit 1
  fi

  local folder_verification
  folder_verification=$(jq -n \
    --slurpfile workflows "$workflows_json" \
    --slurpfile folders "$folders_json" \
    --slurpfile expected "$expected_path" '
      def items(x):
        if (x | type) == "array" then x else (x.data // []) end;

      def build_map(folders):
        reduce (items(folders))[]? as $item ({}; . + { ($item.id // empty): { name: ($item.name // ""), parent: ($item.parentFolderId // null) }});

      def path_lookup($id; $map; $visited):
        if ($id == null) or ($id == "") then {path: [], error: null}
        elif ($visited | index($id)) != null then {path: [], error: {type: "cycle", chain: ($visited + [$id])}}
        else
          ($map[$id] // {name: null, parent: null}) as $node |
          if $node.name == null then {path: [], error: {type: "missing", id: $id}}
          else
            path_lookup($node.parent; $map; $visited + [$id]) as $parent |
            if $parent.error != null then $parent else {path: ($parent.path + [$node.name]), error: null} end
          end
        end;

      def path_result($id; $map):
        path_lookup($id; $map; []);

      def workflow_parent_id($wf):
        if ($wf.parentFolderId // "") != "" then $wf.parentFolderId
        elif ($wf.parentFolder.id // "") != "" then $wf.parentFolder.id
        elif ($wf.folderId // "") != "" then $wf.folderId
        else null end;

      def workflow_project_name($wf):
        if (($wf.homeProject.type // "") | ascii_downcase) == "personal" then "Personal"
        elif ($wf.homeProject.name // "") != "" then $wf.homeProject.name
        elif ($wf.project // "") != "" then $wf.project
        else "Personal" end;

      def lookup_workflow($name; $wfData):
        (items($wfData) | map(select((.resource // "") == "workflow" and (.name // "") == $name)) | first);

      ($workflows[0] // {}) as $wfData |
      ($folders[0] // {}) as $folderData |
      (build_map($folderData)) as $map |
      ($expected[0] // []) as $expectedList |
      [ $expectedList[] as $exp |
          (lookup_workflow($exp.name; $wfData)) as $wf |
          if $wf == null then {name: $exp.name, status: "missing"}
          else
            (workflow_parent_id($wf)) as $folderRef |
            (path_result($folderRef; $map)) as $pathInfo |
            if $pathInfo.error != null then {name: $exp.name, status: "path_resolution_error", details: $pathInfo.error}
            else
              ($pathInfo.path) as $path |
              (workflow_project_name($wf)) as $projectName |
              (if ($projectName // "") == "" then $path
               elif (($path | length) > 0 and $path[0] == $projectName) then $path
               else [$projectName] + $path end) as $fullPath |
              (if (($projectName // "") | ascii_downcase) == "personal" then
                 if (($fullPath | length) > 0) and (($fullPath[0] // "" | ascii_downcase) == "personal") then
                   $fullPath[1:]
                 else
                   $fullPath
                 end
               else
                 $fullPath
               end) as $normalizedFullPath |
              if ($normalizedFullPath == $exp.path) then empty else {name: $exp.name, status: "path_mismatch", actual: $normalizedFullPath, expected: $exp.path} end
            end
          end
        ]
    ')

  if [[ "$folder_verification" != "[]" ]]; then
    log ERROR "Folder placement verification failed: $folder_verification"
    exit 1
  fi

  log SUCCESS "Verified workflow folder placements."
}

rest_update_workflow_folder() {
    local workflow_id="$1"
  local target_folder_id="${2:-}"
  local current_payload="$TEMP_HOME/workflow-$workflow_id-current.json"
  local update_response="$TEMP_HOME/workflow-$workflow_id-update.json"

  local destination_parent_folder
  if [[ -n "$target_folder_id" ]]; then
    destination_parent_folder="$target_folder_id"
  else
    destination_parent_folder="0"
  fi

  local status
  status=$(rest_get_to_file "/rest/workflows/$workflow_id" "$current_payload")
  if [[ "$status" != "200" ]]; then
    log ERROR "Failed to fetch workflow $workflow_id for folder update (status=$status)"
    cat "$current_payload" >&2 || true
    exit 1
  fi

  local patch_json
  patch_json=$(jq -c --arg folder "$destination_parent_folder" '
    (.data // {}) as $data |
    {
      id: $data.id,
      name: $data.name,
      nodes: $data.nodes,
      connections: $data.connections,
      settings: ($data.settings // {}),
      staticData: ($data.staticData // null),
      pinData: ($data.pinData // null),
      meta: ($data.meta // null),
      active: ($data.active // false),
      tags: ($data.tags // []),
      versionId: ($data.versionId // null),
      folderId: (if $folder == "0" then null elif ($folder | length) > 0 then $folder else null end),
      parentFolderId: (if ($folder | length) > 0 then $folder else null end),
      projectId: (
        if ($data.projectId // "") != "" then $data.projectId
        elif ($data.homeProject.id // "") != "" then $data.homeProject.id
        else null end
      ),
      sharedWithProjects: ($data.sharedWithProjects // []),
      scopes: ($data.scopes // [])
    }
  ' "$current_payload")

  if [[ -z "$patch_json" || "$patch_json" == "null" ]]; then
    log ERROR "Unable to build update payload for workflow $workflow_id"
    cat "$current_payload" >&2 || true
    exit 1
  fi

  log INFO "Updating workflow $workflow_id folder → ${target_folder_id:-<root>}"

  local update_status
  update_status=$(curl -sS --retry 5 --retry-delay 2 --retry-all-errors \
    -b "$SESSION_COOKIES" \
    -H "Content-Type: application/json" \
    -X PATCH \
    -d "$patch_json" \
    -o "$update_response" \
    "$REST_BASE_URL/rest/workflows/$workflow_id" \
    -w '%{http_code}')

  if [[ "$update_status" != "200" ]]; then
    log ERROR "Failed to update folder for workflow $workflow_id (status=$update_status)"
    cat "$update_response" >&2 || true
    exit 1
  fi
}

generate_noise_node_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

create_noise_workflow() {
  local name="$1"
  local slug
  slug=$(printf '%s' "$name" | tr '[:space:]' '-' | tr -cd 'A-Za-z0-9_-')
  if [[ -z "$slug" ]]; then
    slug="noise"
  fi
  local payload="$TEMP_HOME/noise-${slug}.json"
  local response="$TEMP_HOME/noise-${slug}-response.json"
  local node_id
  node_id="$(generate_noise_node_id)"

  cat >"$payload" <<JSON
{
  "name": "$name",
  "nodes": [
    {
      "parameters": {},
      "id": "$node_id",
      "name": "Start",
      "type": "n8n-nodes-base.start",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "connections": {},
  "settings": {},
  "active": false
}
JSON

  local status
  status=$(curl -sS -b "$SESSION_COOKIES" \
    -H "Content-Type: application/json" \
    -o "$response" \
    -d @"$payload" \
    "$REST_BASE_URL/rest/workflows" \
    -w '%{http_code}')

  if [[ "$status" != "200" && "$status" != "201" ]]; then
    log ERROR "Failed to seed noise workflow '$name' (status=$status)"
    cat "$response" >&2 || true
    exit 1
  fi

  local new_id
  new_id=$(jq -r '.data.id // .id // empty' "$response" 2>/dev/null || printf '')
  if [[ -z "$new_id" ]]; then
    log ERROR "Noise workflow '$name' creation response missing id"
    cat "$response" >&2 || true
    exit 1
  fi

  log INFO "Seeded noise workflow '$name' (id: $new_id)"
}

seed_workspace_noise() {
  local label="$1"
  log INFO "Seeding extraneous workflows before $label"
  create_noise_workflow "Noise Root 1 (${label})"
  create_noise_workflow "Noise Root 2 (${label})"
}


run_reset_command() {
  local mode="$1"; shift
  local commit="$1"; shift
  local label="$1"; shift
  local log_path="$1"; shift
  local -a extra_cli_args=("$@")

  log HEADER "Executing $mode reset for $label"

  if test_verbose_enabled; then
    log INFO "n8n-git CLI output streaming below (also saved to $log_path)"
  else
    log INFO "n8n-git CLI output saved to $log_path (suppressed)"
  fi
  : >"$log_path"

  local status
  set +e
  (
    cd "$TEST_REPO_DIR" || exit 1
    export HOME="$TEMP_HOME"
    export N8N_EMAIL="$TEST_EMAIL"
    export N8N_PASSWORD="$TEST_PASSWORD"
    export DOCKER_EXEC_USER="node"
    test_run_with_msys "$MANAGER_SCRIPT" reset \
      --container "$CONTAINER_NAME" \
      --mode "$mode" \
      --to "$commit" \
      --n8n-url "http://localhost:${CONTAINER_PORT}" \
      --n8n-email "$TEST_EMAIL" \
      --n8n-password "$TEST_PASSWORD" \
      --local-path "$TEST_REPO_DIR" \
      --config /dev/null \
      --defaults \
      "${CLI_VERBOSE_FLAGS[@]}" \
      "${extra_cli_args[@]}"
  ) 2>&1 | if test_verbose_enabled; then tee "$log_path"; else cat > "$log_path"; fi
  status=${PIPESTATUS[0]}
  set -e

  if (( status != 0 )); then
    log ERROR "n8n-git reset ($mode) for $label failed with exit code $status"
    if ! test_verbose_enabled; then
      log ERROR "Failure log output:"
      cat "$log_path" >&2
    fi
    exit "$status"
  fi
}

assert_workflow_absent() {
  local workflow_name="$1"
  local export_json="$2"
  if printf '%s' "$export_json" | jq -e --arg name "$workflow_name" '.[] | select(.name == $name)' >/dev/null; then
    log ERROR "Workflow '$workflow_name' unexpectedly present"
    printf '%s\n' "$export_json" | jq '.' >&2
    exit 1
  fi
  log SUCCESS "Workflow '$workflow_name' absent as expected"
}

assert_workflow_archival_state() {
  local workflow_name="$1"
  local export_json="$2"
  local expected_state="$3"
  local actual
  actual=$(printf '%s' "$export_json" | jq -r --arg name "$workflow_name" '.[] | select(.name == $name) | (.isArchived // false)')
  if [[ "$actual" != "$expected_state" ]]; then
    log ERROR "Workflow '$workflow_name' archived state expected $expected_state, found $actual"
    printf '%s\n' "$export_json" | jq '.' >&2
    exit 1
  fi
  log SUCCESS "Workflow '$workflow_name' archived state = $actual"
}

assert_workflow_active_state() {
  local workflow_name="$1"
  local export_json="$2"
  local expected_state="$3"
  local actual
  actual=$(printf '%s' "$export_json" | jq -r --arg name "$workflow_name" '.[] | select(.name == $name) | (.active // false)')
  if [[ "$actual" != "$expected_state" ]]; then
    log ERROR "Workflow '$workflow_name' active state expected $expected_state, found $actual"
    printf '%s\n' "$export_json" | jq '.' >&2
    exit 1
  fi
  log SUCCESS "Workflow '$workflow_name' active state = $actual"
}

assert_rest_not_found() {
  local workflow_id="$1"
  local label="$2"
  local attempts="${3:-30}"
  local delay="${4:-2}"
  local response_path="$TEMP_HOME/rest-$workflow_id.json"
  local status=""

  for ((attempt=1; attempt<=attempts; attempt++)); do
    status=$(rest_get_to_file "/rest/workflows/$workflow_id" "$response_path")
    if [[ "$status" == "404" ]]; then
      log SUCCESS "REST lookup for $label returned 404 as expected"
      return 0
    fi
    sleep "$delay"
  done

  log ERROR "Expected 404 when fetching $label (status=$status)"
  cat "$response_path" >&2 || true
  exit 1
}

assert_rest_archived() {
  local workflow_id="$1"
  local label="$2"
  local attempts="${3:-30}"
  local delay="${4:-2}"
  local response_path="$TEMP_HOME/rest-$workflow_id.json"
  local status=""

  for ((attempt=1; attempt<=attempts; attempt++)); do
    status=$(rest_get_to_file "/rest/workflows/$workflow_id" "$response_path")
    if [[ "$status" == "200" ]]; then
      local archived
      archived=$(jq -r '(.data // {}) | ((.isArchived // .archived // false) | tostring)' "$response_path")
      if [[ "${archived,,}" == "true" ]]; then
        log SUCCESS "REST payload confirms $label archived"
        return 0
      fi
    fi
    sleep "$delay"
  done

  log ERROR "$label did not report archived state"
  cat "$response_path" >&2 || true
  exit 1
}

log_verbose_mode
create_workflow_repo

# Start n8n container with license patch to enable archival endpoints
log INFO "Starting n8n container $CONTAINER_NAME"
if ! testbed_start_container_with_license_patch "$CONTAINER_NAME" "$CONTAINER_BASE_PORT" >/dev/null; then
  log ERROR "Failed to start n8n container"
  exit 1
fi

CONTAINER_PORT="$(testbed_container_port "$CONTAINER_NAME")"
if [[ -z "$CONTAINER_PORT" ]]; then
  log ERROR "Unable to determine container port"
  exit 1
fi

log INFO "Waiting for n8n to become ready"
if ! testbed_wait_for_container "$CONTAINER_NAME" 60 2; then
  log ERROR "Container did not reach running state"
  exit 1
fi

if ! testbed_wait_for_http "http://localhost:${CONTAINER_PORT}/" 80 2; then
  log ERROR "n8n HTTP endpoint not ready"
  exit 1
fi

# Prepare authenticated session and configuration for CLI operations
authenticate_session

cat >"$TEST_REPO_DIR/.config" <<CONFIG
n8n_base_url=http://localhost:${CONTAINER_PORT}
workflows=local
credentials=0
environment=0
folder_structure=true
local_backup_path=$TEST_REPO_DIR
CONFIG

CLI_VERBOSE_FLAGS=()
if test_verbose_enabled; then
  CLI_VERBOSE_FLAGS+=(--verbose)
fi

# Stage 1: hard reset to HEAD to seed workflows in n8n
git -C "$TEST_REPO_DIR" checkout -q "$COMMIT_HEAD"
run_reset_command hard "$COMMIT_HEAD" "head commit" "$TEMP_HOME/head-reset.log"

if ! grep -q "Pull pipeline import completed" "$TEMP_HOME/head-reset.log"; then
  log ERROR "Hard reset did not invoke pull import pipeline"
  cat "$TEMP_HOME/head-reset.log" >&2
  exit 1
fi

initial_export=$(await_workflow_export 3 "post head reset")
ALPHA_ID=$(require_workflow_id "Root Workflow Alpha" "$initial_export")
BETA_ID=$(require_workflow_id "Folder Workflow Beta" "$initial_export")
GAMMA_ID=$(require_workflow_id "Folder Workflow Gamma" "$initial_export")
GAMMA_ID_INITIAL="$GAMMA_ID"

assert_workflow_archival_state "Folder Workflow Beta" "$initial_export" "false"
assert_workflow_archival_state "Folder Workflow Gamma" "$initial_export" "false"
assert_workflow_active_state "Folder Workflow Beta" "$initial_export" "false"
assert_workflow_active_state "Folder Workflow Gamma" "$initial_export" "false"
assert_workflow_active_state "Root Workflow Alpha" "$initial_export" "false"
assert_workflow_in_root_folder "$ALPHA_ID" "Root Workflow Alpha"
assert_workflows_share_folder "$BETA_ID" "$GAMMA_ID" "Folder Workflow Beta" "Folder Workflow Gamma"

if [[ "${RESET_SKIP_BACKTRACK:-0}" != "1" ]]; then
  # Stage 2: hard reset to mid commit, expect folder gamma removed
  git -C "$TEST_REPO_DIR" checkout -q "$COMMIT_MID"
  run_reset_command hard "$COMMIT_MID" "mid commit" "$TEMP_HOME/hard-reset.log"

  if ! grep -q "Pull pipeline import completed" "$TEMP_HOME/hard-reset.log"; then
    log ERROR "Mid commit reset did not invoke pull import pipeline"
    cat "$TEMP_HOME/hard-reset.log" >&2
    exit 1
  fi

  if ! grep -q "Deleted workflow" "$TEMP_HOME/hard-reset.log"; then
    log ERROR "Hard reset did not report deletions"
    cat "$TEMP_HOME/hard-reset.log" >&2
    exit 1
  fi

  post_hard_export=$(await_workflow_export 2 "post hard reset")
  ALPHA_ID=$(require_workflow_id "Root Workflow Alpha" "$post_hard_export")
  BETA_ID=$(require_workflow_id "Folder Workflow Beta" "$post_hard_export")
  GAMMA_ID_CURRENT=$(workflow_id_by_name "Folder Workflow Gamma" "$post_hard_export")

  assert_workflow_absent "Folder Workflow Gamma" "$post_hard_export"
  assert_rest_not_found "$GAMMA_ID_INITIAL" "Folder Workflow Gamma"
  assert_workflow_archival_state "Folder Workflow Beta" "$post_hard_export" "false"
  assert_workflow_active_state "Folder Workflow Beta" "$post_hard_export" "false"
  assert_workflow_active_state "Root Workflow Alpha" "$post_hard_export" "false"
  assert_workflow_in_root_folder "$ALPHA_ID" "Root Workflow Alpha"
  assert_workflow_in_non_root_folder "$BETA_ID" "Folder Workflow Beta"

  if [[ -n "$GAMMA_ID_CURRENT" ]]; then
    log ERROR "Gamma workflow unexpectedly present after hard reset"
    exit 1
  fi

  # Stage 3: soft reset to baseline, expect beta archived and alpha active
  git -C "$TEST_REPO_DIR" checkout -q "$COMMIT_BASELINE"
  seed_workspace_noise "soft baseline"
  run_reset_command soft "$COMMIT_BASELINE" "baseline commit" "$TEMP_HOME/soft-reset.log"

  if ! grep -q "Pull pipeline import completed" "$TEMP_HOME/soft-reset.log"; then
    log ERROR "Soft reset did not invoke pull import pipeline"
    cat "$TEMP_HOME/soft-reset.log" >&2
    exit 1
  fi

  post_soft_export=$(await_workflow_export 1 "post soft reset")
  ALPHA_ID=$(require_workflow_id "Root Workflow Alpha" "$post_soft_export")

  assert_workflow_absent "Folder Workflow Beta" "$post_soft_export"
  assert_workflow_archival_state "Root Workflow Alpha" "$post_soft_export" "false"
  assert_workflow_active_state "Root Workflow Alpha" "$post_soft_export" "false"
  assert_workflow_in_root_folder "$ALPHA_ID" "Root Workflow Alpha"
  assert_rest_not_found "$BETA_ID" "Folder Workflow Beta"
  assert_rest_not_found "$GAMMA_ID_INITIAL" "Folder Workflow Gamma"
else
  log INFO "Skipping backtracking reset stages (RESET_SKIP_BACKTRACK=$(RESET_SKIP_BACKTRACK))"
fi

# Stage 4: hard reset to head using github_path slice to limit scope
log INFO "Validating github_path slice handling"
seed_workspace_noise "github slice"
git -C "$TEST_REPO_DIR" checkout -q "$COMMIT_HEAD"
run_reset_command hard "$COMMIT_HEAD" "head commit (github slice)" "$TEMP_HOME/head-reset-githubpath.log" --github-path "workflows/Teams/Support"

if ! grep -q "Pull pipeline import completed" "$TEMP_HOME/head-reset-githubpath.log"; then
  log ERROR "GitHub slice reset did not invoke pull import pipeline"
  cat "$TEMP_HOME/head-reset-githubpath.log" >&2
  exit 1
fi

slice_export=$(await_workflow_export 2 "post github slice reset")
assert_workflow_absent "Root Workflow Alpha" "$slice_export"
BETA_ID=$(require_workflow_id "Folder Workflow Beta" "$slice_export")
GAMMA_ID=$(require_workflow_id "Folder Workflow Gamma" "$slice_export")
assert_workflows_share_folder "$BETA_ID" "$GAMMA_ID" "Folder Workflow Beta" "Folder Workflow Gamma"
assert_workflow_archival_state "Folder Workflow Beta" "$slice_export" "false"
assert_workflow_archival_state "Folder Workflow Gamma" "$slice_export" "false"
assert_workflow_active_state "Folder Workflow Beta" "$slice_export" "false"
assert_workflow_active_state "Folder Workflow Gamma" "$slice_export" "false"

# Stage 4b: verify scoped reimport mints new IDs when existing workflow moved outside target folder
log INFO "Validating scoped import ID reminting when conflicts exist outside scope"
rest_update_workflow_folder "$BETA_ID" ""

local_beta_folder_post_move="$(rest_fetch_workflow_folder_id "$BETA_ID" "Folder Workflow Beta (moved to root)")"
if [[ -n "$local_beta_folder_post_move" ]]; then
  log ERROR "Expected Folder Workflow Beta to reside in root after manual move but folderId=$local_beta_folder_post_move"
  exit 1
fi

run_reset_command hard "$COMMIT_HEAD" "head commit (github slice with scope conflict)" "$TEMP_HOME/head-reset-githubpath-conflict.log" --github-path "workflows/Teams/Support"

if ! grep -q "Pull pipeline import completed" "$TEMP_HOME/head-reset-githubpath-conflict.log"; then
  log ERROR "Scoped conflict reset did not invoke pull import pipeline"
  cat "$TEMP_HOME/head-reset-githubpath-conflict.log" >&2
  exit 1
fi

conflict_export=$(await_workflow_export 2 "post github slice conflict reset")
BETA_ID=$(require_workflow_id "Folder Workflow Beta" "$conflict_export")
GAMMA_ID=$(require_workflow_id "Folder Workflow Gamma" "$conflict_export")
assert_workflows_share_folder "$BETA_ID" "$GAMMA_ID" "Folder Workflow Beta" "Folder Workflow Gamma"
assert_workflow_in_non_root_folder "$BETA_ID" "Folder Workflow Beta"
slice_export="$conflict_export"

# Stage 5: hard reset to head with custom n8n path prefix
log INFO "Validating n8n_path folder prefix handling"
git -C "$TEST_REPO_DIR" checkout -q "$COMMIT_HEAD"
previous_n8n_path="${N8N_PATH:-}"
export N8N_PATH="Another Folder"
run_reset_command hard "$COMMIT_HEAD" "head commit (scoped path)" "$TEMP_HOME/head-reset-n8npath.log"
if [[ -n "$previous_n8n_path" ]]; then
  export N8N_PATH="$previous_n8n_path"
else
  unset N8N_PATH
fi

log HEADER "Reset Test Summary"

cat <<'JSON' >"$TEMP_HOME/expected-scoped-paths.json"
[
  {"name":"Root Workflow Alpha","path":["Another Folder"]},
  {"name":"Folder Workflow Beta","path":["Another Folder","Teams","Support"]},
  {"name":"Folder Workflow Gamma","path":["Another Folder","Teams","Support"]}
]
JSON

verify_folder_structure "$TEMP_HOME/expected-scoped-paths.json"

if ! final_export=$(await_workflow_export "" "final reset summary"); then
  log ERROR "Unable to capture final workflow export for summary"
  exit 1
fi

if ! final_total=$(jq 'length' <<<"$final_export"); then
  log ERROR "Failed to parse workflow export for final summary"
  printf '%s\n' "$final_export" | jq '.' >&2 || printf '%s\n' "$final_export" >&2
  exit 1
fi

if ! final_archived=$(jq '[.[] | select((.isArchived // false) == true)] | length' <<<"$final_export"); then
  log ERROR "Failed to parse archived workflow count for final summary"
  printf '%s\n' "$final_export" | jq '.' >&2 || printf '%s\n' "$final_export" >&2
  exit 1
fi

# Final success summary
log SUCCESS "Reset tests completed successfully"

exit 0
