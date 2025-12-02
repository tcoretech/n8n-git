# n8n-git Pull Reference

The `n8n-git pull` operation imports workflows, credentials, and environment variables from Git repositories or local filesystem storage into a running n8n Docker container. It reconstructs n8n's folder hierarchy when enabled and validates imports with post-operation reconciliation.

## Command Synopsis

```bash
n8n-git pull \
  [--container <id|name>] \
  [--workflows <0|1|2>] \
  [--credentials <0|1|2>] \
  [--folder-structure] \
  [--preserve] \
  [--no-overwrite] \
  [--repo <user/repo>] \
  [--token <pat>] \
  [--branch <name>] \
  [--github-path <path>] \
  [--local-path <path>] \
  [--n8n-path <path>] \
  [--dry-run] \
  [--defaults]
```

### Storage Mode Options

- `0` / `disabled` — Skip component (don't import)
- `1` / `local` — Import from local filesystem (default: `~/n8n-backup`)
- `2` / `remote` — Import from Git repository

### Key Flags

- `--container <id|name>` — Docker container ID or name (default: `n8n`)
- `--workflows <mode>` — Workflow import mode
- `--credentials <mode>` — Credential import mode
- `--folder-structure` — Recreate n8n folder hierarchy from Git directory structure
- `--preserve` — Keep original workflow IDs when safe (avoid duplicates)
- `--no-overwrite` — Force new workflow IDs (intentionally create duplicates)
- `--github-path <path>` — Subdirectory within repo to pull from
- `--n8n-path <path>` — Target path within n8n project (e.g., `clients/acme`)
- `--local-path <path>` — Local storage directory (default: `~/n8n-backup`)
- `--dry-run` — Preview operations without making changes
- `--defaults` — Non-interactive mode (skip prompts)

## Pull Flow

### High-Level Pipeline

```
1. Git Clone / Local Scan
   ↓ Clone repo or read local directory
   ↓
2. Staging (lib/pull/staging.sh)
   ↓ generate_workflow_manifest()
   ↓
3. Folder State Caching (lib/pull/folder-state.sh)
   ↓ load_n8n_state() → N8N_PROJECTS, N8N_FOLDERS, N8N_WORKFLOWS
   ↓
4. Pre-Import Snapshot
   ↓ snapshot_existing_workflows()
   ↓
5. Docker Import
   ↓ docker cp + n8n import:workflow
   ↓
6. Folder Sync (lib/pull/folder-sync.sh)
   ↓ create_folder_path() → recursive folder creation
   ↓
7. Folder Assignment (lib/pull/folder-assignment.sh)
   ↓ assign_workflow_to_folder() → PATCH /rest/workflows/{id}
   ↓
8. Validation (lib/pull/validate.sh)
   ↓ reconcile_imported_workflow_ids()
   ↓
9. Success Report
```

### Detailed Steps

#### 1. Git Clone / Local Scan

**Remote Pull** (`workflows=2` or `credentials=2`):

```bash
# Clone with sparse checkout (efficient)
git clone \
  --depth 1 \
  --branch $branch \
  --filter=blob:none \
  --no-checkout \
  --sparse \
  https://${token}@github.com/${repo}.git \
  /tmp/n8n-download-XXXXXX

# Configure sparse checkout
git sparse-checkout set "$github_path"
git checkout
```

**Local Pull** (`workflows=1` or `credentials=1`):

Reads directly from `LOCAL_BACKUP_PATH` (default: `~/n8n-backup`).

**Path Resolution**:

If `--github-path` includes tokens (e.g., `backups/%DATE%/`), they are rendered before clone:

```bash
# Config: GITHUB_PATH="backups/%DATE%/"
# Rendered: backups/2025-11-09/
```

#### 2. Staging — Manifest Generation (`lib/pull/staging.sh`)

**Function**: `generate_workflow_manifest()`

Scans directory structure and creates NDJSON manifest file:

```bash
find $source_dir -type f -name "*.json" -print0 | while IFS= read -r -d '' file; do
  # Extract workflow metadata
  id=$(jq -r '.id // ""' "$file")
  name=$(jq -r '.name // ""' "$file")
  storagePath="${file#$source_dir/}"
  
  # Create manifest entry
  jq -n --arg id "$id" --arg name "$name" --arg path "$storagePath" \
    '{id: $id, name: $name, storagePath: $path}'
done > /tmp/manifest.ndjson
```

**Manifest Format** (NDJSON):

Each line is a JSON object representing one workflow:

```json
{"id":"abc123def4567890","name":"Email Campaign","storagePath":"Personal/Marketing/Email Campaign.json"}
{"id":"xyz789abc0123456","name":"Twitter Bot","storagePath":"Personal/Social Media/Twitter Bot.json"}
{"id":"","name":"New Workflow","storagePath":"Imports/New Workflow.json"}
```

**ID Validation** (`is_valid_workflow_id()`):

- Valid: Exactly 16 alphanumeric characters OR empty
- Empty IDs → n8n assigns new ID during import
- Invalid IDs → stripped (forces new assignment)

**Reconciliation** (`reconcile_manifest_ids()`):

After import, matches imported workflow IDs back to manifest entries:

```json
{
  "id": "abc123def4567890",
  "name": "Email Campaign",
  "storagePath": "Personal/Marketing/Email Campaign.json",
  "actualImportedId": "abc123def4567890",
  "idReconciled": true
}
```

#### 3. Folder State Caching (`lib/pull/folder-state.sh`)

**Function**: `load_n8n_state()`

Fetches current n8n state via REST API and caches in memory:

**API Calls**:

```bash
# 1. Load projects
GET /api/v1/projects
Response: [{"id":"proj-abc-123","name":"Personal","type":"personal"}]

# 2. Load folders
GET /api/v1/workflows/folders
Response: [{"id":"folder-xyz-789","name":"Marketing","projectId":"proj-abc-123","parentId":null}]

# 3. Load existing workflows
GET /api/v1/workflows?limit=1000
Response: {"data":[{"id":"wf-123","name":"Test","folderId":"folder-xyz-789"}]}
```

**Cache Structures** (Bash Associative Arrays):

```bash
# Global state in folder-state.sh
declare -g -A N8N_PROJECTS       
# ["Personal"]="proj-abc-123"
# ["Client Work"]="proj-def-456"

declare -g -A N8N_FOLDERS        
# ["proj-abc-123/Marketing"]="folder-xyz-789"
# ["proj-abc-123/Marketing/Email Campaigns"]="folder-abc-012"

declare -g -A N8N_WORKFLOWS      
# ["wf-123"]="folder-xyz-789|proj-abc-123|version-1"

declare -g N8N_DEFAULT_PROJECT_ID="proj-abc-123"
```

**Cache Key Format**:

```bash
# Folder cache key construction
cache_key = "${project_id}/${folder_path}"

# Examples:
# "proj-abc-123/Marketing"
# "proj-abc-123/Marketing/Email Campaigns"
# "proj-def-456/Development"
```

**Functions**:

| Function | Purpose |
|----------|---------|
| `load_n8n_projects()` | Populate N8N_PROJECTS map from API |
| `load_n8n_folders()` | Populate N8N_FOLDERS map with hierarchy |
| `load_n8n_workflows()` | Populate N8N_WORKFLOWS with current assignments |
| `set_folder_cache_entry()` | Add folder to cache (used during sync) |
| `invalidate_n8n_state_cache()` | Clear all cached state |

#### 4. Pre-Import Snapshot

**Function**: `snapshot_existing_workflows()` (in `staging.sh`)

Captures current workflow list before import for rollback capability:

**Method 1: API** (preferred):

```bash
GET /api/v1/workflows?limit=1000
# Store response in /tmp/n8n-existing-workflows-XXXXXX.json
```

**Method 2: CLI Export** (fallback):

```bash
docker exec $container n8n export:workflow --all --output=/tmp/snapshot.json
docker cp $container:/tmp/snapshot.json /tmp/snapshot-XXXXXX.json
```

**Usage**:

- Rollback if import fails midway
- Duplicate detection (workflow name already exists)
- Reconciliation matching

#### 5. Docker Import

**Function**: `stage_directory_workflows_to_container()` (in `staging.sh`)

Copies workflows into container and imports:

```bash
# 1. Copy workflows to container temp directory
docker cp /tmp/workflows/ $container:/tmp/workflows/

# 2. Import all workflows
docker exec $container n8n import:workflow \
  --input=/tmp/workflows/ \
  --separate

# 3. Cleanup container temp files
docker exec $container rm -rf /tmp/workflows/
```

**ID Handling**:

- `--preserve` mode: Keep original IDs when no conflict exists
- `--no-overwrite` mode: Strip IDs (force new assignment)
- Default: Smart merge (reuse safe IDs, mint new when conflicts arise)

#### 6. Folder Sync (`lib/pull/folder-sync.sh`)

**Function**: `create_folder_path()`

Recursively creates folder hierarchy in n8n to match Git directory structure.

**Example Flow**:

```bash
# Git structure: Personal/Marketing/Email Campaigns/Welcome Email.json
# Target n8n path: Personal → Marketing → Email Campaigns

# Step 1: Resolve project
project_id = N8N_PROJECTS["Personal"]  # → "proj-abc-123"

# Step 2: Check cache for full path
cache_key = "proj-abc-123/Marketing/Email Campaigns"
if N8N_FOLDERS[cache_key] exists:
    return folder_id  # Cache hit

# Step 3: Create folders recursively
create_folder("Marketing", project_id, parent=null)
  → POST /api/v1/workflows/folders
  → {"name":"Marketing","projectId":"proj-abc-123","parentId":null}
  → Response: {"id":"folder-xyz-789"}
  → Cache: N8N_FOLDERS["proj-abc-123/Marketing"]="folder-xyz-789"

create_folder("Email Campaigns", project_id, parent="folder-xyz-789")
  → POST /api/v1/workflows/folders
  → {"name":"Email Campaigns","projectId":"proj-abc-123","parentId":"folder-xyz-789"}
  → Response: {"id":"folder-abc-012"}
  → Cache: N8N_FOLDERS["proj-abc-123/Marketing/Email Campaigns"]="folder-abc-012"
```

**API Call** (folder creation):

```bash
POST /rest/workflows/folders
Content-Type: application/json

{
  "name": "Email Campaigns",
  "projectId": "proj-abc-123",
  "parentId": "folder-xyz-789"
}

Response:
{
  "id": "folder-abc-012",
  "name": "Email Campaigns",
  "projectId": "proj-abc-123",
  "parentId": "folder-xyz-789",
  "createdAt": "2025-11-09T14:30:00.000Z"
}
```

**Functions**:

| Function | Purpose |
|----------|---------|
| `get_workflow_folder_path()` | Extract folder path from Git storage path |
| `get_project_from_path()` | Determine project name from directory structure |
| `create_folder_path()` | Recursively create folder hierarchy with caching |

#### 7. Folder Assignment (`lib/pull/folder-assignment.sh`)

**Function**: `assign_workflow_to_folder()`

Updates workflow-folder mappings via REST API.

**Iteration Through Manifest**:

```bash
while IFS= read -r manifest_entry; do
  workflow_id=$(jq -r '.actualImportedId' <<< "$manifest_entry")
  storage_path=$(jq -r '.storagePath' <<< "$manifest_entry")
  
  # Extract folder path from storage path
  # "Personal/Marketing/Email Campaign.json" → "Marketing"
  folder_path=$(dirname "$storage_path")
  
  # Resolve folder ID from cache
  project_id=$(get_project_from_path "$storage_path")
  folder_id=${N8N_FOLDERS["$project_id/$folder_path"]}
  
  # Update workflow
  assign_workflow_to_folder "$workflow_id" "$folder_id" "$project_id"
done < /tmp/manifest.ndjson
```

**API Call**:

```bash
PATCH /rest/workflows/$workflow_id
Content-Type: application/json

{
  "folderId": "folder-abc-012",
  "projectId": "proj-abc-123"
}

Response:
{
  "id": "abc123def4567890",
  "name": "Email Campaign",
  "folderId": "folder-abc-012",
  "projectId": "proj-abc-123",
  "updatedAt": "2025-11-09T14:35:00.000Z"
}
```

**Error Handling**:

- Missing folder ID → log warning, skip assignment
- Invalid workflow ID → skip (already logged during staging)
- API failure → log error, continue with next workflow

#### 8. Validation (`lib/pull/validate.sh`)

**Function**: `reconcile_imported_workflow_ids()`

Matches imported workflows to manifest entries and reports metrics.

**Reconciliation Strategies**:

1. **ID Match**: Workflow ID from manifest matches post-import ID
2. **Name Match**: Workflow name matches (for new workflows without stable IDs)
3. **Unreconciled**: Workflow not found (import failed or duplicate created)

**Metrics Exported**:

```bash
export RESTORE_WORKFLOWS_CREATED=5    # New workflows imported
export RESTORE_WORKFLOWS_UPDATED=12   # Existing workflows updated
export RESTORE_WORKFLOWS_FAILED=0     # Import failures
export RESTORE_FOLDERS_CREATED=3      # New folders created
export RESTORE_PROJECTS_CREATED=0     # New projects created
```

**Success Report**:

```
✅ Pull complete: 17 workflows imported
   - 5 created
   - 12 updated
   - 3 folders synced
   - 0 failures
```

## Workflow ID Handling Modes

### Default Mode (Smart Merge)

```bash
n8n-git pull --workflows 2
```

**Behavior**:
- Reuse workflow IDs from Git when safe (no name/ID conflicts)
- Mint new IDs when conflicts detected
- Optimal for syncing between environments

### Preserve Mode

```bash
n8n-git pull --workflows 2 --preserve
```

**Behavior**:
- Keep original workflow IDs from Git whenever possible
- Fail if ID collision detected (same ID, different workflow)
- Best for cloning exact replicas

### No-Overwrite Mode

```bash
n8n-git pull --workflows 2 --no-overwrite
```

**Behavior**:
- Always generate new workflow IDs
- Intentionally creates duplicates if workflow name exists
- Safe for importing templates/examples

### Comparison Table

| Mode | ID Strategy | Duplicate Handling | Use Case |
|------|-------------|-------------------|----------|
| **Default** | Smart reuse | Merge | Sync between environments |
| **Preserve** | Keep original | Fail on conflict | Exact replica cloning |
| **No-Overwrite** | Force new | Always duplicate | Import templates |

## Credential Handling

### Local Import (`credentials=1`)

```bash
# Source: ~/n8n-backup/.credentials/credentials.json
# Encrypted by n8n (safe storage)
docker cp ~/n8n-backup/.credentials/ $container:/tmp/credentials/
docker exec $container n8n import:credentials --input=/tmp/credentials/
```

**Permissions**:
- Local directory: `700` (user-only)
- Credential files: `600` (user read/write only)

### Remote Import (`credentials=2`)

```bash
# Source: Git repository (cloned to temp directory)
# Warning: Only import encrypted credentials from Git
docker cp /tmp/repo/.credentials/ $container:/tmp/credentials/
docker exec $container n8n import:credentials --input=/tmp/credentials/
```

**Security Warning**: Never import decrypted credentials from Git (verify `DECRYPT_CREDENTIALS=false` was used during push).

## n8n Path Targeting

**Flag**: `--n8n-path <path>`

Targets specific folder within n8n project for import:

```bash
# Import into "Examples/Gmail" folder
n8n-git pull \
  --repo Zie619/n8n-workflows \
  --github-path workflows/Gmail \
  --n8n-path Examples/Gmail
```

**Behavior**:
- Creates target folder if missing
- Prepends path to all workflow folder assignments
- Useful for organizing imports from different sources

**Example Mapping**:

```
Git structure:           n8n structure (with --n8n-path Examples/Gmail):
workflows/Gmail/         Personal/Examples/Gmail/
├── Send Email.json  →       ├── Send Email.json
└── Filter.json      →       └── Filter.json
```

## Module Functions

### `lib/pull/import.sh`

| Function | Purpose |
|----------|---------|
| `pull_import()` | **Main orchestrator**: coordinates workflow/credential import pipeline |

### `lib/pull/staging.sh`

| Function | Purpose |
|----------|---------|
| `generate_workflow_manifest()` | Scans Git directory structure, creates NDJSON manifest |
| `reconcile_manifest_ids()` | Updates manifest with post-import workflow IDs |
| `is_valid_workflow_id()` | Validates ID format (16 alphanumeric or empty) |
| `snapshot_existing_workflows()` | Captures pre-import state for rollback |
| `stage_directory_workflows_to_container()` | Copies workflows to container and imports |

### `lib/pull/folder-state.sh`

| Function | Purpose |
|----------|---------|
| `load_n8n_state()` | **Main state loader**: populates all cache maps |
| `load_n8n_projects()` | Fetches projects via API, populates N8N_PROJECTS |
| `load_n8n_folders()` | Fetches folders via API, populates N8N_FOLDERS |
| `load_n8n_workflows()` | Fetches workflows via API, populates N8N_WORKFLOWS |
| `set_folder_cache_entry()` | Adds folder to cache (used during sync) |
| `invalidate_n8n_state_cache()` | Clears all cached state |

### `lib/pull/folder-sync.sh`

| Function | Purpose |
|----------|---------|
| `get_workflow_folder_path()` | Extracts folder path from Git storage path |
| `get_project_from_path()` | Determines project name from directory structure |
| `create_folder_path()` | **Core sync logic**: recursively creates folder hierarchy with API calls and caching |

### `lib/pull/folder-assignment.sh`

| Function | Purpose |
|----------|---------|
| `assign_workflow_to_folder()` | Updates workflow folderId/projectId via PATCH /rest/workflows/{id} |

### `lib/pull/validate.sh`

| Function | Purpose |
|----------|---------|
| `reconcile_imported_workflow_ids()` | Matches imported IDs to manifest, exports metrics |

### `lib/pull/utils.sh`

| Function | Purpose |
|----------|---------|
| `capture_existing_workflow_snapshot()` | Wrapper for snapshot_existing_workflows() |
| `find_workflow_directory()` | Locates workflow storage directory in cloned repo |
| `locate_workflow_artifacts()` | Finds workflow JSON files in directory |
| `locate_credentials_artifact()` | Finds credential files (directory or JSON) |
| `bundle_credentials_directory()` | Packs credentials into archive for import |

## Configuration Options

### Required for Remote Pull

```bash
GITHUB_TOKEN="ghp_..."          # Personal Access Token (repo scope)
GITHUB_REPO="user/repo-name"    # Source repository
GITHUB_BRANCH="main"            # Branch to pull from
```

### Optional Settings

```bash
GITHUB_PATH="backups/%DATE%/"   # Subdirectory with token support
LOCAL_BACKUP_PATH="~/n8n-backup"  # Local storage location
FOLDER_STRUCTURE=true           # Enable folder hierarchy recreation
N8N_CONTAINER="n8n"             # Docker container name
N8N_PROJECT="Personal"          # Target project name
N8N_PATH="Examples/Gmail"       # Target path within project
```

## Error Handling & Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| `0` | Success (all operations completed) |
| `1` | Execution failure (Docker, Git, or API error) |
| `2` | Validation failure (no workflows found, invalid manifest) |

### Common Failure Modes

**Git Clone Failures**:
```bash
# Authentication failed
fatal: Authentication failed for 'https://github.com/user/repo.git'
→ Solution: Verify GITHUB_TOKEN is valid and has repo access
```

**API Folder Creation Failures**:
```bash
# Project doesn't exist
ERROR: Failed to create folder: project not found
→ Solution: Verify N8N_PROJECT matches existing project in n8n
```

**Import Failures**:
```bash
# Invalid workflow JSON
ERROR: Failed to import workflow: invalid JSON
→ Solution: Validate JSON files with `jq empty <file.json>`
```

## Dry-Run Mode

Preview operations without side effects:

```bash
n8n-git pull --dry-run --verbose
```

**Logged Operations** (not executed):
- Would clone repository: `https://github.com/user/repo.git`
- Would generate manifest with 17 workflows
- Would create folder: `Marketing`
- Would import workflow: `Email Campaign.json`
- Would assign workflow to folder: `folder-abc-012`

## Automation Examples

### Scheduled Environment Sync

```bash
# /etc/cron.d/n8n-sync
0 3 * * * user /usr/local/bin/n8n-git pull \
  --container n8n-dev \
  --workflows 2 \
  --credentials 1 \
  --folder-structure \
  --preserve \
  --defaults
```

### CI/CD Deployment

```yaml
# .github/workflows/n8n-deploy.yml
name: Deploy to n8n
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Pull workflows into n8n
        run: |
          n8n-git pull \
            --container n8n-prod \
            --workflows 2 \
            --folder-structure \
            --preserve \
            --defaults
        env:
          GITHUB_TOKEN: ${{ secrets.N8N_DEPLOY_TOKEN }}
          GITHUB_REPO: company/n8n-workflows
```

## Rollback & Recovery

### Automatic Rollback

If pull fails after import, automatic rollback restores pre-import state:

```bash
# Pull fails during folder assignment
ERROR: Failed to assign workflow to folder
INFO: Restoring pre-import snapshot...
SUCCESS: Rollback complete
```

### Manual Rollback

Use reset to revert to previous Git commit:

```bash
# Find last good commit
git log --oneline

# Reset to before failed pull
n8n-git reset --to abc123f --mode soft
```

## Related Documentation

- **Push Operations**: [docs/push.md](push.md) — Export workflows to Git
- **Reset Feature**: [docs/reset.md](reset.md) — Time-travel through Git history
- **Architecture**: [docs/ARCHITECTURE.md](ARCHITECTURE.md) — System design overview
- **User Guide**: [README.md](../README.md) — Full feature documentation
