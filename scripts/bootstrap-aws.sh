#!/usr/bin/env bash
# Deploy stacka bootstrapu na dev i prod. WYLACZNIE z laptopa. Wymaga: source .envrc, aws sso login.
set -euo pipefail
: "${DEV_ACCOUNT:?}" "${PROD_ACCOUNT:?}" "${PROFILE_DEV:?}" "${PROFILE_PROD:?}"
: "${REGION:?}" "${PREFIX:?}" "${GITHUB_OWNER:?}" "${GITHUB_OWNER_ID:?}" "${GITHUB_REPO_NAME:?}" "${GITHUB_REPO_ID:?}"

TEMPLATE="$(dirname "$0")/../cloudformation/foundation/cicd-bootstrap/template.yaml"

assert_account() {   # profil musi wskazywac na konto, ktore myslisz, ze wskazuje
  local profile=$1 expected=$2 actual
  actual=$(aws sts get-caller-identity --profile "$profile" --query Account --output text)
  [[ "$actual" == "$expected" ]] || { echo "STOP: $profile -> $actual, oczekiwano $expected" >&2; return 1; }
  echo "OK: $profile -> $actual"
}

deploy_bootstrap() {
  local profile=$1 env=$2 branch=$3
  echo "=== $profile / env=$env / branch=$branch ==="
  aws cloudformation deploy \
    --profile "$profile" --region "$REGION" \
    --stack-name "${PREFIX}-cicd-bootstrap" \
    --template-file "$TEMPLATE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides \
        GitHubOwner="$GITHUB_OWNER" GitHubOwnerId="$GITHUB_OWNER_ID" \
        GitHubRepoName="$GITHUB_REPO_NAME" GitHubRepoId="$GITHUB_REPO_ID" \
        EnvName="$env" NamePrefix="$PREFIX" DeployBranch="$branch" \
    --tags Environment="$env" Domain=cicd ManagedBy=manual-cli Repo="$GITHUB_REPO_NAME"
}

assert_account "$PROFILE_DEV"  "$DEV_ACCOUNT"
assert_account "$PROFILE_PROD" "$PROD_ACCOUNT"
deploy_bootstrap "$PROFILE_DEV"  dev  dev
deploy_bootstrap "$PROFILE_PROD" prod main
echo "Bootstrap gotowy."