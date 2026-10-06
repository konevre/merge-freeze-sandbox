#!/usr/bin/env bash
# Fails unless `merge-freeze` is a required status check on dev and staging, whichever ruleset requires it:
# without the requirement the status that merge-freeze.sh posts blocks nothing.
set -uo pipefail

: "${GH_REPO:?GH_REPO is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

err="$(mktemp)"
trap 'rm -f "$err"' EXIT

rc=0
for branch in dev staging; do
  if ! rules="$(gh api "repos/${GH_REPO}/rules/branches/${branch}" 2> "$err")"; then
    echo "::error::cannot read the rules of ${branch}: $(head -c 300 "$err")"
    rc=1
    continue
  fi
  if ! printf '%s' "$rules" | jq -e '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | index("merge-freeze")' > /dev/null; then
    echo "::error::merge-freeze is not a required status check on ${branch}"
    rc=1
  fi
done
exit "$rc"
