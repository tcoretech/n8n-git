# n8n-git Push Reference

The `n8n-git push` operation exports workflows, credentials, and environment variables from a running n8n Docker container and stores them in Git repositories or local filesystem storage. It preserves n8n's folder hierarchy when enabled and creates individual Git commits per workflow for granular version control.

## Command Synopsis

```bash
n8n-git push \
  [--container <id|name>] \
  [--workflows <0|1|2>] \
  [--credentials <0|1|2>] \
  [--environment <0|1|2>] \
  [--folder-structure] \
  [--decrypt <true|false>] \
  [--repo <user/repo>] \
  [--token <pat>] \
  [--branch <name>] \
  [--github-path <path>] \
  [--local-path <path>] \
  [--dry-run] \
  [--defaults]
```

### Storage Mode Options

- `0` / `disabled` — Skip component (don't export)
- `1` / `local` — Store in local filesystem (default: `~/n8n-backup`)
- `2` / `remote` — Store in Git repository

### Key Flags

- `--container <id|name>` — Docker container ID or name (default: `n8n`)
- `--workflows <mode>` — Workflow storage mode
- `--credentials <mode>` — Credential storage mode  
- `--environment <mode>` — Environment variable storage mode
- `--folder-structure` — Preserve n8n project/folder hierarchy in Git
- `--decrypt <true|false>` — Export credentials decrypted (default: `false` - keeps encrypted)
- `--github-path <path>` — Subdirectory within repo (supports tokens: `%DATE%`, `%PROJECT%`, etc.)
- `--local-path <path>` — Local storage directory (default: `~/n8n-backup`)
- `--dry-run` — Preview operations without making changes
- `--defaults` — Non-interactive mode (skip prompts)

## Push Flow

### High-Level Pipeline

```
1. Container Export
   ↓ n8n export:workflow commands
   ↓
2. Temporary Host Storage
   ↓ docker cp
   ↓
3. n8n API Folder Mapping
   ↓ GET /api/v1/workflows (with folder metadata)
   ↓
4. Folder Structure Organization
   ↓ push_organize_workflows_by_folders()
   ↓
5. JSON Prettification
   ↓ 2-space indent, sorted keys
   ↓
6. Git Operations
   ↓ Per-workflow commits or bulk commits
   ↓
7. Git Push to Remote
   (if workflows=2)
```

### Detailed Steps

#### 1. Container Export (`lib/push/container_io.sh`)

**Function**: `push_collect_workflow_exports()`

Exports workflow files from the n8n Docker container using `n8n export:workflow` commands:

```bash
# Individual workflow exports
docker exec $container_id n8n export:workflow \
  --id="<workflow-id>" \
  --output="/tmp/workflow_exports/<workflow-id>.json" \
  --separate
```

Creates temporary directory structure:
```
/tmp/workflow_exports/
├── abc123def456.json
├── xyz789abc012.json
└── ...
```

**Error Handling**:
- Validates export directory exists in container
- Falls back to directory copy if individual exports fail
- Cleans up temp exports after processing

#### 2. Folder Mapping Retrieval (`lib/n8n/n8n-api.sh`)

**Function**: `get_workflow_folder_mapping()`

Fetches folder organization from n8n REST API:

```bash
# API call structure
GET /api/v1/workflows?limit=1000&includeScopes=workflow:list
Authorization: Bearer <n8n-api-key>
# OR via session cookie from Basic Auth credential
```

**Response Structure**:
```json
{
  "selectedProject": {
    "id": "proj-abc-123",
    "name": "Personal"
  },
  "workflowsById": {
    "<workflow-id>": {
      "id": "<workflow-id>",
      "name": "My Workflow",
      "projectId": "proj-abc-123",
      "folderId": "folder-xyz-789",
      "folderPath": ["Marketing", "Email Campaigns"],
      "relativePath": "Marketing/Email Campaigns/My Workflow.json"
    }
  }
}
```

**Fallback Behavior**:
- If API unavailable → flat structure (`push_copy_workflows_flat_with_names()`)
- If folder API fails → workflows stored by ID without hierarchy
- Returns exit code `2` to signal fallback used

#### 3. Folder Structure Organization (`lib/push/folder_mapping.sh`)

**Function**: `push_organize_workflows_by_folders()`

Maps workflow files to directory structure based on API response:

```bash
# Example mapping
API folderPath: ["Marketing", "Email Campaigns"]
Git structure:   Personal/Marketing/Email Campaigns/My Workflow.json
```

**Path Construction**:
1. Extract project name from mapping
2. Build folder hierarchy from `folderPath` array
3. Sanitize workflow name for filename
4. Ensure unique filenames with collision detection

**Directory Structure Output**:
```
target_dir/
├── Personal/
│   ├── Marketing/
│   │   ├── Email Campaigns/
│   │   │   ├── Welcome Email.json
│   │   │   └── Newsletter.json
│   │   └── Social Media/
│   │       └── Twitter Bot.json
│   └── Development/
│       └── API Integration.json
└── .credentials/
    └── credentials.json
```

**Collision Handling**:
- Duplicate filenames get suffix: `Workflow.json`, `Workflow (2).json`
- Registry tracking prevents overwrites

#### 4. JSON Prettification

**Function**: `push_prettify_json_file()` (in `lib/utils/common.sh`)

Formats exported JSON for readable diffs:

```bash
jq --indent 2 --sort-keys . "$file" > "$temp_file"
mv "$temp_file" "$file"
```

**Benefits**:
- Consistent formatting across exports
- Meaningful Git diffs (line-by-line changes)
- Sorted keys for deterministic output

#### 5. Git Operations (`lib/github/git.sh`, `lib/github/git_ops.sh`)

**Per-Workflow Commits**:

Function: `commit_individual_workflow()`

Creates individual commit for each workflow:

```bash
git add "Personal/Marketing/Welcome Email.json"
git commit -m "[new] Welcome Email"
# OR
git commit -m "[updated] Welcome Email"
```

**Commit Message Generation**:

Function: `push_generate_workflow_commit_message()` (in `git_ops.sh`)

- Detects new vs updated workflows via `git diff --cached`
- Prefix: `[new]`, `[updated]`, or `[deleted]`
- Preserves workflow name in commit message

**Bulk Commits** (alternative):
```bash
git add .
git commit -m "Push workflows from n8n (X workflows updated)"
```

#### 6. Credential Handling

**Local Storage** (`credentials=1`):

```bash
# Stored at ~/n8n-backup/.credentials/
credentials.json  # Encrypted by n8n (safe)
```

**Permissions**:
- Directory: `700` (user-only)
- Files: `600` (user read/write only)

**Git Storage** (`credentials=2`):

- **Encrypted** (default): Safe for Git
- **Decrypted** (`--decrypt true`): ⚠️ **HIGH RISK** — plaintext secrets in Git

Security validation:
```bash
if [[ $credentials == 2 && $decrypt == true ]]; then
  log WARN "⚠️  Storing decrypted credentials in Git repository (high risk)"
fi
```

#### 7. Environment Variable Export

**Function**: `push_export_sync_environment_to_git()`

Exports environment variables when `environment=2`:

```bash
docker exec $container_id env > /tmp/environment.txt
# Filtered and formatted
docker cp $container_id:/tmp/.env $local_path/.env
```

**Warning**: Environment variables may contain secrets — use `environment=1` (local) unless explicitly required.

## Path Token Expansion

**Function**: `render_github_path_with_tokens()` (in `lib/utils/common.sh`)

Supports dynamic path generation with token substitution:

### Available Tokens

| Token | Description | Example |
|-------|-------------|---------|
| `%DATE%` | Session date (YYYY-MM-DD) | `2025-11-09` |
| `%DATETIME%` / `%TIME%` | Full timestamp | `2025-11-09_14-30-45` |
| `%YYYY%` | Four-digit year | `2025` |
| `%YY%` | Two-digit year | `25` |
| `%MM%` | Month (01-12) | `11` |
| `%DD%` | Day (01-31) | `09` |
| `%HH%` | Hour (00-23) | `14` |
| `%mm%` | Minute (00-59) | `30` |
| `%ss%` | Second (00-59) | `45` |
| `%PROJECT%` | Project name or `%PERSONAL_PROJECT%` | `MyProject` |

### Example Paths

```bash
# Config setting
GITHUB_PATH="backups/%DATE%/%PROJECT%/"

# Rendered result
backups/2025-11-09/Personal/
```

```bash
# Timestamped backup with project
GITHUB_PATH="archive/%YYYY%/%MM%/%PROJECT%/"

# Rendered result
archive/2025/11/Personal/
```

## Module Functions

### `lib/push/export.sh`

| Function | Purpose |
|----------|---------|
| `push_export()` | **Main orchestrator**: coordinates workflow/credential/environment export |
| `push_export_sync_workflows_to_git()` | Exports workflows to Git with folder structure or flat fallback |
| `push_export_sync_credentials_to_git()` | Exports credentials to Git repository |
| `push_export_sync_environment_to_git()` | Exports environment variables to Git repository |
| `push_create_folder_structure()` | **Core folder flow**: collects exports, fetches mapping, organizes by folders |
| `push_render_credentials_directory()` | Unpacks credential bundle into directory structure |

### `lib/push/container_io.sh`

| Function | Purpose |
|----------|---------|
| `push_collect_workflow_exports()` | Executes `n8n export:workflow` commands in container and copies files to host |

### `lib/push/folder_mapping.sh`

| Function | Purpose |
|----------|---------|
| `push_apply_mapping_metadata()` | Extracts project metadata from API response and updates global config |
| `push_print_folder_structure_preview()` | Displays tree preview of organized workflows (logging) |
| `push_copy_workflows_flat_with_names()` | Fallback: copies workflows with sanitized names (no folder structure) |
| `push_organize_workflows_by_folders()` | **Main organization logic**: maps workflows to folders and commits individually |

### `lib/github/git_ops.sh`

| Function | Purpose |
|----------|---------|
| `push_generate_workflow_commit_message()` | Generates `[new]`/`[updated]`/`[deleted]` commit messages based on Git diff |
| `commit_individual_workflow()` | Creates single commit for one workflow file |

## Configuration Options

### Required for Remote Push

```bash
GITHUB_TOKEN="ghp_..."          # Personal Access Token (repo scope)
GITHUB_REPO="user/repo-name"    # Target repository
GITHUB_BRANCH="main"            # Branch to push to
```

### Optional Settings

```bash
GITHUB_PATH="%PROJECT%/"        # Subdirectory with token support
LOCAL_BACKUP_PATH="~/n8n-backup"  # Local storage location
FOLDER_STRUCTURE=true           # Enable folder hierarchy
DECRYPT_CREDENTIALS=false       # Keep credentials encrypted (recommended)
N8N_CONTAINER="n8n"             # Docker container name
```

## Security Best Practices

### ✅ Safe Configuration

```bash
WORKFLOWS=2              # Workflows to Git
CREDENTIALS=1            # Credentials local only
DECRYPT_CREDENTIALS=false  # Encrypted credentials
ENVIRONMENT=1            # Environment variables local only
```

### ⚠️ High-Risk Configuration

```bash
CREDENTIALS=2            # Credentials to Git
DECRYPT_CREDENTIALS=true  # ❌ PLAINTEXT SECRETS IN GIT
ENVIRONMENT=2            # ❌ Secrets exposed in environment vars
```

**Rule**: Never set `CREDENTIALS=2` AND `DECRYPT_CREDENTIALS=true` simultaneously.

## Error Handling & Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| `0` | Success (all operations completed) |
| `1` | Execution failure (Docker, Git, or API error) |
| `2` | Folder structure fallback used (API unavailable) |

### Common Failure Modes

**Docker Container Issues**:
```bash
# Container not found
docker: Error response from daemon: No such container: n8n
→ Solution: Verify container name with `docker ps`
```

**API Authentication Failures**:
```bash
# Session auth failed
ERROR: n8n API validation failed
→ Solution: Check N8N_LOGIN_CREDENTIAL_NAME matches credential in n8n
```

**Git Push Failures**:
```bash
# Permission denied
remote: Permission to user/repo.git denied
→ Solution: Verify GITHUB_TOKEN has 'repo' scope
```

## Dry-Run Mode

Preview operations without side effects:

```bash
n8n-git push --dry-run --verbose
```

**Logged Operations** (not executed):
- Would execute: `docker exec n8n export:workflow ...`
- Would copy workflows to Git repository
- Would create Git commit: `[new] Workflow Name`
- Would push to remote: `origin/main`

## Automation Examples

### Daily Backup Cron Job

```bash
# /etc/cron.d/n8n-backup
0 2 * * * user /usr/local/bin/n8n-git push \
  --workflows 2 \
  --credentials 1 \
  --folder-structure \
  --github-path "daily-backup/%DATE%/" \
  --defaults
```

### CI/CD Integration

```yaml
# .github/workflows/n8n-backup.yml
name: n8n Backup
on:
  schedule:
    - cron: '0 2 * * *'
jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - name: Push workflows to Git
        run: |
          n8n-git push \
            --container n8n-prod \
            --workflows 2 \
            --credentials 1 \
            --folder-structure \
            --github-path "prod-backup/%YYYY%/%MM%/" \
            --defaults
        env:
          GITHUB_TOKEN: ${{ secrets.N8N_BACKUP_TOKEN }}
          GITHUB_REPO: company/n8n-backups
```

## Related Documentation

- **Pull Operations**: [docs/pull.md](pull.md) — Import workflows back into n8n
- **Reset Feature**: [docs/reset.md](reset.md) — Time-travel through Git history
- **Architecture**: [docs/ARCHITECTURE.md](ARCHITECTURE.md) — System design overview
- **User Guide**: [README.md](../README.md) — Full feature documentation
