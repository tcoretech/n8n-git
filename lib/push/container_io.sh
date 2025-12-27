#!/usr/bin/env bash
# =========================================================
# lib/push/container_io.sh - Container export helpers for push flow
# =========================================================
# Provides focused helpers that interact with the n8n Docker container
# to collect workflow artifacts for downstream processing.

push_collect_workflow_exports() {
    local container_id="$1"
    local result_ref="${2:-}"

    if [[ -z "$container_id" ]]; then
        log ERROR "Container ID not provided for workflow export"
        return 1
    fi

    log DEBUG "Exporting individual workflows from n8n container..."
    local _pce_temp_dir
    _pce_temp_dir="$(mktemp -d -t n8n-workflows-XXXXXXXXXX)" || {
        log ERROR "Failed to allocate temporary directory for workflow export"
        return 1
    }

    if ! n8n_exec "$container_id" "rm -rf /tmp/workflow_exports && mkdir -p /tmp/workflow_exports" false; then
        log ERROR "Failed to prepare workflow export directory inside container"
        cleanup_temp_path "$_pce_temp_dir"
        return 1
    fi

    local export_cmd="n8n export:workflow --all --separate --output=/tmp/workflow_exports/"
    if ! n8n_exec "$container_id" "$export_cmd" false; then
        log ERROR "Failed to export individual workflow files from container"
        cleanup_temp_path "$_pce_temp_dir"
        return 1
    fi

    local cp_workflow_output=""
    local docker_cp_local_export_dir
    docker_cp_local_export_dir=$(convert_path_for_docker_cp "$_pce_temp_dir/")
    [[ -z "$docker_cp_local_export_dir" ]] && docker_cp_local_export_dir="$_pce_temp_dir/"
    if ! copy_from_n8n "/tmp/workflow_exports/" "$docker_cp_local_export_dir" "$container_id"; then
        log ERROR "Failed to copy exported workflow files from n8n instance"
        cleanup_temp_path "$_pce_temp_dir"
        return 1
    fi

    if [[ ! -d "$_pce_temp_dir/workflow_exports" ]]; then
        log ERROR "Expected workflow export directory missing after copy from n8n"
        cleanup_temp_path "$_pce_temp_dir"
        return 1
    fi

    log SUCCESS "Exported individual workflow files to temporary directory"

    if [[ -n "$result_ref" ]]; then
        printf -v "$result_ref" '%s' "$_pce_temp_dir"
    else
        printf '%s\n' "$_pce_temp_dir"
    fi

    return 0
}
