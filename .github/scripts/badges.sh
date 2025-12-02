#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

README_FILE="README.md"
SCRIPT_FILE="n8n-git.sh"

# --- Configuration & Dynamic Data --- 
# Attempt to get version from script file
SCRIPT_VERSION=""
if grep -qE '^VERSION=' "$SCRIPT_FILE" 2>/dev/null; then
    SCRIPT_VERSION=$(grep -E '^VERSION=' "$SCRIPT_FILE" | head -1 | cut -d'"' -f2)
fi

# GitHub repository details (owner/repo)
ORIGIN_URL=$(git config --get remote.origin.url || echo "")
if [[ "$ORIGIN_URL" =~ github.com[/:]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    OWNER_NAME="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
else
    echo "Error: Could not parse repository from git remote: $ORIGIN_URL" >&2
    exit 1
fi

GITHUB_REPO_SLUG="$OWNER_NAME/$REPO_NAME"
BADGE_STYLE="flat-square"

# --- Badge Definitions (HTML format) ---
LATEST_RELEASE_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG/releases/latest\"><img src=\"https://img.shields.io/github/v/release/$GITHUB_REPO_SLUG?style=$BADGE_STYLE\" alt=\"Latest Release\" /></a>"
LICENSE_BADGE="<a href=\"LICENSE\"><img src=\"https://img.shields.io/badge/License-MIT-yellow.svg?style=$BADGE_STYLE\" alt=\"MIT License\" /></a>"
STARS_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG/stargazers\"><img src=\"https://img.shields.io/github/stars/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github\" alt=\"GitHub Stars\" /></a>"
FORKS_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG/network/members\"><img src=\"https://img.shields.io/github/forks/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github\" alt=\"GitHub Forks\" /></a>"
CONTRIBUTORS_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG/graphs/contributors\"><img src=\"https://img.shields.io/github/contributors/$GITHUB_REPO_SLUG?style=$BADGE_STYLE\" alt=\"Contributors\" /></a>"
LAST_COMMIT_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG/commits/main\"><img src=\"https://img.shields.io/github/last-commit/$GITHUB_REPO_SLUG?style=$BADGE_STYLE\" alt=\"Last Commit\" /></a>"
STATUS_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG\"><img src=\"https://img.shields.io/badge/status-active-success.svg?style=$BADGE_STYLE\" alt=\"Status: Active\" /></a>"
VIEWS_BADGE="<a href=\"https://github.com/$GITHUB_REPO_SLUG\"><img src=\"https://komarev.com/ghpvc/?username=$OWNER_NAME&repo=$REPO_NAME&style=$BADGE_STYLE\" alt=\"Views\" /></a>"

# Compose badge block
ALL_BADGES_HTML="<p align=\"center\">
  $LATEST_RELEASE_BADGE
  $LICENSE_BADGE
  $STARS_BADGE
  $FORKS_BADGE
  $CONTRIBUTORS_BADGE
  $LAST_COMMIT_BADGE
  $STATUS_BADGE
  $VIEWS_BADGE
</p>"

# --- Update README ---
if [[ ! -f "$README_FILE" ]]; then
    echo "Error: README file not found: $README_FILE" >&2
    exit 1
fi

# Create temp file
TEMP_FILE=$(mktemp)

# Replace content between markers
awk -v badges="$ALL_BADGES_HTML" '
    /<!-- ALL_BADGES_START -->/ { print; print badges; in_section=1; next }
    /<!-- ALL_BADGES_END -->/ { in_section=0 }
    !in_section { print }
' "$README_FILE" > "$TEMP_FILE"

# Replace original file
mv "$TEMP_FILE" "$README_FILE"

echo "Updated badges in $README_FILE"
echo "Badges: Latest Release | License: MIT | GitHub Stars | GitHub Forks | Contributors | Last Commit | Status: Active | Views"
