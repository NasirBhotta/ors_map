#!/usr/bin/env bash
# Local Release Validation Script for mapbox_nav_core (Bash)
# Usage: ./tool/release_check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${SCRIPT_DIR}/../packages/mapbox_nav_core"
EXAMPLE_DIR="${PACKAGE_DIR}/example"

echo "=========================================="
echo "Starting mapbox_nav_core Release Pre-flight Checks"
echo "=========================================="

echo -e "\n[1/6] Checking code formatting..."
cd "${PACKAGE_DIR}"
dart format --output=none --set-exit-if-changed .
echo "Formatting clean!"

echo -e "\n[2/6] Running static analysis on package..."
cd "${PACKAGE_DIR}"
flutter analyze
echo "Package static analysis clean!"

echo -e "\n[3/6] Running package tests (unit & stress suites)..."
cd "${PACKAGE_DIR}"
flutter test test
echo "All package tests passed!"

echo -e "\n[4/6] Analyzing example application..."
cd "${EXAMPLE_DIR}"
flutter pub get
flutter analyze
flutter test
echo "Example app clean and tested!"

echo -e "\n[5/6] Validating package publish archive (dry-run)..."
cd "${PACKAGE_DIR}"
dart pub publish --dry-run
echo "Publish dry-run succeeded!"

echo "=========================================="
echo "ALL PRE-RELEASE CHECKS PASSED SUCCESSFULLY!"
echo "=========================================="
