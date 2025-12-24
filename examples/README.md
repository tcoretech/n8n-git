# n8n-git Examples

This directory contains examples for using n8n-git in various scenarios.

## Dockerfile Examples

### [`Dockerfile.n8n-with-git`](./Dockerfile.n8n-with-git)

Build an n8n container with n8n-git installed inside, enabling workflows to call n8n-git commands via the Execute Command node.

**Build:**
```bash
docker build -t n8n-with-git:latest -f examples/Dockerfile.n8n-with-git .
```

**Run:**
```bash
docker run -d \
  --name n8n \
  -p 5678:5678 \
  -v n8n_data:/home/node/.n8n \
  -e N8N_LOGIN_CREDENTIAL_NAME="N8N REST BACKUP" \
  -e GITHUB_TOKEN="your_github_token" \
  -e GITHUB_REPO="your_username/n8n-workflows" \
  n8n-with-git:latest
```

**Key Features:**
- n8n-git runs directly inside the container (no docker exec needed)
- Workflows can trigger git operations via Execute Command node
- No Docker socket access required
- All dependencies (bash, git, curl, jq) included

## Workflow Examples

### [`workflow-automated-backup.json`](./workflow-automated-backup.json)

**Automated Daily Backup Workflow**

This workflow runs daily at 2 AM and:
1. Executes `n8n-git push` to back up workflows and credentials
2. Checks the exit code for success/failure
3. Sends Slack notifications based on the result

**To use:**
1. Import the workflow into your n8n instance
2. Configure Slack credentials (or replace with your notification method)
3. Ensure n8n-git is installed inside the container
4. Activate the workflow

**Prerequisites:**
- n8n running in a container built with n8n-git (see Dockerfile example)
- Environment variables configured:
  - `N8N_BASE_URL=http://localhost:5678`
  - `GITHUB_TOKEN=your_token`
  - `GITHUB_REPO=your_username/repo`
- n8n-git will automatically use local execution when run inside the container

## Configuration Examples

### Basic Config for Embedded n8n-git

Create a `.config` file in your n8n container:

```bash
# /root/.config/n8n-git/config

# n8n API access
# When running inside the container, n8n-git automatically detects
# the local n8n CLI and uses it directly (no container parameter needed)
N8N_BASE_URL=http://localhost:5678
N8N_LOGIN_CREDENTIAL_NAME="N8N REST BACKUP"

# GitHub settings
GITHUB_REPO="myuser/n8n-workflows"
GITHUB_BRANCH="main"
GITHUB_TOKEN="${GITHUB_TOKEN}"  # From environment

# Storage modes
WORKFLOWS=2          # Push to Git
CREDENTIALS=1        # Local encrypted storage
ENVIRONMENT=0        # Skip environment variables

# Features
FOLDER_STRUCTURE=true
DECRYPT_CREDENTIALS=false

# General
ASSUME_DEFAULTS=true  # Non-interactive mode for automation
VERBOSE=false
```

### Kubernetes ConfigMap Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: n8n-git-config
data:
  config: |
    N8N_BASE_URL=http://localhost:5678
    N8N_LOGIN_CREDENTIAL_NAME="N8N REST BACKUP"
    GITHUB_REPO="myuser/n8n-workflows"
    WORKFLOWS=2
    CREDENTIALS=1
    FOLDER_STRUCTURE=true
    ASSUME_DEFAULTS=true
---
apiVersion: v1
kind: Secret
metadata:
  name: n8n-git-secrets
type: Opaque
stringData:
  github-token: "ghp_your_github_token"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
spec:
  replicas: 1
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      containers:
      - name: n8n
        image: n8n-with-git:latest
        ports:
        - containerPort: 5678
        env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: n8n-git-secrets
              key: github-token
        volumeMounts:
        - name: config
          mountPath: /root/.config/n8n-git
          readOnly: true
        - name: data
          mountPath: /home/node/.n8n
      volumes:
      - name: config
        configMap:
          name: n8n-git-config
      - name: data
        persistentVolumeClaim:
          claimName: n8n-data
```

## Use Cases

### 1. Workflow-Triggered Manual Backup

Create a simple webhook-triggered workflow:

```bash
# Trigger URL: http://your-n8n:5678/webhook/backup-now
# Command: n8n-git push --workflows 2 --folder-structure --defaults
```

### 2. Pre-Deployment Snapshot

Before deploying workflow changes:

```bash
# In Execute Command node:
n8n-git push --workflows 2 --folder-structure --github-path "snapshots/pre-deploy-$(date +%Y%m%d-%H%M%S)/"
```

### 3. Multi-Environment Sync

Sync workflows from staging to production:

```bash
# Staging: Push workflows
n8n-git push --workflows 2 --folder-structure --branch staging

# Production: Pull from staging branch
n8n-git pull --workflows 2 --folder-structure --branch staging --n8n-path "Staging Import"
```

### 4. Scheduled Credential Backup

```bash
# Local encrypted backup of credentials only
n8n-git push --workflows 0 --credentials 1 --local-path /backup/credentials
```

## Troubleshooting

### Issue: "n8n command not found"

**Solution:** Ensure you're using the Dockerfile example or have n8n installed in the container:

```dockerfile
# Verify n8n is available
RUN which n8n || echo "n8n not found!"
```

### Issue: "Permission denied" when executing n8n-git

**Solution:** Ensure n8n-git is executable and in PATH:

```dockerfile
RUN chmod +x /usr/local/bin/n8n-git
RUN which n8n-git
```

### Issue: Git authentication fails

**Solution:** Ensure GitHub token is set and has correct permissions:

```bash
# In workflow Execute Command node:
echo $GITHUB_TOKEN | grep -q "ghp_" && echo "Token set" || echo "Token missing"
```

### Issue: "Docker not available" or "Container not found"

**Solution:** When running inside the n8n container, ensure you're NOT specifying a --container parameter:

```bash
# Correct (inside container):
n8n-git push --workflows 2

# Wrong (inside container):
n8n-git push --container n8n --workflows 2  # Don't do this!
```

n8n-git will automatically detect the local n8n CLI and use it directly.

## Additional Resources

- [Main README](../README.md)
- [Architecture Documentation](../docs/ARCHITECTURE.md)
- [Configuration Reference](../.config.example)
- [Local Execution Mode Proposal](../docs/issues/local-execution-mode.md)
