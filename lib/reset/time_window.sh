#!/usr/bin/env bash
# =========================================================
# lib/reset/time_window.sh - Utilities for time-window resets
# =========================================================
# Normalises natural-language timestamps and resolves commits
# that fall within the requested window.

set -Eeuo pipefail
IFS=$'\n\t'

TIME_WINDOW_LIMIT="${TIME_WINDOW_LIMIT:-1000}"
TIME_WINDOW_DEFAULT_REF="${TIME_WINDOW_DEFAULT_REF:-HEAD}"

# Determine whether GNU date style -d flag is available.
_time_window_has_gnu_date() {
    date -d @0 '+%s' >/dev/null 2>&1
}

# Normalise a raw user-supplied time expression to ISO-8601.
# Returns empty string when normalisation fails so callers can
# fall back to the raw input while still allowing Git to parse it.
normalize_time_boundary() {
    local raw_input="$1"
    local normalized=""

    if [[ -z "$raw_input" ]]; then
        echo ""
        return 0
    fi

    if command -v gdate >/dev/null 2>&1; then
        normalized=$(gdate -u -d "$raw_input" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    elif _time_window_has_gnu_date; then
        normalized=$(date -u -d "$raw_input" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    fi

    if [[ -z "$normalized" && -n "$(command -v python3 2>/dev/null)" ]]; then
        normalized=$(
python3 - "$raw_input" <<'PY' 2>/dev/null
import sys
from datetime import datetime, timezone
raw = sys.argv[1]
try:
    if raw.lower() == "now":
        dt = datetime.now(timezone.utc)
    else:
        raw_clean = raw.replace('Z', '+00:00')
        dt = datetime.fromisoformat(raw_clean)
    print(dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception:
    pass
PY
        ) || true
    fi

    printf '%s\n' "$normalized"
}

# Resolve the latest commit that falls within the requested window.
# Args: since_input until_input ref
resolve_time_window_commit() {
    local since_input="$1"
    local until_input="$2"
    local ref="${3:-$TIME_WINDOW_DEFAULT_REF}"
    local args=(--max-count=1 --date-order --since="$since_input")

    if [[ -n "$until_input" ]]; then
        args+=(--until="$until_input")
    fi

    args+=("$ref")

    git rev-list "${args[@]}" 2>/dev/null | head -n 1
}

# Describe the requested time window for plan summaries.
format_time_window_context() {
    local since_raw="$1"
    local until_raw="$2"
    local since_norm until_norm

    since_norm=$(normalize_time_boundary "$since_raw")
    until_norm=$(normalize_time_boundary "${until_raw:-now}")

    if [[ -z "$since_norm" ]]; then
        since_norm="$since_raw"
    fi
    if [[ -z "$until_norm" ]]; then
        until_norm="${until_raw:-now}"
    fi

    printf 'Time window: %s → %s' "$since_norm" "$until_norm"
}

export -f normalize_time_boundary
export -f resolve_time_window_commit
export -f format_time_window_context
