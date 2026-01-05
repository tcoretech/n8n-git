#!/usr/bin/env bash
# =========================================================
# lib/utils/version.sh - Version check and update utilities
# =========================================================
# Functions for checking for updates, comparing versions,
# and performing self-updates of n8n-git

# GitHub repository for n8n-git
N8N_GIT_REPO="${N8N_GIT_REPO:-tcoretech/n8n-git}"
N8N_GIT_UPDATE_CHECK_INTERVAL="${N8N_GIT_UPDATE_CHECK_INTERVAL:-86400}"  # 24 hours in seconds

# Global variables for update state (initialized to prevent unset variable issues)
UPDATE_AVAILABLE="${UPDATE_AVAILABLE:-false}"
LATEST_VERSION="${LATEST_VERSION:-}"

# Installation detection globals
INSTALL_TYPE="${INSTALL_TYPE:-}"
INSTALL_BINDIR="${INSTALL_BINDIR:-}"
INSTALL_SHAREDIR="${INSTALL_SHAREDIR:-}"

# Cache file for version check (avoid spamming GitHub API)
_get_version_cache_file() {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/n8n-git"
    mkdir -p "$cache_dir" 2>/dev/null || true
    echo "$cache_dir/version-check"
}

# Get the latest release version from GitHub
# Returns: version string (e.g., "1.2.0") or empty on failure
get_latest_release_version() {
    local api_url="https://api.github.com/repos/${N8N_GIT_REPO}/releases/latest"
    local response
    local version=""

    # Try to fetch latest release info
    if command -v curl >/dev/null 2>&1; then
        response=$(curl -fsSL --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        response=$(wget -qO- --timeout=10 "$api_url" 2>/dev/null) || return 1
    else
        return 1
    fi

    # Extract tag_name from JSON response
    # GitHub tags are usually "v1.2.0" format, we strip the leading 'v'
    if command -v jq >/dev/null 2>&1; then
        version=$(echo "$response" | jq -r '.tag_name // empty' 2>/dev/null)
    else
        # Fallback: use grep/sed for JSON parsing
        version=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi

    # Strip leading 'v' if present
    version="${version#v}"

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi
    return 1
}

# Validate a version string matches semantic versioning pattern
# Returns: 0 if valid, 1 if invalid
# Valid formats: 1.2.3, v1.2.3, 1.2, v1.2
is_valid_version() {
    local version="$1"
    # Strip leading 'v' if present
    version="${version#v}"
    # Check for valid semver pattern (major.minor or major.minor.patch)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        return 0
    fi
    return 1
}

# Compare two semantic versions
# Returns: 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    # Strip leading 'v' if present
    v1="${v1#v}"
    v2="${v2#v}"

    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi

    local IFS='.'
    local i
    read -ra V1 <<< "$v1"
    read -ra V2 <<< "$v2"

    # Compare each component
    for ((i=0; i<3; i++)); do
        local n1="${V1[i]:-0}"
        local n2="${V2[i]:-0}"

        # Remove any non-numeric suffix (e.g., "1-beta" -> "1")
        n1="${n1%%[^0-9]*}"
        n2="${n2%%[^0-9]*}"

        if ((n1 > n2)); then
            return 1
        elif ((n1 < n2)); then
            return 2
        fi
    done

    return 0
}

# Check if an update is available (with caching)
# Sets global variables: UPDATE_AVAILABLE, LATEST_VERSION
# Returns: 0 if update check succeeded, 1 on failure
check_for_updates() {
    local current_version="${VERSION:-0.0.0}"
    local cache_file
    cache_file="$(_get_version_cache_file)"
    local now
    now=$(date +%s)

    # Check cache first
    if [[ -f "$cache_file" ]]; then
        local cached_time cached_version
        read -r cached_time cached_version < "$cache_file" 2>/dev/null || true

        if [[ -n "$cached_time" && -n "$cached_version" ]]; then
            local age=$((now - cached_time))
            if ((age < N8N_GIT_UPDATE_CHECK_INTERVAL)); then
                LATEST_VERSION="$cached_version"
                compare_versions "$current_version" "$cached_version"
                local cmp_result=$?
                if ((cmp_result == 2)); then
                    UPDATE_AVAILABLE=true
                else
                    UPDATE_AVAILABLE=false
                fi
                return 0
            fi
        fi
    fi

    # Fetch latest version from GitHub
    local latest
    if ! latest=$(get_latest_release_version); then
        UPDATE_AVAILABLE=false
        LATEST_VERSION=""
        return 1
    fi

    LATEST_VERSION="$latest"

    # Cache the result
    echo "$now $latest" > "$cache_file" 2>/dev/null || true

    # Compare versions
    local cmp_result=0
    compare_versions "$current_version" "$latest" || cmp_result=$?
    if ((cmp_result == 2)); then
        UPDATE_AVAILABLE=true
    else
        UPDATE_AVAILABLE=false
    fi

    return 0
}

# Show update notification if an update is available
# This should be called early in the main flow
show_update_notification() {
    # Skip update check if explicitly disabled
    if [[ "${N8N_GIT_DISABLE_UPDATE_CHECK:-}" == "true" ]]; then
        return 0
    fi

    # Skip update check in non-interactive/CI environments
    if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        return 0
    fi

    # Run check in background to avoid slowing down startup
    # But if we already have cached data, show it immediately
    local cache_file
    cache_file="$(_get_version_cache_file)"

    if [[ -f "$cache_file" ]]; then
        check_for_updates
        if [[ "$UPDATE_AVAILABLE" == "true" && -n "$LATEST_VERSION" ]]; then
            echo ""
            log INFO "${YELLOW}Update available:${NC} v${VERSION} -> v${LATEST_VERSION}"
            log INFO "Run '${BOLD}n8n-git update${NC}' to install the latest version."
            echo ""
        fi
    else
        # Trigger background check for next time (don't block)
        # Use disown to properly detach the background process
        (check_for_updates &
        disown) 2>/dev/null || true
    fi
}

# Detect the installation type and paths
# Sets: INSTALL_TYPE (system|user|dev), INSTALL_BINDIR, INSTALL_SHAREDIR
detect_installation() {
    local script_path
    script_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    local script_dir
    script_dir="$(dirname "$script_path")"

    # Check if we're in a development environment (lib/utils/version.sh)
    if [[ "$script_dir" == */lib/utils ]]; then
        local parent_dir
        parent_dir="$(dirname "$(dirname "$script_dir")")"
        if [[ -f "$parent_dir/n8n-git.sh" && -d "$parent_dir/lib" ]]; then
            INSTALL_TYPE="dev"
            INSTALL_BINDIR="$parent_dir"
            INSTALL_SHAREDIR="$parent_dir"
            return 0
        fi
    fi

    # Check common installation paths
    if [[ -f "/usr/local/bin/n8n-git" ]]; then
        INSTALL_TYPE="system"
        INSTALL_BINDIR="/usr/local/bin"
        INSTALL_SHAREDIR="/usr/local/share/n8n-git"
    elif [[ -f "/usr/bin/n8n-git" ]]; then
        INSTALL_TYPE="system"
        INSTALL_BINDIR="/usr/bin"
        INSTALL_SHAREDIR="/usr/share/n8n-git"
    elif [[ -f "$HOME/.local/bin/n8n-git" ]]; then
        INSTALL_TYPE="user"
        INSTALL_BINDIR="$HOME/.local/bin"
        INSTALL_SHAREDIR="$HOME/.local/share/n8n-git"
    else
        # Try to detect from LIB_DIR
        if [[ -n "${LIB_DIR:-}" ]]; then
            if [[ "$LIB_DIR" == /usr/local/share/* ]]; then
                INSTALL_TYPE="system"
                INSTALL_BINDIR="/usr/local/bin"
                INSTALL_SHAREDIR="/usr/local/share/n8n-git"
            elif [[ "$LIB_DIR" == /usr/share/* ]]; then
                INSTALL_TYPE="system"
                INSTALL_BINDIR="/usr/bin"
                INSTALL_SHAREDIR="/usr/share/n8n-git"
            elif [[ "$LIB_DIR" == "$HOME"/.local/* ]]; then
                INSTALL_TYPE="user"
                INSTALL_BINDIR="$HOME/.local/bin"
                INSTALL_SHAREDIR="$HOME/.local/share/n8n-git"
            else
                INSTALL_TYPE="dev"
                INSTALL_BINDIR="$(dirname "${LIB_DIR}")"
                INSTALL_SHAREDIR="$(dirname "${LIB_DIR}")"
            fi
        else
            INSTALL_TYPE="unknown"
            INSTALL_BINDIR=""
            INSTALL_SHAREDIR=""
        fi
    fi

    return 0
}

# Perform self-update
# Downloads the latest release and installs it
perform_update() {
    local dry_run="${1:-false}"
    local target_version="${2:-}"  # Optional specific version

    # Detect current installation
    detect_installation

    if [[ "$INSTALL_TYPE" == "unknown" ]]; then
        log ERROR "Unable to detect n8n-git installation type."
        log INFO "Please reinstall using one of the supported methods:"
        log INFO "  System install: curl -sSL https://raw.githubusercontent.com/${N8N_GIT_REPO}/main/install.sh | sudo bash"
        log INFO "  User install:   curl -sSL https://raw.githubusercontent.com/${N8N_GIT_REPO}/main/install.sh | PREFIX=\$HOME/.local bash"
        return 1
    fi

    if [[ "$INSTALL_TYPE" == "dev" ]]; then
        log WARN "Development installation detected at: $INSTALL_BINDIR"
        log INFO "For development installations, use 'git pull' to update."
        log INFO "Alternatively, run 'make install' after pulling updates."

        # Check if this is a git repository
        if [[ -d "$INSTALL_BINDIR/.git" ]]; then
            log INFO ""
            log INFO "To update your development installation:"
            log INFO "  cd $INSTALL_BINDIR && git pull origin main"
            return 0
        fi
        return 1
    fi

    # Determine the version to install
    local source_ref="main"
    if [[ -n "$target_version" ]]; then
        # Validate version string before using it in URL construction
        if ! is_valid_version "$target_version"; then
            log ERROR "Invalid version format: $target_version"
            log INFO "Version must be in semantic version format (e.g., 1.2.3 or v1.2.3)"
            return 1
        fi
        source_ref="v${target_version#v}"
        log INFO "Installing specific version: $source_ref"
    else
        # Get latest release version
        if ! check_for_updates; then
            log ERROR "Failed to check for updates. Check your network connection."
            return 1
        fi

        if [[ "$UPDATE_AVAILABLE" != "true" ]]; then
            log SUCCESS "You are already running the latest version (v${VERSION})."
            return 0
        fi

        source_ref="v${LATEST_VERSION}"
        log INFO "Updating from v${VERSION} to v${LATEST_VERSION}..."
    fi

    # Check write permissions
    local needs_sudo=false
    if [[ "$INSTALL_TYPE" == "system" ]]; then
        if [[ ! -w "$INSTALL_BINDIR" ]] || [[ ! -w "$(dirname "$INSTALL_SHAREDIR")" ]]; then
            needs_sudo=true
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        log WARN "DRY RUN - Would perform the following:"
        log INFO "  Download: https://github.com/${N8N_GIT_REPO}/archive/refs/tags/${source_ref}.tar.gz"
        log INFO "  Install binary to: $INSTALL_BINDIR/n8n-git"
        log INFO "  Install libraries to: $INSTALL_SHAREDIR/lib"
        if [[ "$needs_sudo" == "true" ]]; then
            log INFO "  (Would require sudo for system installation)"
        fi
        return 0
    fi

    # Create temporary directory
    local workdir
    workdir=$(mktemp -d)
    # shellcheck disable=SC2064 # We want to expand workdir now because it is local
    trap "rm -rf \"$workdir\"" EXIT

    # Download the release
    local archive_url="https://github.com/${N8N_GIT_REPO}/archive/refs/tags/${source_ref}.tar.gz"
    local archive_path="$workdir/n8n-git.tar.gz"

    log INFO "Downloading $source_ref..."
    if ! curl -fsSL "$archive_url" -o "$archive_path" 2>/dev/null; then
        # Try heads/ instead of tags/ (for main branch)
        archive_url="https://github.com/${N8N_GIT_REPO}/archive/refs/heads/${source_ref#v}.tar.gz"
        if ! curl -fsSL "$archive_url" -o "$archive_path" 2>/dev/null; then
            log ERROR "Failed to download release. Check your network connection."
            return 1
        fi
    fi

    # Extract the archive
    log INFO "Extracting..."
    if ! tar -xzf "$archive_path" -C "$workdir" 2>/dev/null; then
        log ERROR "Failed to extract archive."
        return 1
    fi

    # Find extracted directory
    local source_dir
    source_dir=$(find "$workdir" -mindepth 1 -maxdepth 1 -type d -name 'n8n-git-*' | head -n1)
    if [[ -z "$source_dir" ]]; then
        log ERROR "Unable to locate extracted source directory."
        return 1
    fi

    # Perform installation
    log INFO "Installing to $INSTALL_BINDIR..."

    local install_cmd=""
    if [[ "$needs_sudo" == "true" ]]; then
        if command -v sudo >/dev/null 2>&1; then
            install_cmd="sudo"
            log INFO "Using sudo for system installation..."
        else
            log ERROR "System installation requires root privileges. Please run with sudo."
            return 1
        fi
    fi

    # Install binary
    if ! $install_cmd install -d "$INSTALL_BINDIR" 2>/dev/null; then
        log ERROR "Failed to create $INSTALL_BINDIR"
        return 1
    fi

    if ! $install_cmd install -m 755 "$source_dir/n8n-git.sh" "$INSTALL_BINDIR/n8n-git" 2>/dev/null; then
        log ERROR "Failed to install n8n-git binary."
        return 1
    fi

    # Install libraries
    if ! $install_cmd install -d "$INSTALL_SHAREDIR" 2>/dev/null; then
        log ERROR "Failed to create $INSTALL_SHAREDIR"
        return 1
    fi

    $install_cmd rm -rf "$INSTALL_SHAREDIR/lib" 2>/dev/null || true
    if ! $install_cmd mkdir -p "$INSTALL_SHAREDIR/lib" 2>/dev/null; then
        log ERROR "Failed to create library directory."
        return 1
    fi

    if ! $install_cmd cp -R "$source_dir/lib/." "$INSTALL_SHAREDIR/lib/" 2>/dev/null; then
        log ERROR "Failed to install library files."
        return 1
    fi

    # Clear version cache
    local cache_file
    cache_file="$(_get_version_cache_file)"
    rm -f "$cache_file" 2>/dev/null || true

    log SUCCESS "n8n-git has been updated successfully!"
    log INFO "Binary: $INSTALL_BINDIR/n8n-git"
    log INFO "Libraries: $INSTALL_SHAREDIR/lib"

    # Show what version we updated to
    local new_version
    new_version=$(grep '^VERSION=' "$INSTALL_BINDIR/n8n-git" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    log SUCCESS "Now running version: v${new_version}"

    return 0
}

# Show version information
show_version_info() {
    local current="${VERSION:-unknown}"

    echo "n8n-git version $current"
    echo ""

    detect_installation
    echo "Installation type: $INSTALL_TYPE"
    if [[ -n "$INSTALL_BINDIR" ]]; then
        echo "Binary location: $INSTALL_BINDIR/n8n-git"
    fi
    if [[ -n "$INSTALL_SHAREDIR" ]]; then
        echo "Library location: $INSTALL_SHAREDIR/lib"
    fi
    echo ""

    echo "Checking for updates..."
    if check_for_updates; then
        if [[ "$UPDATE_AVAILABLE" == "true" ]]; then
            echo ""
            echo "Update available: v${current} -> v${LATEST_VERSION}"
            echo "Run 'n8n-git update' to install the latest version."
        else
            echo "You are running the latest version."
        fi
    else
        echo "Unable to check for updates (network error or rate limited)."
    fi
}
