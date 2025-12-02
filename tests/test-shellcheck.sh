#!/usr/bin/env bash
# =========================================================
# n8n Git - ShellCheck Linting
# =========================================================
# Validates shell scripts for common issues and best practices

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/utils/common-testbed.sh"

log HEADER "ShellCheck Analysis"
echo ""  # Maintain spacing before report output

# Find all shell scripts
MAIN_SCRIPT="$PROJECT_ROOT/n8n-git.sh"
INSTALL_SCRIPT="$PROJECT_ROOT/install.sh"
LIB_SCRIPTS=()
if [[ -d "$PROJECT_ROOT/lib" ]]; then
    while IFS= read -r -d '' file; do
        LIB_SCRIPTS+=("$file")
    done < <(find "$PROJECT_ROOT/lib" -name "*.sh" -print0 2>/dev/null || true)
fi

# Report file
REPORT="$PROJECT_ROOT/shellcheck-report.md"
echo "# n8n Git - ShellCheck Analysis Report" > "$REPORT"
echo "" >> "$REPORT"
echo "Generated: $(date)" >> "$REPORT"
echo "" >> "$REPORT"

TOTAL_ISSUES=0

# Check main script
log INFO "Analyzing n8n-git.sh..."
echo "## Main Script (n8n-git.sh)" >> "$REPORT"
echo '```' >> "$REPORT"
if shellcheck -f gcc -e SC1091 -e SC2034 -e SC2154 "$MAIN_SCRIPT" >> "$REPORT" 2>&1; then
    echo "✓ No issues found" >> "$REPORT"
    log SUCCESS "n8n-git.sh passed"
else
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    log ERROR "n8n-git.sh reported ShellCheck findings"
fi
echo '```' >> "$REPORT"
echo "" >> "$REPORT"

# Check install script
log INFO "Analyzing install.sh..."
echo "## Install Script (install.sh)" >> "$REPORT"
echo '```' >> "$REPORT"
if shellcheck -f gcc -e SC1091 "$INSTALL_SCRIPT" >> "$REPORT" 2>&1; then
    echo "✓ No issues found" >> "$REPORT"
    log SUCCESS "install.sh passed"
else
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    log ERROR "install.sh reported ShellCheck findings"
fi
echo '```' >> "$REPORT"
echo "" >> "$REPORT"

# Check library scripts
if ((${#LIB_SCRIPTS[@]} > 0)); then
    log INFO "Analyzing library modules..."
    echo "## Library Modules" >> "$REPORT"

    for lib in "${LIB_SCRIPTS[@]}"; do
        lib_name=$(basename "$lib")
    log INFO "  - $lib_name"
        echo "### $lib_name" >> "$REPORT"
        echo '```' >> "$REPORT"
        if shellcheck -f gcc -e SC1091 -e SC2034 -e SC2154 "$lib" >> "$REPORT" 2>&1; then
            echo "✓ No issues found" >> "$REPORT"
            log SUCCESS "$lib_name passed"
        else
            TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
            log ERROR "$lib_name reported ShellCheck findings"
        fi
        echo '```' >> "$REPORT"
        echo "" >> "$REPORT"
    done
fi

echo ""
log HEADER "ShellCheck Summary"
if [ "$TOTAL_ISSUES" -eq 0 ]; then
    log SUCCESS "All scripts passed ShellCheck"
    exit 0
else
    log ERROR "Found issues in $TOTAL_ISSUES script(s)"
    log INFO "See shellcheck-report.md for details"
    exit 0  # Don't fail CI on warnings
fi
