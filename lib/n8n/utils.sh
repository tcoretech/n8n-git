#!/usr/bin/env bash
# =========================================================
# lib/n8n/utils.sh - n8n API utilities
# =========================================================
# Common utility functions for n8n API interactions

if [[ -n "${LIB_N8N_UTILS_LOADED:-}" ]]; then
  return 0
fi
LIB_N8N_UTILS_LOADED=true

sanitize_n8n_json_response() {
    local raw="${1-}"

    # Treat unset or empty payloads as an empty object to avoid jq errors
    if [[ -z "$raw" ]]; then
        printf '{}'
        return 0
    fi

    local sanitized="$raw"

    # Strip UTF-8 BOM if present and carriage returns that break jq parsing
    if [[ "${sanitized:0:1}" == $'\uFEFF' ]]; then
        sanitized="${sanitized:1}"
    fi
    sanitized="${sanitized//$'\r'/}"

    # Collapse payloads that are only whitespace or explicit null into empty object
    if [[ "$sanitized" =~ ^[[:space:]]*$ ]]; then
        printf '{}'
        return 0
    fi

    if [[ "$sanitized" == "null" ]]; then
        printf '{}'
        return 0
    fi

    printf '%s' "$sanitized"
}

normalize_identifier() {
    local value="${1-}"

    # Remove control characters and surrounding whitespace
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value//$'\t'/}"

    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"

    if [[ -z "$value" || "$value" == "null" ]]; then
        printf ''
        return 0
    fi

    # Retain only safe identifier characters (alphanumeric, underscore, hyphen)
    value="$(printf '%s' "$value" | tr -dc '[:alnum:]_-')"

    printf '%s' "$value"
}

trim_identifier_value() {
    local value="${1-}"

    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value//$'\t'/}"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"

    if [[ -z "$value" || "$value" == "null" ]]; then
        printf ''
        return 0
    fi

    printf '%s' "$value"
}
