#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/tests}"
MANAGER_SCRIPT="$ROOT_DIR/n8n-git.sh"
source "$SCRIPT_DIR/utils/n8n-testbed.sh"

CONTAINER_NAME="n8n-pull-id-test"
CONTAINER_BASE_PORT=${CONTAINER_BASE_PORT:-5679}
CONTAINER_PORT=""
TEST_EMAIL="${TEST_EMAIL:-$(testbed_default_owner_email)}"
TEST_PASSWORD="${TEST_PASSWORD:-$(testbed_default_owner_password)}"
TEST_FIRST_NAME="${TEST_FIRST_NAME:-$(testbed_default_owner_first)}"
TEST_LAST_NAME="${TEST_LAST_NAME:-$(testbed_default_owner_last)}"

test_apply_msys_overrides

TEST_VERBOSE=${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}

log HEADER "n8n-git Pull Test"

if ! test_configure_docker_cli test_run_with_msys; then
  exit 1
fi

log_verbose_mode() {
  if test_verbose_enabled; then
    log INFO "Running n8n-git.sh in verbose mode"
  fi
}

cleanup() {
  log INFO "Cleaning up test environment..."
  testbed_docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ -n "${TEMP_HOME:-}" && -d "$TEMP_HOME" ]]; then
    if test_should_keep_artifacts; then
      log INFO "Preserving temporary test artifacts in $TEMP_HOME"
    else
      rm -rf "$TEMP_HOME"
    fi
  fi
}
trap cleanup EXIT

verify_folder_structure() {
  local expected_path="$1"

  log INFO "Authenticating REST session for folder verification"
  sleep 2

  if ! testbed_login "$PULL_BASE_URL" "$TEST_EMAIL" "$TEST_PASSWORD" "$SESSION_COOKIES"; then
    log ERROR "Failed to establish authenticated session for folder verification"
    exit 1
  fi

  local projects_json="$TEMP_HOME/projects.json"
  local folders_json="$TEMP_HOME/folders.json"
  local workflows_json="$TEMP_HOME/workflows-api.json"

  curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "$PULL_BASE_URL/rest/projects?skip=0&take=250" >"$projects_json"
  if [[ ! -s "$projects_json" ]]; then
    log ERROR "Failed to fetch projects for folder verification"
    exit 1
  fi

  local project_id
  project_id=$(jq -r '.data[]? | select((.type // "") == "personal") | .id' "$projects_json" | head -n1)
  if [[ -z "$project_id" ]]; then
    log ERROR "Unable to determine personal project identifier from projects payload"
    cat "$projects_json" >&2
    exit 1
  fi

  curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "$PULL_BASE_URL/rest/projects/$project_id/folders?skip=0&take=1000" >"$folders_json"
  if [[ ! -s "$folders_json" ]]; then
    log ERROR "Failed to fetch folders for project $project_id"
    exit 1
  fi

  curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "$PULL_BASE_URL/rest/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=2000&sortBy=updatedAt%3Adesc" >"$workflows_json"
  if [[ ! -s "$workflows_json" ]]; then
    log ERROR "Failed to fetch workflows with folder metadata"
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

      def path_from_folder($id; $map):
        if ($id == null) or ($id == "") then []
        else
          ($map[$id] // {name: null, parent: null}) as $node |
          if $node.name == null then [] else (path_from_folder($node.parent; $map) + [$node.name]) end
        end;

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
            (path_from_folder($folderRef; $map)) as $path |
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
        ]
    ')

  if [[ "$folder_verification" != "[]" ]]; then
    log ERROR "Folder placement verification failed: $folder_verification"
    exit 1
  fi

  log SUCCESS "Verified workflow folder placements."
}

log INFO "Starting workflow ID sanitization pull test"
log_verbose_mode

log INFO "Starting disposable n8n container ($CONTAINER_NAME) with license bypass"
if ! testbed_start_container_with_license_patch "$CONTAINER_NAME" "$CONTAINER_BASE_PORT" >/dev/null; then
  log ERROR "Failed to start n8n container"
  exit 1
fi

CONTAINER_PORT="$(testbed_container_port "$CONTAINER_NAME")"
if [[ -z "$CONTAINER_PORT" ]]; then
  log ERROR "Failed to determine container port"
  exit 1
fi

log INFO "Waiting for n8n to become ready"
if ! testbed_wait_for_container "$CONTAINER_NAME" 60 3; then
  log ERROR "n8n container did not reach running state"
  exit 1
fi

if ! testbed_wait_for_http "http://localhost:${CONTAINER_PORT}/" 80 3; then
  log ERROR "n8n did not become ready within timeout"
  exit 1
fi

log INFO "Preparing fixture workflow directory"
TEMP_HOME=$(mktemp -d)
SESSION_COOKIES="$TEMP_HOME/session.cookies"
: >"$SESSION_COOKIES"
PULL_BASE="$TEMP_HOME/n8n-backup"
mkdir -p \
  "$PULL_BASE/Personal/Projects/Folder/Subfolder" \
  "$PULL_BASE/Personal/Project1" \
  "$PULL_BASE/Personal/Project2"

cat <<'JSON' >"$PULL_BASE/Personal/Projects/Folder/Subfolder/001_bad_id.json"
{
  "id": "wf-1",
  "name": "Bad ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Start",
      "type": "n8n-nodes-base.start",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-1"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$PULL_BASE/Personal/002_no_id.json"
{
  "name": "No ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "When Webhook Calls",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-2"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$PULL_BASE/Personal/Project1/003_correct.json"
{
  "id": "12345678abcdefgh",
  "name": "Correct ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Cron",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-3"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$PULL_BASE/Personal/Project2/004_duplicate.json"
{
  "id": "12345678abcdefgh",
  "name": "Duplicate ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Cron",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [360, 160]
    }
  ],
  "meta": {
    "instanceId": "test-instance-4"
  },
  "connections": {}
}
JSON

chmod 600 \
  "$PULL_BASE"/Personal/Projects/Folder/Subfolder/001_bad_id.json \
  "$PULL_BASE"/Personal/002_no_id.json \
  "$PULL_BASE"/Personal/Project1/003_correct.json \
  "$PULL_BASE"/Personal/Project2/004_duplicate.json

log INFO "Completing owner setup via REST API"
if ! testbed_prepare_owner "$CONTAINER_NAME" "http://localhost:${CONTAINER_PORT}" "$TEST_EMAIL" "$TEST_PASSWORD" "$TEST_FIRST_NAME" "$TEST_LAST_NAME" "$SESSION_COOKIES"; then
  log ERROR "Failed to establish n8n session owner via REST API"
  exit 1
fi

MANIFEST_PATH="$TEMP_HOME/manifest.json"
PULL_LOG="$TEMP_HOME/pull.log"

log INFO "Running pull with sanitized workflow IDs"
CLI_VERBOSE_FLAGS=()
if test_verbose_enabled; then
  CLI_VERBOSE_FLAGS+=(--verbose)
fi

PULL_BASE_URL="http://localhost:${CONTAINER_PORT}"

if ! DOCKER_EXEC_USER="node" \
  HOME="$TEMP_HOME" \
  PULL_MANIFEST_DEBUG_PATH="$MANIFEST_PATH" \
  test_run_with_msys "$MANAGER_SCRIPT" pull \
    "${CLI_VERBOSE_FLAGS[@]}" \
    --container "$CONTAINER_NAME" \
    --local-path "$PULL_BASE" \
    --workflows 1 \
    --credentials 0 \
    --folder-structure \
    --config /dev/null \
    --n8n-url "$PULL_BASE_URL" \
    --n8n-email "$TEST_EMAIL" \
    --n8n-password "$TEST_PASSWORD" \
    --github-path "Personal/" \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    2>&1 | tee "$PULL_LOG"; then
  while IFS= read -r line; do
    log ERROR "$line"
  done <"$PULL_LOG"
  exit 1
fi

if ! grep -q "Successfully authenticated with n8n session" "$PULL_LOG"; then
  log ERROR "Expected session-based authentication to succeed"
  cat "$PULL_LOG" >&2
  exit 1
fi

if grep -q "Collecting folder entry without workflow ID" "$PULL_LOG"; then
  log ERROR "Folder collection should not miss workflow IDs"
  cat "$PULL_LOG" >&2
  exit 1
fi

log INFO "Exporting workflows from n8n for verification"
testbed_docker exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export.json' >/dev/null
POST_EXPORT=$(testbed_docker exec -u node "$CONTAINER_NAME" sh -c 'cat /tmp/export.json')

WORKFLOW_COUNT=$(printf '%s' "$POST_EXPORT" | jq 'length')
if [[ "$WORKFLOW_COUNT" -ne 4 ]]; then
  log ERROR "Expected four workflows after pull, found $WORKFLOW_COUNT"
  exit 1
fi

INVALID_IDS=$(printf '%s' "$POST_EXPORT" | jq '[ .[].id | select(test("^[A-Za-z0-9]{16}$") | not) ] | length')
if [[ "$INVALID_IDS" -ne 0 ]]; then
    log ERROR "One or more pulled workflows have invalid IDs"
    exit 1
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
    log ERROR "Expected reconciled manifest at $MANIFEST_PATH"
    exit 1
fi

MANIFEST_COUNT=$(jq -s 'length' "$MANIFEST_PATH")
if [[ "$MANIFEST_COUNT" -ne 4 ]]; then
  log ERROR "Expected manifest to contain four entries, found $MANIFEST_COUNT"
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

MISSING_NOTES=$(jq -s '[ .[]
  | select((.originalWorkflowId // "") | length > 0)
  | select(((.originalWorkflowId // "") | test("^[A-Za-z0-9]{16}$")) | not)
  | select(((.sanitizedIdNote // "") | length) == 0)
] | length' "$MANIFEST_PATH")
if [[ "$MISSING_NOTES" -ne 0 ]]; then
  log ERROR "Manifest entries are missing sanitized ID notes"
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

MANIFEST_MISMATCH=$(jq -s --argjson exported "$POST_EXPORT" '
  [ .[] as $entry |
    ($exported | map(select((.name // "") == ($entry.name // ""))) | first) as $match
    | if $match == null then {name: $entry.name, reason: "missing"}
      elif ($match.id // "") | test("^[A-Za-z0-9]{16}$") | not then {name: $entry.name, reason: "invalid_id"}
      else empty end
  ]
' "$MANIFEST_PATH")

if [[ "$MANIFEST_MISMATCH" != "[]" ]]; then
  log ERROR "Manifest did not align with exported workflow IDs"
  printf '%s\n' "$MANIFEST_MISMATCH" >&2
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

SANITIZED_IDS=$(printf '%s' "$POST_EXPORT" | jq -r 'map({name: .name, id: .id})')
log DEBUG "Verified sanitized workflow IDs: $SANITIZED_IDS"

EXPECTED_FOLDERS_PATH="$TEMP_HOME/expected-folders.json"
cat <<'JSON' >"$EXPECTED_FOLDERS_PATH"
[
  {"name":"Bad ID Workflow","path":["Projects","Folder","Subfolder"]},
  {"name":"No ID Workflow","path":[]},
  {"name":"Correct ID Workflow","path":["Project1"]},
  {"name":"Duplicate ID Workflow","path":["Project2"]}
]
JSON

verify_folder_structure "$EXPECTED_FOLDERS_PATH"

ID_BAD=$(printf '%s' "$POST_EXPORT" | jq -r '.[] | select(.name == "Bad ID Workflow") | .id' || true)
ID_NO=$(printf '%s' "$POST_EXPORT" | jq -r '.[] | select(.name == "No ID Workflow") | .id' || true)
ID_CORRECT=$(printf '%s' "$POST_EXPORT" | jq -r '.[] | select(.name == "Correct ID Workflow") | .id' || true)
ID_DUPLICATE=$(printf '%s' "$POST_EXPORT" | jq -r '.[] | select(.name == "Duplicate ID Workflow") | .id' || true)

for pair in \
  "Bad ID Workflow:$ID_BAD" \
  "No ID Workflow:$ID_NO" \
  "Correct ID Workflow:$ID_CORRECT" \
  "Duplicate ID Workflow:$ID_DUPLICATE"; do
  IFS=':' read -r label value <<<"$pair"
  if [[ -z "$value" ]] || ! [[ "$value" =~ ^[A-Za-z0-9]{16}$ ]]; then
    log ERROR "Missing or invalid ID for $label after first pull ($value)"
    exit 1
  fi
done

log INFO "Preparing delta fixture for double pull validation"
SECOND_PULL_DIR="$TEMP_HOME/pull-second"
rm -rf "$SECOND_PULL_DIR"
mkdir -p \
  "$SECOND_PULL_DIR/Personal/Projects/Folder/Subfolder" \
  "$SECOND_PULL_DIR/Personal/Project1" \
  "$SECOND_PULL_DIR/Personal/Project2"

cat <<'JSON' >"$SECOND_PULL_DIR/Personal/Projects/Folder/Subfolder/001_bad_id.json"
{
  "id": "AAAAAAAAAAAAAAAA",
  "name": "Bad ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Start",
      "type": "n8n-nodes-base.start",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-1"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$SECOND_PULL_DIR/Personal/002_no_id.json"
{
  "id": "BBBBBBBBBBBBBBBB",
  "name": "No ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "When Webhook Calls",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-2"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$SECOND_PULL_DIR/Personal/Project1/003_correct.json"
{
  "id": "CCCCCCCCCCCCCCCC",
  "name": "Correct ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Cron",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-3"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$SECOND_PULL_DIR/Personal/Project2/004_duplicate.json"
{
  "id": "DDDDDDDDDDDDDDDD",
  "name": "Duplicate ID Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Cron",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [360, 160]
    }
  ],
  "meta": {
    "instanceId": "test-instance-4"
  },
  "connections": {}
}
JSON

cat <<JSON >"$SECOND_PULL_DIR/Personal/Projects/Folder/Subfolder/005_injected.json"
{
  "id": "$ID_BAD",
  "name": "Injected Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-5"
  },
  "connections": {}
}
JSON

chmod 600 \
  "$SECOND_PULL_DIR"/Personal/Projects/Folder/Subfolder/*.json \
  "$SECOND_PULL_DIR"/Personal/002_no_id.json \
  "$SECOND_PULL_DIR"/Personal/Project1/003_correct.json \
  "$SECOND_PULL_DIR"/Personal/Project2/004_duplicate.json

MANIFEST_SECOND="$TEMP_HOME/manifest-second.json"
PULL_LOG_SECOND="$TEMP_HOME/pull-second.log"
PULL_SECOND_PATH=$(test_convert_path_for_cli "$SECOND_PULL_DIR")

log INFO "Running second pull to validate ID stability"
if ! DOCKER_EXEC_USER="node" \
  HOME="$TEMP_HOME" \
  PULL_MANIFEST_DEBUG_PATH="$MANIFEST_SECOND" \
  test_run_with_msys "$MANAGER_SCRIPT" pull \
    --container "$CONTAINER_NAME" \
    --local-path "$PULL_SECOND_PATH" \
    --workflows 1 \
    --credentials 0 \
    --folder-structure \
    --config /dev/null \
    --n8n-url "$PULL_BASE_URL" \
    --n8n-email "$TEST_EMAIL" \
    --n8n-password "$TEST_PASSWORD" \
    --github-path "Personal/" \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    2>&1 | tee "$PULL_LOG_SECOND"; then
  while IFS= read -r line; do
    log ERROR "$line"
  done <"$PULL_LOG_SECOND"
  exit 1
fi

log INFO "Exporting workflows after double pull"
testbed_docker exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export-second.json' >/dev/null
POST_EXPORT_SECOND=$(testbed_docker exec -u node "$CONTAINER_NAME" sh -c 'cat /tmp/export-second.json')

if [[ ! -f "$MANIFEST_SECOND" ]]; then
  log ERROR "Expected manifest for second pull at $MANIFEST_SECOND"
  exit 1
fi

# Manifest records workflows that require reconciliation. The injected workflow
# now triggers its own manifest entry because the ID gets rejected and a new ID
# is minted (sanitized conflict note). Expect five total entries.
MANIFEST_SECOND_COUNT=$(jq -s 'length' "$MANIFEST_SECOND")
if [[ "$MANIFEST_SECOND_COUNT" -ne 5 ]]; then
  log ERROR "Expected manifest to contain five reconciliation entries after double pull, found $MANIFEST_SECOND_COUNT"
  cat "$MANIFEST_SECOND" >&2
  exit 1
fi

ID_BAD_SECOND=$(printf '%s' "$POST_EXPORT_SECOND" | jq -r '.[] | select(.name == "Bad ID Workflow") | .id' || true)
ID_NO_SECOND=$(printf '%s' "$POST_EXPORT_SECOND" | jq -r '.[] | select(.name == "No ID Workflow") | .id' || true)
ID_CORRECT_SECOND=$(printf '%s' "$POST_EXPORT_SECOND" | jq -r '.[] | select(.name == "Correct ID Workflow") | .id' || true)
ID_DUPLICATE_SECOND=$(printf '%s' "$POST_EXPORT_SECOND" | jq -r '.[] | select(.name == "Duplicate ID Workflow") | .id' || true)
ID_INJECTED=$(printf '%s' "$POST_EXPORT_SECOND" | jq -r '.[] | select(.name == "Injected Workflow") | .id' || true)

if [[ "$ID_BAD_SECOND" != "$ID_BAD" ]] || [[ "$ID_NO_SECOND" != "$ID_NO" ]] \
   || [[ "$ID_CORRECT_SECOND" != "$ID_CORRECT" ]] || [[ "$ID_DUPLICATE_SECOND" != "$ID_DUPLICATE" ]]; then
  log ERROR "One or more workflow IDs mutated between pulls"
  exit 1
fi

if [[ -z "$ID_INJECTED" ]] || ! [[ "$ID_INJECTED" =~ ^[A-Za-z0-9]{16}$ ]]; then
  log ERROR "Injected workflow received invalid ID: $ID_INJECTED"
  exit 1
fi

if [[ "$ID_INJECTED" == "$ID_BAD" || "$ID_INJECTED" == "$ID_NO" || "$ID_INJECTED" == "$ID_CORRECT" || "$ID_INJECTED" == "$ID_DUPLICATE" ]]; then
  log ERROR "Injected workflow incorrectly reused an existing ID ($ID_INJECTED)"
  exit 1
fi

INVALID_IDS_SECOND=$(printf '%s' "$POST_EXPORT_SECOND" | jq '[ .[].id | select(test("^[A-Za-z0-9]{16}$") | not) ] | length')
if [[ "$INVALID_IDS_SECOND" -ne 0 ]]; then
  log ERROR "Second pull produced invalid workflow IDs"
  exit 1
fi

for workflow_name in "Bad ID Workflow" "No ID Workflow" "Correct ID Workflow" "Duplicate ID Workflow" "Injected Workflow"; do
  count=$(printf '%s' "$POST_EXPORT_SECOND" | jq --arg name "$workflow_name" '[ .[] | select(.name == $name) ] | length')
  if [[ "$count" -ne 1 ]]; then
    log ERROR "Unexpected workflow count for $workflow_name after second pull (count=$count)"
    exit 1
  fi
done

cat <<'JSON' >"$TEMP_HOME/expected-folders-second.json"
[
  {"name":"Bad ID Workflow","path":["Projects","Folder","Subfolder"]},
  {"name":"No ID Workflow","path":[]},
  {"name":"Correct ID Workflow","path":["Project1"]},
  {"name":"Duplicate ID Workflow","path":["Project2"]},
  {"name":"Injected Workflow","path":["Projects","Folder","Subfolder"]}
]
JSON

verify_folder_structure "$TEMP_HOME/expected-folders-second.json"

log SUCCESS "Double pull verification succeeded"
log SUCCESS "Test completed successfully"
