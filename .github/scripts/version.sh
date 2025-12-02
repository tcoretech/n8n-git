#!/usr/bin/env bash
# =========================================================
# Version Bump Script for n8n Git
# =========================================================
set -euo pipefail

# Get current version from main script
SCRIPT_FILE="n8n-git.sh"
CURRENT_VERSION=$(grep '^VERSION=' "$SCRIPT_FILE" | cut -d'"' -f2)

# Get version bump type from environment variable
BUMP_TYPE="${VERSION_BUMP_TYPE:-patch}"

# Parse current version
IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"

# Bump version based on type
case "$BUMP_TYPE" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
  *)
    echo "Error: Invalid bump type '$BUMP_TYPE'. Must be major, minor, or patch."
    exit 1
    ;;
esac

NEW_VERSION="${major}.${minor}.${patch}"

# Update version in script
sed -i "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" "$SCRIPT_FILE"

# Output for GitHub Actions
echo "new_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"
echo "Bumped version from $CURRENT_VERSION to $NEW_VERSION (type: $BUMP_TYPE)"
