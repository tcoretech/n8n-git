#!/usr/bin/env bash
# =========================================================
# Changelog Generator for n8n Git
# Uses Keep a Changelog format
# =========================================================
set -euo pipefail

CHANGELOG_FILE="CHANGELOG.md"
NEW_VERSION="${1:-$(grep '^VERSION=' n8n-git.sh | cut -d'"' -f2)}"
RELEASE_DATE=$(date +%Y-%m-%d)

# Get the previous version tag
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

# Generate commit log
if [ -n "$PREV_TAG" ]; then
  COMMIT_LOG=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" --no-merges)
else
  COMMIT_LOG=$(git log --pretty=format:"- %s" --no-merges)
fi

# Categorize commits by conventional commit type
FEATURES=$(echo "$COMMIT_LOG" | grep "^- feat" | sed 's/^- feat[:(]/- /' | sed 's/^- feat: /- /' || true)
FIXES=$(echo "$COMMIT_LOG" | grep "^- fix" | sed 's/^- fix[:(]/- /' | sed 's/^- fix: /- /' || true)
DOCS=$(echo "$COMMIT_LOG" | grep "^- docs" | sed 's/^- docs[:(]/- /' | sed 's/^- docs: /- /' || true)
CHORE=$(echo "$COMMIT_LOG" | grep "^- chore" | sed 's/^- chore[:(]/- /' | sed 's/^- chore: /- /' || true)
OTHER=$(echo "$COMMIT_LOG" | grep -v "^- \(feat\|fix\|docs\|chore\)" || true)

# Read existing changelog
if [ -f "$CHANGELOG_FILE" ]; then
  EXISTING_CHANGELOG=$(tail -n +8 "$CHANGELOG_FILE")
else
  EXISTING_CHANGELOG=""
fi

# Generate new changelog entry
cat > "$CHANGELOG_FILE" << EOF
# Changelog

All notable changes to n8n Git will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [${NEW_VERSION}] - ${RELEASE_DATE}

EOF

# Add sections only if they have content
if [ -n "$FEATURES" ]; then
  echo "### Added" >> "$CHANGELOG_FILE"
  echo "$FEATURES" >> "$CHANGELOG_FILE"
  echo "" >> "$CHANGELOG_FILE"
fi

if [ -n "$FIXES" ]; then
  echo "### Fixed" >> "$CHANGELOG_FILE"
  echo "$FIXES" >> "$CHANGELOG_FILE"
  echo "" >> "$CHANGELOG_FILE"
fi

if [ -n "$DOCS" ]; then
  echo "### Documentation" >> "$CHANGELOG_FILE"
  echo "$DOCS" >> "$CHANGELOG_FILE"
  echo "" >> "$CHANGELOG_FILE"
fi

if [ -n "$CHORE" ]; then
  echo "### Maintenance" >> "$CHANGELOG_FILE"
  echo "$CHORE" >> "$CHANGELOG_FILE"
  echo "" >> "$CHANGELOG_FILE"
fi

if [ -n "$OTHER" ]; then
  echo "### Other Changes" >> "$CHANGELOG_FILE"
  echo "$OTHER" >> "$CHANGELOG_FILE"
  echo "" >> "$CHANGELOG_FILE"
fi

# Append existing changelog
if [ -n "$EXISTING_CHANGELOG" ]; then
  echo "$EXISTING_CHANGELOG" >> "$CHANGELOG_FILE"
fi

echo "Changelog updated for version ${NEW_VERSION}"
