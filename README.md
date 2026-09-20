# cloudops-platform

**Platform repo:** `damianwojciechowski4/cloudops-platform` (public, `main`, protected)
**Sandbox repo:** `damianwojciechowski4/AWS-Projects` (unprotected, experiments)
**Region:** `eu-central-1` · **Budget:** 6–10 h/week · < 5 USD/month per account

---

## Status

Implementation follows a simplified plan: one bootstrap stack per account, two roles (`cicd-deploy-<env>`, `cicd-cfn-exec-<env>`), CloudFormation + SAM only — no Terraform.

| | State |
|---|---|
| Tooling (`aws`, `sam`, `gh`, `cfn-lint`) | done |
| AWS accounts and SSO profiles | done |
| Repo `cloudops-platform`, `main` + `dev` branches, tool-first layout | done |
| Bootstrap OIDC (1 stack/account: provider, bucket, boundary, `cfn-exec`, `deploy`) | done on dev + prod |
| Canary (`cloudformation/networking/ssm-smoke`) | done |
| `discover-solutions.py` + tests (5 passed) | done |
| GH repo variables (`AWS_REGION`, `DEV_ACCOUNT_ID`, `PROD_ACCOUNT_ID`) | done |
| `deploy.yml` (`discover` + `deploy`, CFN + SAM) | done, first DEV deploy green |
| **SAM `hello` (Lambda smoke test)** | **← next step** |
| GitHub configuration (environments, branch protection, `approve-prod.sh`) | pending (week 3) |
| Full dev → main → prod run, negative tests N1–N8 | pending (week 3) |

**Known incidents:**

| Date | What | Cause | Fix |
|---|---|---|---|
| 2026-09-20 | First DEV deploy: `AccessDenied` on `iam:PassRole` (`deploy` → `cfn-exec`) | `CicdBoundary` → `DenyCicdIdentityTampering` used `Action: iam:*`, which also covered `PassRole`; an explicit deny in a permissions boundary always beats an explicit allow on the role | Narrowed the deny to actual tampering actions (Create/Update/Delete/Attach/Detach/Put on roles/policies), excluded `PassRole`/`Get*`/`List*`. Bootstrap redeployed on dev + prod. |
---

## 1. Reference: accounts, naming, solution paths

### Accounts

| Account | ID | Profile | Role |
|---|---|---|---|
| `GENERAL` | `$GENERAL_ACCOUNT` | `cloudops-general` | Organizations, SSO, billing, SCPs. **Zero workloads.** |
| `DEVELOPMENT` | `$DEV_ACCOUNT` | `cloudops-development` | dev environment |
| `PRODUCTION` | `$PROD_ACCOUNT` | `cloudops-production` | prod environment |

### Naming

| Type | Pattern | Example |
|---|---|---|
| Bootstrap stack | `cloudops-cicd-bootstrap` | one per account (env is a parameter, not a name suffix) |
| Deploy role (assumed by GitHub Actions) | `cloudops-cicd-deploy-<env>` | `cloudops-cicd-deploy-prod` |
| Exec role (assumed by CloudFormation) | `cloudops-cicd-cfn-exec-<env>` | shared by CloudFormation and SAM |
| Permissions boundary | `cloudops-cicd-boundary-<env>` | ceiling for everything the pipeline is and creates |
| Solution stack | `cloudops-<domain>-<name>-<env>` | `cloudops-net-ssm-smoke-dev` |
| Artifacts bucket | `cloudops-artifacts-<account-id>-<region>` | SAM build artifacts |

Environments are exclusively `dev` and `prod` — these strings are baked into the OIDC `sub` claim.

### Solution paths

Each deployable unit is a directory with a `.solution.yml` under `cloudformation/` or `sam/` (never under `foundation/` — that's bootstrap, deployed manually from a laptop).

| Solution | Path | `order` |
|---|---|---|
| CI/CD bootstrap (manual, not discovered) | `cloudformation/foundation/cicd-bootstrap` | — |
| Pipeline canary | `cloudformation/networking/ssm-smoke` | 10 |
| Lambda smoke test | `sam/networking/hello` | 20 |

---

## Conventions

- **Branches:** feature work always branches from `dev` (`feat/<domain>-<description>`), no environment suffixes — the environment is determined by where the branch lands, not by its name.
- **Merge:** `feat/* → dev` is always **squash** (linear `dev` history); `dev → main` is always **merge commit** (visible promotion points to prod).
- **Lambda exclusively through SAM** — never raw CloudFormation. SAM gives `sam build`/`sam deploy` with a code hash as the S3 key, so there's no manual artifact version bumping.
- **Working loop** (branch → dev → main → prod):

  ```bash
  git switch dev && git pull --ff-only
  git switch -c feat/net-<description>
  # change in one solution
  python3 scripts/discover-solutions.py dev HEAD          # sanity: 1 entry
  git commit -m "feat(net): <imperative description>"
  git push -u origin feat/net-<description>
  gh pr create --base dev --fill && gh pr merge --squash --delete-branch   # -> DEV deploy
  gh run watch
  gh pr create --base main --head dev --fill && gh pr merge --merge        # -> PROD deploy waits
  ./scripts/approve-prod.sh
  ```

---

## 2. How deployment works

- **OIDC, no long-lived credentials.** GitHub Actions authenticates to AWS via `sts:AssumeRoleWithWebIdentity`. The trust policy pins `sub` (owner ID + repo ID + environment) and `job_workflow_ref` (workflow file + branch) — nothing but `deploy.yml`, on the right branch, in the right GitHub environment, can assume the role.
- **Two roles per environment, split by what they're trusted to do:**
  - `cloudops-cicd-deploy-<env>` — assumed by GitHub Actions. Can only call `cloudformation:*` on `cloudops-*` stacks, `iam:PassRole` to the exec role (scoped to `iam:PassedToService: cloudformation.amazonaws.com`), and read/write the artifacts bucket.
  - `cloudops-cicd-cfn-exec-<env>` — assumed by the CloudFormation service. Can actually create resources (`PowerUserAccess` + scoped IAM for `cloudops-*` roles/policies), but is never assumed directly by CI.
- **A permissions boundary is attached to every role the pipeline creates**, capping what any of it can ever do — including a deny on touching the bootstrap stack itself and on removing the boundary.
- **`discover-solutions.py`** diffs the two commits behind a push and returns only the solutions (directories with `.solution.yml`) that changed, in `order`. The `deploy` job runs as a matrix over that list, `max-parallel: 1`.
- **`main` requires parity with `dev`** — before a solution deploys to prod, the workflow diffs that directory between `origin/dev` and the pushed commit. If they differ, the deploy fails: the change skipped promotion through dev.
- **Prod requires manual approval** via the GitHub `prod` environment's required reviewer (`scripts/approve-prod.sh` approves the pending deployment from the CLI).

---

## Foundation that stays

One OIDC provider per account · two CI/CD roles per account (`deploy`, `cfn-exec`) with a shared permissions boundary · artifacts bucket with `DeletionPolicy: Retain` · GitHub environments and branch protection.

Everything else — the canary, `hello`, and future solutions — is deletable and expected to be pruned once it's stopped earning its keep.

---

## Known tech debt

| Item | Why, for now | Payoff |
|---|---|---|
| No plan/change-set step before merge | simplicity; reviewer sees the code diff | `plan` job on `pull_request` with a read-only role |
| Parity check proves identity with `dev`, not success on `dev` | one-line check, no extra API calls | `assert-promoted.sh` against the Actions API |
| `PowerUserAccess` on `cfn-exec` | the boundary limits the blast radius | narrow it based on CloudTrail data |
| SSE-S3 instead of KMS; no org CloudTrail; no SCPs; bootstrap without a StackSet | 2 accounts, cost-conscious | later, if the platform grows past 2 accounts |
| No `cfn-guard`, no signed commits | simplicity | once there's a rule worth enforcing |
| Pipeline never deletes stacks | safer to do by hand for now | `workflow_dispatch` destroy job with approval |

---

## Roadmap (ideas, not committed work)

Beyond the current plan, possible future directions — none scheduled, no time estimates, revisit once the foundation above is boring and stable:

- Multi-account networking (transit gateway / hub-spoke egress) if a second workload account is added.
- A third top-level tool directory (`terraform/`) if a use case actually needs it — out of scope today.
- Service Catalog self-service products once there's more than one consumer of the platform.
- Tighter cost/observability tooling (Flow Logs analysis, drift detection) once there's something worth watching.
