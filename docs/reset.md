# n8n-git Reset Reference

The `n8n-git reset` verb aligns a connected n8n workspace with a Git commit chosen explicitly, via the interactive picker, or through a natural-language time window. Every flow reuses the existing pull validations, prints a confirmation plan, and honours `--dry-run` for safe previews.

## Command Synopsis

```bash
n8n-git reset \
  [--to <sha|tag>] \
  [--interactive] \
  [--since <time> [--until <time>]] \
  [--mode <soft|hard>] \
  [--dry-run]
```

- `--to` targets an explicit commit, tag, or branch tip (`git rev-parse` validation).
- `--interactive` launches the grouped picker (Day/Week toggles, filter prompt, tag highlights).
- `--since/--until` accepts ISO timestamps or natural language understood by Git (e.g. `--since "last Friday 18:00"`). When `--until` is omitted the current time is used.
- `--mode soft` archives workflows missing from the target commit; `--mode hard` deletes them after a destructive confirmation warning.
- `--dry-run` skips Git and n8n mutations after printing the plan.

Mutually exclusive target modes: only one of `--to`, `--interactive`, or `--since/--until` can be supplied per invocation.

## Typical Flows

### Explicit reset

```bash
n8n-git reset --to 7c9f1b3 --mode soft
```

Resolves `7c9f1b3` (tag, branch, or SHA), computes workflow diffs, prompts for confirmation, archives missing workflows, and syncs the repository snapshot back into n8n.

### Interactive picker

```bash
n8n-git reset --interactive --mode hard
```

Displays the latest 60 commits grouped by day (toggle `w` for week view) with filter support. Selection prints a plan annotated with the picker context, then proceeds like the explicit flow. `q` aborts with exit code `130`. For scripted runs set `RESET_INTERACTIVE_AUTOPICK=<index|sha>` to auto-select or `RESET_INTERACTIVE_AUTOPICK_ACTION=abort` to emulate cancellation.

### Time window reset

```bash
n8n-git reset --since "2025-11-01 09:00" --until "2025-11-04 23:59"
```

Uses Git’s history parser to find the latest commit between the supplied bounds. Confirmation output includes the normalised window for audit logs. If no commits exist the command exits with validation code `2`.

## Confirmation & Exit Codes

Every path prints a reset plan summarising:

- Branch, mode, and dry-run status
- Target commit metadata and source (explicit, interactive, time window)
- Workflow action counts (archive/delete/restore/unchanged)
- Warnings when the target is not an ancestor, is older than 30 days, or when destructive hard deletions will occur

Exit-code meaning:

| Code | Description |
| --- | --- |
| `0` | Reset executed (or dry-run completed) successfully. |
| `1` | Execution failure (Git or n8n API error). |
| `2` | Validation failure (invalid reference, empty time window, missing prerequisites). |
| `130` | User aborted via picker, confirmation prompt, or `RESET_INTERACTIVE_AUTOPICK_ACTION=abort`. |

## Automation Tips

- Use `--dry-run` with `--mode hard` to inspect impact before destructive resets.
- Supply `--defaults` or export `ASSUME_DEFAULTS=true` when running from CI to auto-confirm prompts; the interactive picker will fall back to the latest commit unless `RESET_INTERACTIVE_AUTOPICK` overrides it.
- The picker reads these environment variables (useful for tests or scheduled workflows):

| Variable | Purpose |
| --- | --- |
| `RESET_INTERACTIVE_AUTOPICK` | Auto-select by index (`1`, `2`, …) or SHA prefix instead of prompting. |
| `RESET_INTERACTIVE_AUTOPICK_ACTION` | Set to `abort` to simulate a cancellation (returns exit code `130`). |
| `RESET_INTERACTIVE_FILTER` | Apply an initial case-insensitive filter to the picker list. |
| `RESET_PICKER_LIMIT` | Override the number of commits shown (default `60`). |
| `RESET_PICKER_DEFAULT_VIEW` | Default grouping (`day` or `week`). |

## Hard vs Soft Mode

| Mode | Workflow impact | API calls |
| --- | --- | --- |
| `soft` | Archives workflows absent from the target commit so they remain recoverable inside n8n. | `POST /rest/workflows/{id}/archive` |
| `hard` | Permanently deletes workflows missing from the target commit (after archiving to satisfy API constraints). | `POST /rest/workflows/{id}/archive` followed by `DELETE /rest/workflows/{id}` |

Both modes restore workflows that exist in Git but not in the workspace, and respect the pull pipeline’s validation order (config → Git state → n8n connectivity). Use `log --verbose` to see each archive/delete call and inspect `action_totals` in the summary before re-running.
