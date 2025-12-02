#!/usr/bin/env bash
# =========================================================
# Installer for n8n-git
# =========================================================
set -Eeuo pipefail
IFS=$'\n\t'

log() {
    local level="$1"
    shift
    printf '[%s] %s\n' "$level" "$*"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log ERROR "Required command '$1' is not available."
        exit 1
    fi
}

cleanup() {
    [[ -d "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
}

trap cleanup EXIT

INSTALL_NAME="${INSTALL_NAME:-n8n-git}"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
SHAREDIR="${SHAREDIR:-$PREFIX/share/n8n-git}"
LIB_DEST="${LIB_DEST:-$SHAREDIR/lib}"
SCRIPT_DEST="$BINDIR/$INSTALL_NAME"

SOURCE_REF="${N8N_GIT_SOURCE_REF:-main}"
ARCHIVE_URL="${N8N_GIT_SOURCE_URL:-https://github.com/tcoretech/n8n-git/archive/refs/heads/${SOURCE_REF}.tar.gz}"

log INFO "n8n-git installer"
log INFO "Installing binary to $SCRIPT_DEST"
log INFO "Installing libraries to $LIB_DEST"

require_command curl
require_command tar
require_command install

WORKDIR="$(mktemp -d)"

ARCHIVE_PATH="$WORKDIR/n8n-git.tar.gz"
log INFO "Downloading sources from $ARCHIVE_URL"
if ! curl -fsSL "$ARCHIVE_URL" -o "$ARCHIVE_PATH"; then
    log ERROR "Failed to download archive. Check your network connection or SOURCE_REF."
    exit 1
fi

log INFO "Extracting archive"
if ! tar -xzf "$ARCHIVE_PATH" -C "$WORKDIR"; then
    log ERROR "Failed to extract archive."
    exit 1
fi

SOURCE_DIR=$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'n8n-git-*' | head -n 1)
if [[ -z "$SOURCE_DIR" ]]; then
    log ERROR "Unable to locate extracted source directory."
    exit 1
fi

log INFO "Preparing installation directories"
if ! install -d "$BINDIR"; then
    log ERROR "Cannot create $BINDIR. Re-run as root or override PREFIX/BINDIR."
    exit 1
fi
if ! install -d "$SHAREDIR"; then
    log ERROR "Cannot create $SHAREDIR. Re-run as root or override PREFIX/SHAREDIR."
    exit 1
fi

log INFO "Installing CLI to $SCRIPT_DEST"
if ! install -m 755 "$SOURCE_DIR/n8n-git.sh" "$SCRIPT_DEST"; then
    log ERROR "Failed to install CLI executable."
    exit 1
fi

log INFO "Syncing library modules"
if [[ -d "$LIB_DEST" ]]; then
    rm -rf "$LIB_DEST"
fi
if ! mkdir -p "$LIB_DEST"; then
    log ERROR "Failed to create $LIB_DEST."
    exit 1
fi
if ! cp -R "$SOURCE_DIR/lib/." "$LIB_DEST/"; then
    log ERROR "Failed to copy libraries into $LIB_DEST."
    exit 1
fi

log SUCCESS "n8n-git installed successfully"
log INFO "Binary: $SCRIPT_DEST"
log INFO "Libraries: $LIB_DEST"
log INFO "Run '$INSTALL_NAME --help' to get started."

