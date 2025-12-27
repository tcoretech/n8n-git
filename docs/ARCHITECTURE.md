# n8n-git — Architecture Documentation

> **Quick Reference**: This document provides system design overview, module boundaries, and development patterns for AI development tools and contributors. For detailed feature documentation, see operation-specific guides: [push.md](push.md), [pull.md](pull.md), [reset.md](reset.md).

## Project Purpose

n8n-git is a Bash-based CLI tool that provides bidirectional synchronization between n8n workflow instances (running in Docker) and Git repositories. It preserves n8n's project and folder hierarchy in the Git directory structure and reconstructs it during pull operations.

**Core Capabilities**:

- **Push**: Export workflows/credentials/environment from n8n → Git/local storage
- **Pull**: Import workflows/credentials/environment from Git/local storage → n8n
- **Reset**: Time-travel through Git history to restore/archive/delete workflows

## Architecture Overview

### Core Modules

```text
n8n-git.sh          ← Entry point: CLI parsing, config resolution, command dispatch
│
├── lib/utils/
│   ├── common.sh          ← Shared utilities: logging, config, Docker helpers, path rendering
│   └── interactive.sh     ← Interactive menus, configuration wizard, help text
│
├── lib/n8n/
│   ├── auth.sh            ← REST API authentication (session/API key)
│   ├── endpoints.sh       ← API endpoint wrappers (projects, folders, workflows)
│   ├── snapshot.sh        ← Workspace state capture and caching
│   ├── utils.sh           ← API utilities and JSON sanitization
│   └── decrypt.sh         ← Credential decryption helpers
│
├── lib/push/
│   ├── export.sh          ← Push orchestration: workflow/credential/environment export
│   ├── container_io.sh    ← Docker container operations: exec, cp, file handling
│   └── folder_mapping.sh  ← Workflow organization: folder structure, flat fallback
│
├── lib/pull/
│   ├── import.sh          ← Pull orchestration: workflow/credential import pipeline
│   ├── staging.sh         ← Manifest generation, ID validation, pre-import snapshot
│   ├── folder-state.sh    ← n8n state caching: projects, folders, workflows
│   ├── folder-sync.sh     ← Folder creation: recursive hierarchy build with API calls
│   ├── folder-assignment.sh ← Workflow-folder mapping: PATCH API assignments
│   ├── validate.sh        ← Post-import reconciliation, metrics reporting
│   └── utils.sh           ← Pull helpers: snapshot, artifact location, bundling
│
├── lib/github/
│   ├── git.sh             ← Git operations: init, clone, sparse checkout, commits
│   └── git_ops.sh         ← Commit message generation, per-workflow commits
│
└── lib/reset/
    ├── reset.sh           ← Reset orchestration: target resolution, execution
    ├── plan.sh            ← Diff calculation: archive/delete/restore/unchanged
    ├── apply.sh           ← Workflow state changes: archive, delete, restore via API
    ├── resolve.sh         ← Target resolution: explicit, interactive, time window
    ├── time_window.sh     ← Time-based commit lookup with natural language support
    └── common.sh          ← Reset utilities: logging, validation, safety checks
```

### Execution Abstraction

The core `n8n_exec()` function provides transparent execution of n8n CLI commands regardless of environment:

- **Container specified**: Uses `docker exec` to run commands in container
- **No container specified**: Attempts direct execution of n8n CLI on host
- **Neither available**: Interactive container selection (if TTY)

This is not a "mode" - it's intelligent execution path selection based on available resources and user input.

File operations follow the same pattern via `copy_from_n8n()` and `copy_to_n8n()` helper functions, which abstract away the difference between `docker cp` and local `cp`.

### Configuration Precedence

Settings are resolved in this order (highest to lowest priority):

1. **Command-line arguments** (`--workflows 2`, `--token "..."`)
2. **Local config** (`./.config` in project directory)
3. **User config** (`~/.config/n8n-git/config`)
4. **Interactive prompts** (when in interactive mode)
5. **Built-in defaults** (hardcoded fallbacks)

### Storage Modes

All storage components (workflows, credentials, environment) support three modes for push and pull:

- `0` / `disabled` — Skip this component
- `1` / `local` — Store in `~/n8n-backup` (or custom path via `LOCAL_BACKUP_PATH`)
- `2` / `remote` — Store in Git repository

**Legacy Note**: The default local directory is `~/n8n-backup` (named for historical reasons). Documentation now refers to this as the "local storage directory" or "local push/pull directory."

## Operation Flows

Detailed flow documentation is organized by operation:

- **[Push Flow](push.md)** — Export from n8n to Git/local storage
- **[Pull Flow](pull.md)** — Import from Git/local storage to n8n
- **[Reset Flow](reset.md)** — Replay Git history into n8n workspace

### Quick Reference

| Operation | Entry Function | Key Modules | Primary APIs |
| ----------- | --------------- | ------------- | -------------- |
| **Push** | `push_export()` | `lib/push/*`, `lib/github/git.sh` | `GET /api/v1/workflows`, `n8n export:workflow` |
| **Pull** | `pull_import()` | `lib/pull/*`, `lib/n8n/*` | `GET /api/v1/projects`, `POST /api/v1/workflows/folders`, `PATCH /rest/workflows/{id}` |
| **Reset** | `main_reset()` | `lib/reset/*`, reuses pull pipeline | `POST /rest/workflows/{id}/archive`, `DELETE /rest/workflows/{id}` |

## Authentication

### Session-Based Authentication (Current Method)

n8n's folder management API is not yet available via API keys, so session-based authentication is required for folder structure operations.

**Setup**:

1. Create **Basic Auth credential** in n8n UI
2. Set credential name in config: `N8N_LOGIN_CREDENTIAL_NAME="N8N REST BACKUP"`
3. n8n-git performs login and manages session cookie

**Flow** (`prepare_n8n_api_auth()` in `lib/n8n/auth.sh`):

```bash
# 1. Retrieve credential from n8n's credential store
docker exec $container n8n export:credentials \
  --id="<credential-id>" \
  --output=/tmp/auth-cred.json

# 2. Extract email/password from credential
email=$(jq -r '.data.user' /tmp/auth-cred.json)
password=$(jq -r '.data.password' /tmp/auth-cred.json)

# 3. Perform login to get session cookie
curl -c /tmp/n8n-cookie.txt \
  -d '{"email":"<email>","password":"<password>"}' \
  $N8N_BASE_URL/rest/login

# 4. Reuse cookie for subsequent API calls
curl -b /tmp/n8n-cookie.txt \
  $N8N_BASE_URL/api/v1/workflows
```

**Cleanup**: `finalize_n8n_api_auth()` deletes cookie file after operations.

### API Key Authentication (Placeholder)

**Config**: `N8N_API_KEY="n8n_api_..."`

**Status**: Currently a placeholder awaiting n8n API support for folder operations. API keys work for workflow listing but not folder management.

**Usage**:

```bash
curl -H "X-N8N-API-KEY: $N8N_API_KEY" \
  $N8N_BASE_URL/api/v1/workflows
```

## Path Token System

**Function**: `render_github_path_with_tokens()` (in `lib/utils/common.sh`)

Supports dynamic path generation with token substitution in `GITHUB_PATH` config:

### Available Tokens

| Token Category | Tokens | Example Output |
| --------------- | --------- | ---------------- |
| **Date/Time** | `%DATE%` | `2025-11-09` |
| | `%DATETIME%`, `%TIME%` | `2025-11-09_14-30-45` |
| | `%YYYY%`, `%YY%` | `2025`, `25` |
| | `%MM%`, `%DD%` | `11`, `09` |
| | `%HH%`, `%mm%`, `%ss%` | `14`, `30`, `45` |
| **Project** | `%PROJECT%` | `MyProject` or `%PERSONAL_PROJECT%` |
| **Personal** | `%PERSONAL_PROJECT%` | `User Name <user@example.com>` |
| **Host** | `%HOSTNAME%` | `backup-node-01` |

### Rendering Example

```bash
# Config
GITHUB_PATH="backups/%YYYY%/%MM%/%PROJECT%/"

# Session values (set at runtime)
SESSION_YEAR="2025"
SESSION_MONTH="11"
project_name_effective="Personal"

# Rendered result
backups/2025/11/Personal/
```

**Implementation**:

1. Time tokens rendered from `SESSION_*` globals (set once per execution)
2. Project/personal tokens remain literal until a project name is resolved; once resolved, project tokens are sanitized together
3. Host tokens from sanitized `SESSION_HOSTNAME`
4. Path sanitization removes invalid filesystem characters
5. Slash normalization removes duplicates, leading/trailing slashes

## Data Structures

### Manifest Format (NDJSON)

Pull operations use NDJSON (newline-delimited JSON) for efficient line-by-line processing:

```json
{"id":"abc123def4567890","name":"Email Campaign","storagePath":"Personal/Marketing/Email Campaign.json"}
{"id":"xyz789abc0123456","name":"Twitter Bot","storagePath":"Personal/Social Media/Twitter Bot.json"}
{"id":"","name":"New Workflow","storagePath":"Imports/New Workflow.json"}
```

**Fields**:

- `id` — Original workflow ID (16 alphanumeric or empty)
- `name` — Workflow name
- `storagePath` — Relative path in Git repository
- `actualImportedId` — ID assigned after import (added during reconciliation)
- `idReconciled` — Boolean success flag (added during reconciliation)

### Folder State Cache (Bash Associative Arrays)

**Global State** (in `lib/pull/folder-state.sh`):

```bash
declare -g -A N8N_PROJECTS       # ["Personal"]="proj-abc-123"
declare -g -A N8N_FOLDERS        # ["proj-abc-123/Marketing"]="folder-xyz-789"
declare -g -A N8N_FOLDER_PARENTS # ["folder-xyz-789"]="parent-folder-id"
declare -g -A N8N_WORKFLOWS      # ["workflow-id"]="folder-id|project-id|version-id"
declare -g N8N_DEFAULT_PROJECT_ID="proj-abc-123"
```

**Cache Key Format**:

```bash
# Folder lookup
cache_key="${project_id}/${folder_path}"
# Example: "proj-abc-123/Marketing/Email Campaigns"

# Workflow lookup
workflow_state="${N8N_WORKFLOWS[$workflow_id]}"
# Format: "folder-id|project-id|version-id"
```

**Lifecycle**:

1. `load_n8n_state()` — Populate cache from API (3 calls: projects, folders, workflows)
2. `set_folder_cache_entry()` — Add newly created folder to cache
3. `invalidate_n8n_state_cache()` — Clear cache (called at start of pull/reset)

### API Response Processing

n8n API responses are processed with `jq` into TSV streams for efficient bash parsing:

```bash
# Example: Load projects
jq -r '.[] | [.id, .name, .type] | @tsv' <<< "$api_response" |
while IFS=$'\t' read -r id name type; do
  N8N_PROJECTS["$name"]="$id"
  [[ "$type" == "personal" ]] && N8N_DEFAULT_PROJECT_ID="$id"
done
```

**Pattern**:

1. `jq` converts JSON to TSV (tab-separated values)
2. `while IFS=$'\t' read` parses TSV line-by-line
3. Populate associative arrays for O(1) lookups

## Safety Features

### Pre-Pull Snapshot

**Function**: `snapshot_existing_workflows()` (in `lib/pull/staging.sh`)

Before any pull, captures current workflow list for rollback capability:

**Methods**:

1. **API** (preferred): `GET /api/v1/workflows?limit=1000`
2. **CLI Export** (fallback): `n8n export:workflow --all`

**Storage**: `/tmp/n8n-existing-workflows-XXXXXXXX.json`

**Usage**:

- Rollback if pull fails midway
- Duplicate detection (workflow name exists)
- Reconciliation matching

### Automatic Rollback

If a pull fails after import, restore pre-import state:

```bash
# Detect failure in lib/pull/import.sh
if ! pull_workflow_import_succeeded; then
  log ERROR "Pull failed, restoring snapshot..."
  docker cp /tmp/snapshot.json $container:/tmp/rollback.json
  docker exec $container n8n import:workflow --input=/tmp/rollback.json
  log SUCCESS "Rollback complete"
fi
```

### Dry Run Mode

`--dry-run` or `DRY_RUN=true`:

- Logs all planned operations with `log DRYRUN` prefix
- Skips: `docker cp`, `docker exec`, `git push`, API mutations (`POST`, `PATCH`, `DELETE`)
- Executes: directory scanning, manifest generation, Git clones (read-only)

**Check in Code**:

```bash
if [[ "$is_dry_run" == "true" ]]; then
  log DRYRUN "Would execute: docker exec $container n8n import:workflow"
  return 0
fi
# Actual execution below
```

### ID Conflict Resolution

Workflow IDs must be exactly 16 alphanumeric characters. During staging:

1. **Validate format**: `is_valid_workflow_id()`
2. **Check for conflicts**: Same ID, different name → reject
3. **Check for duplicates**: Same name in target folder → reuse existing ID
4. **Sanitize or remove**: Invalid IDs removed (n8n assigns new)

**Controlled by flags**:

- `--preserve` — Keep original IDs when safe
- `--no-overwrite` — Always generate new IDs

## Performance Characteristics

### Memory Usage

- **Moderate**: Folder state cache holds ~1000s of entries in associative arrays
- **Manifest files**: NDJSON format enables line-by-line processing (low memory footprint)
- **Git operations**: Sparse checkout reduces disk/network usage

### API Call Optimization

| Operation | Base Calls | Additional Calls |
| ----------- | ------------ | ------------------ |
| **Push** | 1 (workflows list) | +1 per project, +1 per folder (for mapping) |
| **Pull** | 3 (projects, folders, workflows) | +1 per missing folder, +1 per workflow assignment |
| **Reset** | Same as pull | +1 per archive, +1 per delete (hard mode) |

**Caching Strategy**:

- Load state once, reuse for all operations
- Cache hit = no API call
- Cache miss = create folder + update cache

### File Operations

- **Workflow exports**: 1 file per workflow (not monolithic JSON)
- **Git commits**: Per-workflow or bulk (configurable)
- **Temp files**: All use `mktemp`, cleaned up with traps

## Error Handling

### Strict Mode

All scripts use:

```bash
set -Eeuo pipefail
```

- `-e` — Exit on error
- `-E` — Inherit error trap in functions
- `-u` — Error on undefined variables
- `-o pipefail` — Catch errors in pipes

### Logging Levels

**Function**: `log LEVEL "message"` (in `lib/utils/common.sh`)

```bash
log HEADER "Starting Push Operation"
log INFO "Cloning repository..."
log WARN "API key not found, using session auth"
log ERROR "Failed to create folder"
log SUCCESS "Push complete"
log DEBUG "Cache hit: folder-abc-123"  # Only if --verbose
log DRYRUN "Would execute: git push"   # Only if --dry-run
log SECURITY "Credentials will be encrypted"  # Security warnings
```

### Docker Compatibility

**Alpine containers**: Uses `/bin/ash`, handles busybox limitations  
**Debian/Ubuntu**: Uses `/bin/bash`, full GNU utilities

**Detected automatically** via `n8n_exec()` wrapper in `lib/utils/common.sh`:

```bash
n8n_exec() {
  local container="$1"
  local command="$2"
  local is_dry_run="${3:-false}"
  
  if [[ "$is_dry_run" == "true" ]]; then
    log DRYRUN "Would execute in container: $command"
    return 0
  fi
  
  docker exec "$container" sh -c "$command"
}
```

## Testing

### Test Scripts (`tests/`)

- **test-syntax.sh** — Bash syntax validation (all scripts)
- **test-shellcheck.sh** — ShellCheck linting (all scripts)
- **test-push.sh** — Push regression suite (Docker-based)
- **test-pull.sh** — Pull idempotency, ID sanitization, folder reassignment
- **test-reset.sh** — Reset flow validation, mode testing

### Makefile Shortcuts

```bash
make lint    # Runs syntax + ShellCheck
make test    # Full regression suite
make package # Stages release files in dist/
```

### CI/CD

`.github/workflows/ci.yml` runs 5-job pipeline:

1. Syntax validation
2. ShellCheck linting
3. Push test
4. Pull test
5. Reset test

**Requirement**: All tests must pass before merge/release.

## Development Guidelines

### Adding New Features

1. **Identify affected modules**: Push, pull, reset, or shared utilities?
2. **Update configuration**: Add new settings to `.config.example`
3. **Preserve backward compatibility**: Support old config formats
4. **Add logging**: Use `log DEBUG` for detailed output, `log INFO` for user-facing
5. **Handle dry-run**: Skip destructive operations when `is_dry_run=true`
6. **Update tests**: Add test cases in `tests/test-*.sh`
7. **Document**: Update README.md and operation-specific docs (push.md, pull.md, reset.md)

### Code Conventions

**Quoting**:

```bash
# Always quote variables
local value="$var"
command --arg "$var"

# Array expansion
command "${array[@]}"
```

**Functions**:

```bash
my_function() {
  local param1="$1"
  local param2="${2:-default}"  # Optional with default
  
  # Function logic
  
  return 0  # Success
}
```

**Return Values**:

- `return 0` — Success
- `return 1` — General failure
- `return 2` — Validation failure / special condition
- `return 130` — User abort (interactive picker)

**Arrays**:

```bash
declare -a indexed_array=()     # Indexed array
declare -A assoc_array=()       # Associative array
declare -g -A global_map=()     # Global associative array
```

**Subprocess Errors**:

```bash
if ! command; then
  log ERROR "Command failed"
  return 1
fi

# OR
if command; then
  log SUCCESS "Command succeeded"
else
  log ERROR "Command failed"
  return 1
fi
```

### Module Boundaries

**Dependency Rules**:

- **lib/utils/common.sh** — No dependencies on other modules (foundation)
- **lib/push/export.sh** — May import: `utils/common.sh`, `github/git.sh`, `n8n/n8n-api.sh`, `push/*`
- **lib/pull/import.sh** — May import: `utils/common.sh`, `n8n/n8n-api.sh`, `github/git.sh`, `pull/*`
- **lib/pull/*** modules — May import: `utils/common.sh`, `n8n/n8n-api.sh`, but NOT parent `import.sh`
- **lib/n8n/n8n-api.sh** — Self-contained, handles own auth state
- **lib/reset/reset.sh** — Reuses pull pipeline modules

**Shared State**:

- Config variables exported in `n8n-git.sh`
- Folder cache populated in `folder-state.sh`, read by other pull modules
- Session auth managed in `n8n-api.sh`, accessed globally

## Troubleshooting Tips for AI Tools

### When Debugging Pull Issues

1. **Check manifest**: `cat /tmp/workflow-manifest-*.ndjson`
2. **Check folder cache**: Enable `--verbose`, grep for "Cache hit" / "Cache miss"
3. **Check API responses**: Look for "API request failed" in logs
4. **Check ID conflicts**: Search logs for "ID conflict" or "sanitizing"

### When Extending Functionality

1. Read `lib/utils/common.sh` first (logging, config loading, Docker helpers)
2. Understand configuration precedence (CLI > local > user > default)
3. Test with `--dry-run --verbose` to see full execution flow
4. Use `grep "function " lib/**/*.sh` to find entry points

### Common Patterns

**Loading Config Value with Fallback**:

```bash
local value="${config_var:-default_value}"
```

**Checking Dry-Run**:

```bash
if [[ "$is_dry_run" == "true" ]]; then
  log DRYRUN "Would execute: $command"
  return 0
fi
```

**Safe Docker Execution**:

```bash
if ! dockExec "$container_id" "command" "$is_dry_run"; then
  log ERROR "Command failed"
  return 1
fi
```

**Iterating Manifest**:

```bash
while IFS= read -r entry_line; do
  local id=$(jq -r '.id // ""' <<< "$entry_line")
  local name=$(jq -r '.name // ""' <<< "$entry_line")
  # Process entry...
done < "$manifest_path"
```

## Related Documentation

- **[Push Operations](push.md)** — Detailed push flow, functions, examples
- **[Pull Operations](pull.md)** — Detailed pull flow, folder sync, validation
- **[Reset Operations](reset.md)** — Time travel, interactive picker, modes
- **[User Guide](../README.md)** — Installation, configuration, features
- **[Configuration Reference](../.config.example)** — All settings explained
- **[Changelog](../CHANGELOG.md)** — Version history
