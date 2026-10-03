#!/usr/bin/env bash
# Idempotentna konfiguracja repo. Uruchamiac PO zmergowaniu deploy.yml na main.
set -euo pipefail
: "${REPO:?}" "${REGION:?}" "${DEV_ACCOUNT:?}" "${PROD_ACCOUNT:?}" "${GENERAL_ACCOUNT:?}"

echo "== zmienne repo"
gh variable set AWS_REGION         --repo "$REPO" --body "$REGION"
gh variable set DEV_ACCOUNT_ID     --repo "$REPO" --body "$DEV_ACCOUNT"
gh variable set PROD_ACCOUNT_ID    --repo "$REPO" --body "$PROD_ACCOUNT"
gh variable set GENERAL_ACCOUNT_ID --repo "$REPO" --body "$GENERAL_ACCOUNT"

echo "== repo: squash + merge commit, bez rebase, kasuj galezie po merge"
gh api -X PATCH "repos/$REPO" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=true -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=false

echo "== Actions: PR z forka czeka na reczne Approve and run; token read-only"
gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --silent -f approval_policy=all_external_contributors
gh api -X PUT "repos/$REPO/actions/permissions/workflow" --silent -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

echo "== env dev: bez reviewera, tylko z galezi dev"
gh api -X PUT "repos/$REPO/environments/dev" --silent --input - <<'EOF'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
EOF
gh api "repos/$REPO/environments/dev/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx dev \
  || gh api -X POST "repos/$REPO/environments/dev/deployment-branch-policies" --silent -f name=dev -f type=branch

echo "== env prod: TY jako reviewer, tylko chronione galezie (= main)"
MY_ID=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/prod" --silent --input - <<EOF
{ "wait_timer": 0, "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": $MY_ID } ],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false } }
EOF

# PR wymagany, 0 approvali (autor nie moze zatwierdzic wlasnego PR-a). Bez required checks -
# nic nie odpala sie na pull_request. Bramka PROD = reviewer srodowiska.
protect() {
  local branch=$1 linear=$2
  gh api -X PUT "repos/$REPO/branches/$branch/protection" --silent --input - <<EOF
{ "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "required_linear_history": $linear,
  "allow_force_pushes": false,
  "allow_deletions": false }
EOF
}
echo "== ochrona dev (linear: squash)";       protect dev true
echo "== ochrona main (merge commit)";         protect main false

echo "== weryfikacja"
for b in dev main; do
  gh api "repos/$REPO/branches/$b/protection" --jq "{branch: \"$b\", admins: .enforce_admins.enabled, linear: .required_linear_history.enabled, pr: .required_pull_request_reviews.required_approving_review_count}"
done
gh api "repos/$REPO/actions/permissions/fork-pr-contributor-approval"