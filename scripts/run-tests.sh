#!/usr/bin/env bash
# Run unit tests for all Function Apps and Python apps.
# Each app is tested in its own subprocess to avoid function_app module
# name collisions across apps (each app has a function_app.py entry point).
#
# Usage:
#   ./scripts/run-tests.sh            # unit tests only
#   ./scripts/run-tests.sh --cov      # unit tests with coverage per app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS=(crash-classifier telemetry-writer notifier metrics simulator consumer)
COV_FLAG=""
[[ "${1:-}" == "--cov" ]] && COV_FLAG="--cov --cov-report=term-missing"

PASS=0
FAIL=0
ERRORS=()

for app in "${APPS[@]}"; do
  app_dir="${REPO_ROOT}/apps/${app}"
  echo ""
  echo "━━━  ${app}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if python3 -m pytest "${app_dir}/tests/" -v ${COV_FLAG} \
      --rootdir="${app_dir}"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("${app}")
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Failed apps: ${ERRORS[*]}"
  exit 1
fi
