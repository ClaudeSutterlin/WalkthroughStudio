#!/usr/bin/env bash
# The onboarding-research skill ships copies of two files that also live in this
# repository, so the skill folder can be installed anywhere on its own. Copies drift.
# This check fails when they do; run it in the verify loop.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
check() {
  if ! diff -q "$1" "$2" >/dev/null 2>&1; then
    echo "DRIFT: $1 differs from $2"
    status=1
  else
    echo "in sync: $2"
  fi
}
check docs/onboarding/PACKET.md .claude/skills/onboarding-research/reference/PACKET.md
check scripts/make-fixture-repo.sh .claude/skills/onboarding-research/scripts/make_fixture_repo.sh
exit $status
