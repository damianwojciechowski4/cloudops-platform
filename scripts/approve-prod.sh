#!/usr/bin/env bash
# approve-prod.sh [run-id]  - zatwierdza oczekujacy deployment prod (domyslnie: najnowszy waiting run na main)
set -euo pipefail
: "${REPO:?}"
RUN_ID=${1:-$(gh run list --repo "$REPO" --branch main --status waiting --json databaseId --jq '.[0].databaseId')}
[[ -n "$RUN_ID" ]] || { echo "Brak runa czekajacego na approval." >&2; exit 1; }
ENV_ID=$(gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" --jq '.[0].environment.id')
[[ -n "$ENV_ID" ]] || { echo "Run $RUN_ID nie ma pending deployment." >&2; exit 1; }
echo "Run: https://github.com/$REPO/actions/runs/$RUN_ID"
gh api -X POST "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" \
  -F "environment_ids[]=$ENV_ID" -f state=approved -f comment="approved via scripts/approve-prod.sh" --silent
gh run watch "$RUN_ID" --repo "$REPO"