#!/usr/bin/env bash
# Folder assignment audit logging

# Log a folder assignment operation
# Args: audit_log_path, workflow_id, workflow_name, project_id, folder_id, display_path, status, note
# Returns: 0 always (non-fatal)
log_folder_assignment() {
    local audit_log_path="$1"
    local workflow_id="$2"
    local workflow_name="$3"
    local project_id="$4"
    local folder_id="$5"
    local display_path="$6"
    local status="$7"
    local note="${8:-}"
    
    [[ -z "$audit_log_path" ]] && return 0
    
    # Simple NDJSON append (no jq overhead per record)
    local record
    record=$(printf '{"workflowId":"%s","workflowName":"%s","projectId":"%s","folderId":"%s","displayPath":"%s","status":"%s","note":"%s"}\n' \
        "$workflow_id" \
        "${workflow_name//\"/\\\"}" \
        "$project_id" \
        "${folder_id:-null}" \
        "${display_path//\"/\\\"}" \
        "$status" \
        "${note//\"/\\\"}")
    
    printf '%s' "$record" >> "$audit_log_path"
    return 0
}

# Generate summary report from audit log
# Args: audit_log_path
# Returns: 0 on success
summarize_folder_assignments() {
    local audit_log_path="$1"
    
    if [[ -z "$audit_log_path" || ! -f "$audit_log_path" ]]; then
        return 0
    fi
    
    # Count results by status
    local total=0 success=0 failed=0
    
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        
        local status
        status=$(printf '%s' "$record" | jq -r '.status // ""' 2>/dev/null)
        
        total=$((total + 1))
        
        case "$status" in
            success) success=$((success + 1)) ;;
            failed) failed=$((failed + 1)) ;;
        esac
    done < "$audit_log_path"
    
    if [[ "$total" -eq 0 ]]; then
        log INFO "No folder assignments recorded"
        return 0
    fi
    
    log INFO "Folder assignment summary: $success/$total successful, $failed failed"
    
    # Show failed assignments if any
    if [[ "$failed" -gt 0 && "${verbose:-false}" == "true" ]]; then
        log WARN "Failed assignments (showing up to 10 entries):"

        local shown=0
        while IFS= read -r record; do
            [[ -z "$record" ]] && continue
            
            local status
            status=$(printf '%s' "$record" | jq -r '.status // ""' 2>/dev/null)
            
            if [[ "$status" == "failed" ]]; then
                local workflow_name display_path note
                workflow_name=$(printf '%s' "$record" | jq -r '.workflowName // ""' 2>/dev/null)
                display_path=$(printf '%s' "$record" | jq -r '.displayPath // ""' 2>/dev/null)
                note=$(printf '%s' "$record" | jq -r '.note // ""' 2>/dev/null)

                local note_suffix=""
                if [[ -n "$note" ]]; then
                    note_suffix=" — $note"
                fi

                log WARN "    ${workflow_name:-(unnamed workflow)} → ${display_path:-<no path>}${note_suffix}"

                shown=$((shown + 1))
                [[ "$shown" -ge 10 ]] && break
            fi
        done < "$audit_log_path"
        
        if [[ "$failed" -gt "$shown" ]]; then
            log WARN "    …and $((failed - shown)) additional failure(s)"
        fi
    fi
    
    return 0
}

# Summarize manifest assignment/reconciliation status
# Args: manifest_path, summary_label
# Returns: 0 always (non-fatal)
summarize_manifest_assignment_status() {
    local manifest_path="$1"
    local summary_label="$2"

    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        return 0
    fi

    # Process manifest entries and compute summary stats
    local total=0 resolved=0 unresolved=0
    declare -A strategy_counts=()
    local -a warnings=()
    
    while IFS= read -r entry_line; do
        [[ -z "$entry_line" ]] && continue

        if ! printf '%s' "$entry_line" | jq empty >/dev/null 2>&1; then
            continue
        fi

        total=$((total + 1))

    local is_reconciled
    is_reconciled=$(printf '%s' "$entry_line" | jq -r '.idReconciled // false' 2>/dev/null)
    local strategy
    strategy=$(printf '%s' "$entry_line" | jq -r '.idResolutionStrategy // ""' 2>/dev/null)
    local warning_text
    warning_text=$(printf '%s' "$entry_line" | jq -r '.idReconciliationWarning // ""' 2>/dev/null)
    local entry_name
    entry_name=$(printf '%s' "$entry_line" | jq -r '.name // "Workflow"' 2>/dev/null)

        if [[ "$is_reconciled" == "true" ]]; then
            resolved=$((resolved + 1))
        else
            unresolved=$((unresolved + 1))
        fi
        
        if [[ -n "$strategy" ]]; then
            strategy_counts["$strategy"]=$((${strategy_counts["$strategy"]:-0} + 1))
        fi
        
        if [[ "$is_reconciled" != "true" && -n "$warning_text" ]]; then
            warnings+=("${entry_name}\t${warning_text}")
        fi
    done < "$manifest_path"

    if [[ "$total" -eq 0 ]]; then
        return 0
    fi

    log INFO "ID reconciliation ${summary_label:+($summary_label)}: $resolved/$total resolved, $unresolved unresolved"

    if [[ "$verbose" == "true" && "${#strategy_counts[@]}" -gt 0 ]]; then
        local detail_segments=()
        for strategy in "${!strategy_counts[@]}"; do
            local count="${strategy_counts[$strategy]}"
            local description
            case "$strategy" in
                manifest-id)
                    description="matched manifest IDs"
                    ;;
                existing-workflow-id)
                    description="matched existing workflow IDs"
                    ;;
                original-workflow-id)
                    description="matched original workflow IDs"
                    ;;
                name-only)
                    description="matched by workflow name"
                    ;;
                *)
                    description="used strategy '$strategy'"
                    ;;
            esac
            detail_segments+=("$count workflow(s) $description")
        done
        local IFS='; '
        log DEBUG "ID reconciliation strategies: ${detail_segments[*]}"
    fi
    
    if [[ "$unresolved" -gt 0 ]]; then
        log WARN "$unresolved workflow(s) could not be reconciled with imported IDs"
        
        if [[ "$verbose" == "true" && "${#warnings[@]}" -gt 0 ]]; then
            local shown=0
            for warning in "${warnings[@]}"; do
                IFS=$'\t' read -r wf_name wf_warning <<< "$warning"
                log DEBUG "Unresolved workflow '$wf_name': $wf_warning"
                shown=$((shown + 1))
                [[ "$shown" -ge 10 ]] && break
            done
            
            if [[ "${#warnings[@]}" -gt "$shown" ]]; then
                log DEBUG "…and $((${#warnings[@]} - shown)) additional warning(s)"
            fi
        fi
    fi
    
    return 0
}
