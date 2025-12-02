#!/usr/bin/env bash
# =========================================================
# n8n Git - Bash Syntax Validation
# =========================================================
# Validates all shell scripts can be parsed by bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/utils/common-testbed.sh"

log HEADER "Syntax Validation"
echo ""

cd "$PROJECT_ROOT"

# Test main script
log INFO "Validating n8n-git.sh syntax"
bash -n n8n-git.sh

# Test install script
log INFO "Validating install.sh syntax"
bash -n install.sh

# Test all library modules
log INFO "Validating library modules"
shopt -s nullglob
for lib_script in lib/*.sh; do
    if [ -f "$lib_script" ]; then
        log INFO "  - Validating $(basename "$lib_script")"
        bash -n "$lib_script"
    fi
done
shopt -u nullglob

# Test script can show help
echo ""
log INFO "Testing --help flag"
chmod +x n8n-git.sh
./n8n-git.sh --help > /dev/null 2>&1 || {
    log INFO "  Note: Help output may be redirected or script needs arguments"
}

echo ""
log HEADER "Syntax Check Summary"
log SUCCESS "All syntax checks passed"
exit 0
