#!/usr/bin/env bash
# Enforce "all changes via pull request" on main. Run once per repo with gh authenticated as an admin.
# Usage: ./protect-main.sh <owner>/<repo> [required-check-names...]
set -euo pipefail

REPO="${1:?usage: $0 <owner>/<repo> [check names...]}"
shift || true

# Default required status checks: pass job names as args, e.g. "validate" "plan"
CHECKS_JSON=$(printf '%s\n' "$@" | jq -R . | jq -s '[.[] | select(length>0) | {context: .}]')

gh api -X PUT "repos/${REPO}/branches/main/protection" \
  --input - <<EOF
{
  "required_status_checks": {
    "strict": true,
    "checks": ${CHECKS_JSON}
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

echo "Branch protection applied to ${REPO}:main"
