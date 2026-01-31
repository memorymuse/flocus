#!/usr/bin/env bash
#===============================================================================
# Run all vo tests (CLI + Extension)
# Can be run from any directory.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

cd "$PROJECT_ROOT"

echo ""
echo "================================"
echo "  vo Test Suite"
echo "================================"
echo ""

# Run CLI tests
echo ">>> CLI Integration Tests"
echo ""
if "$SCRIPT_DIR/test_cli.sh"; then
    CLI_RESULT=0
else
    CLI_RESULT=1
fi

echo ""
echo ">>> Extension Unit Tests"
echo ""

# Run extension tests
cd "$PROJECT_ROOT/extension"
if npm run test:unit 2>&1 | grep -E "(^#|ok [0-9]|not ok|tests|pass|fail)" | head -30; then
    EXT_RESULT=0
else
    EXT_RESULT=1
fi

echo ""
echo "================================"
if [[ $CLI_RESULT -eq 0 && $EXT_RESULT -eq 0 ]]; then
    echo -e "  ${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "  ${RED}Some tests failed${NC}"
    exit 1
fi
