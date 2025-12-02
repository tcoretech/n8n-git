#!/usr/bin/env bash
# =========================================================
# lib/reset/reset.sh - Main orchestrator for reset verb
# =========================================================
# Coordinates reset operations: target resolution, planning,
# confirmation, and execution to align n8n workspace with
# a specific repository snapshot

set -Eeuo pipefail
IFS=$'\n\t'

# Source common utilities
# shellcheck source=lib/utils/common.sh
if [[ -f "${BASH_SOURCE[0]%/*}/../utils/common.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/../utils/common.sh"
else
    echo "ERROR: Cannot find lib/utils/common.sh" >&2
    exit 1
fi

# Source reset modules
# shellcheck source=lib/reset/common.sh
if [[ -f "${BASH_SOURCE[0]%/*}/common.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/common.sh"
fi
# shellcheck source=lib/reset/resolve.sh
if [[ -f "${BASH_SOURCE[0]%/*}/resolve.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/resolve.sh"
fi
# shellcheck source=lib/reset/plan.sh
if [[ -f "${BASH_SOURCE[0]%/*}/plan.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/plan.sh"
fi
# shellcheck source=lib/reset/apply.sh
if [[ -f "${BASH_SOURCE[0]%/*}/apply.sh" ]]; then
    source "${BASH_SOURCE[0]%/*}/apply.sh"
fi

# --- Reset-specific configuration ---
reset_mode="${reset_mode:-soft}"  # soft (archive) or hard (delete)
reset_target="${reset_target:-}"  # commit SHA, tag, or branch
reset_dry_run="${reset_dry_run:-false}"
reset_interactive="${reset_interactive:-false}"
reset_since="${reset_since:-}"
reset_until="${reset_until:-}"

# --- Stub functions for reset workflow ---

# Resolve target commit from user input
# Handles --to, --since/--until, and --interactive modes
# Exports: RESOLVED_TARGET_SHA, RESOLVED_TARGET_DISPLAY, RESOLVED_TARGET_SOURCE
# Returns: 0 on success, 2 on invalid target
resolve_target_commit() {
    log INFO "Resolving target commit..."
    
    # Determine resolution mode
    if [[ -n "$reset_target" ]]; then
        # Explicit mode: --to <sha|tag>
        if ! parse_explicit_target "$reset_target"; then
            local exit_code=$?
            log ERROR "Failed to resolve explicit target: $reset_target"
            [[ $exit_code -eq 130 ]] && return 130
            return 2
        fi
        log INFO "Target resolved (explicit): $RESOLVED_TARGET_DISPLAY ($RESOLVED_TARGET_SHA)"
        
    elif [[ "$reset_interactive" == "true" ]]; then
        # Interactive mode: --interactive
        log INFO "Launching interactive commit picker..."
        if ! launch_interactive_picker; then
            local exit_code=$?
            log ERROR "Interactive picker failed or was cancelled"
            [[ $exit_code -eq 130 ]] && return 130
            return 2
        fi
        log INFO "Target resolved (interactive): $RESOLVED_TARGET_DISPLAY ($RESOLVED_TARGET_SHA)"
        
    elif [[ -n "$reset_since" ]] || [[ -n "$reset_until" ]]; then
        # Time window mode: --since/--until
        log INFO "Resolving target from time window..."
        if ! parse_time_window "$reset_since" "$reset_until"; then
            log ERROR "Failed to resolve time window: since=$reset_since until=$reset_until"
            return 2
        fi
        log INFO "Target resolved (time window): $RESOLVED_TARGET_DISPLAY ($RESOLVED_TARGET_SHA)"
        
    else
        # No target specified - error
        log ERROR "No target specified. Use --to, --interactive, or --since/--until"
        return 2
    fi
    
    # Update global reset_target for downstream usage
    reset_target="$RESOLVED_TARGET_SHA"
    
    return 0
}

# Generate reset plan
# Computes workflow diffs and creates confirmation summary
# Returns: 0 on success, 1 on failure
generate_reset_plan() {
    log INFO "Generating reset plan..."
    
    # Get current branch
    local current_branch
    current_branch=$(get_current_branch)
    
    # Initialize reset plan
    local plan_id
    plan_id=$(init_reset_plan \
        "$current_branch" \
        "$reset_mode" \
        "$RESOLVED_TARGET_SHA" \
        "$RESOLVED_TARGET_DISPLAY" \
        "$RESOLVED_TARGET_SOURCE" \
        "$reset_dry_run" \
        "${RESOLVED_TARGET_CONTEXT:-}")
    
    log DEBUG "Plan initialized: $plan_id"
    
    # Compute workflow differences
    if ! compute_workflow_diff "$reset_mode" "$RESOLVED_TARGET_SHA"; then
        log ERROR "Failed to compute workflow differences"
        return 1
    fi
    
    log SUCCESS "Reset plan generated"
    return 0
}

# Display reset plan and get confirmation
# Shows branch, mode, target, impact summary
# Returns: 0 if confirmed, 130 if user aborts, 2 if dry-run
display_confirmation() {
    # Display plan details
    display_reset_plan
    
    # If dry-run, skip confirmation prompt
    if [[ "$reset_dry_run" == "true" ]]; then
        log DRYRUN "Dry-run mode: skipping execution"
        return 2
    fi
    
    # Prompt for confirmation
    if ! prompt_for_confirmation; then
        log WARN "Reset aborted by user"
        return 130
    fi
    
    log SUCCESS "Plan confirmed"
    return 0
}

# Execute reset operations
# Applies Git reset and syncs n8n workspace
# Returns: 0 on success, 1 on failure
execute_reset() {
    log INFO "Executing reset operations..."
    
    # Execute all reset actions (archive/delete/restore)
    if ! execute_reset_actions "$reset_dry_run"; then
        log ERROR "Reset action execution failed"
        return 1
    fi

    # Import workflows from the target snapshot via pull pipeline
    if ! perform_reset_pull "$RESOLVED_TARGET_SHA" "$reset_dry_run"; then
        log ERROR "Failed to import workflows from target commit"
        return 1
    fi
    
    # TODO: Apply Git reset to repository (Phase 6 - for now, Git reset is manual)
    # git reset --hard "$RESOLVED_TARGET_SHA"
    
    log SUCCESS "Reset execution complete"
    return 0
}

# Display reset summary
# Shows final status and next steps
# Returns: 0 always
display_summary() {
    # Display execution summary from plan
    display_reset_summary
    return 0
}

# Main reset orchestration
# Coordinates the full reset workflow
# Args: parsed from CLI flags (set via caller)
# Returns: 0 on success, 1 on execution failure, 2 on validation failure, 130 on user abort
main_reset() {
    local exit_code=0
    
    log HEADER "n8n-git Reset"
    log INFO "Mode: $reset_mode | Dry-run: $reset_dry_run"
    
    # Step 1: Validate prerequisites
    if ! validate_reset_prerequisites; then
        return 2
    fi
    
    # Step 2: Resolve target commit
    if ! resolve_target_commit; then
        log ERROR "Failed to resolve target commit"
        return 2
    fi
    
    # Step 3: Generate reset plan
    if ! generate_reset_plan; then
        log ERROR "Failed to generate reset plan"
        return 1
    fi
    
    # Step 4: Display plan and get confirmation
    if ! display_confirmation; then
        exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            # Dry-run mode: exit cleanly
            log INFO "Dry-run complete"
            return 0
        elif [[ $exit_code -eq 130 ]]; then
            # User abort
            log WARN "Reset aborted by user"
            return 130
        else
            log ERROR "Confirmation failed"
            return 2
        fi
    fi
    
    # Step 5: Execute reset
    if ! execute_reset; then
        log ERROR "Reset execution failed"
        return 1
    fi
    
    # Step 6: Display summary
    display_summary
    
    return 0
}

# Allow this script to be sourced or executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_reset "$@"
fi
