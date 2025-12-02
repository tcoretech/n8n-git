# Push Modules

This directory hosts push-focused helpers extracted from the original monolithic export flow.

## Module map
- `container_io.sh` — Docker interactions for workflow exports (copies, temp directories).
- `folder_mapping.sh` — Folder mapping metadata, flat fallback, and Git organization helpers.
- `export.sh` — Push orchestrator sourcing shared helpers.

Shared utilities used from `lib/utils/`, and Git-specific helpers live under `lib/github/`.
