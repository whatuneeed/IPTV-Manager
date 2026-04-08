#!/bin/sh
# ==========================================
# IPTV Manager — Test runner
# Runs all unit tests
# Usage: sh run_tests.sh  (or bash run_tests.sh)
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
TOTAL=0

echo "=========================================="
echo " IPTV Manager — Unit Test Suite"
echo "=========================================="
echo ""

run_test_file() {
    local file="$1"
    local name
    name=$(basename "$file")
    echo "── Running: $name ──"

    if [ ! -f "$file" ]; then
        echo "  SKIP: file not found"
        return
    fi

    # Run test, capture output
    local output
    output=$(bash "$file" 2>&1)
    local rc=$?

    echo "$output" | tail -3

    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))
    echo ""
}

for f in "$SCRIPT_DIR"/test_*.sh; do
    run_test_file "$f"
done

echo "=========================================="
echo " Results: $TOTAL suites, $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
