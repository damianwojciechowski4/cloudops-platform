# Plan działań: cloudops-platform

**Repo platformy:** `damianwojciechowski4/cloudops-platform` (publiczne, `main`, pod ochroną)
**Repo piaskownica:** `damianwojciechowski4/AWS-Projects` (bez ochrony, eksperymenty)
**Region:** `eu-central-1` · **Budżet:** 6–10 h/tydzień · < 5 USD/mies. per konto

---

## Status

| | Stan |
|---|---|
| Narzędzia (`aws`, `sam`, `gh`, `cfn-lint`) | gotowe |
| Konta AWS i profile SSO | gotowe |
| Repo `cloudops-platform`, branch `main`, struktura tool-first | gotowe |
| **Bootstrap OIDC (6 stacków)** | **← następny krok** |
| Konfiguracja GitHuba (środowiska, ochrona, zmienne) | do zrobienia |
| Workflowy i pierwszy przelot | do zrobienia |

---

## 1. Referencja: konta, nazwy, ścieżki

### Konta

| Konto | ID | Profil | Rola |
|---|---|---|---|
| `GENERAL` | `$GENERAL_ACCOUNT` | `cloudops-general` | Organizations, SSO, billing, SCP. **Zero workloadów.** |
| `DEVELOPMENT` | `$DEVELOPMENT_ACCOUNT` | `cloudops-development` | środowisko dev |
| `PRODUCTION` | `$PRODUCTION_ACCOUNT` | `cloudops-production` | środowisko prod + hub sieciowy |



### Nazwy

| Typ | Wzorzec | Przykład |
|---|---|---|
| Rola plan | `cloudops-cicd-<tool>-plan-<env>` | `cloudops-cicd-tf-plan-prod` |
| Rola apply/deploy | `cloudops-cicd-<tool>-apply-<env>` | `cloudops-cicd-tf-apply-prod` |
| Rola wykonawcza CFN | `cloudops-cicd-cfn-exec-<env>` | wspólna dla CFN i SAM |
| Stack bootstrapu | `cloudops-cicd-bootstrap-<tool>` | `cloudops-cicd-bootstrap-sam` |
| Stack komponentu | `cloudops-<domena>-<nazwa>-<env>` | `cloudops-net-vpc-prod` |
| Bucket stanu | `cloudops-tfstate-<account-id>-<region>` | — |
| Bucket artefaktów | `cloudops-artifacts-<account-id>-<region>` | — |
| Klucz stanu TF | `<domena>/<nazwa>/<env>/terraform.tfstate` | `networking/vpc/prod/terraform.tfstate` |

`<tool>` ∈ `tf`, `cfn`, `sam`. Środowiska wyłącznie `dev` i `prod` — te łańcuchy są wbudowane w claim `sub`.

### Ścieżki rozwiązań

| Rozwiązanie | Ścieżka | `order` |
|---|---|---|
| VPC | `terraform/networking/vpc` | 10 |
| TGW | `terraform/networking/tgw` | 20 |
| Egress | `terraform/networking/egress` | 25 |
| Route 53 Resolver | `terraform/networking/resolver` | 30 |
| EC2 | `terraform/platform/ec2` | 50 |
| ALB | `terraform/platform/alb` | 55 |
| Flow Logs | `terraform/observability/flow-logs` | 80 |
| Produkt SC „VPC" | `cloudformation/service-catalog/products/vpc` | 10 |
| Lambda IPAM | `sam/networking/ipam-allocator` | 10 |

---

## SPRINT 1 — Fundament CI/CD (W1–W2)

### Tydzień 1 — Bootstrap, 6 stacków

Szablon `cloudformation/foundation/cicd-bootstrap/template.yaml` przyjmuje parametry:

| Parametr | Rola |
|---|---|
| `GitHubRepo` | `damianwojciechowski4/cloudops-platform` |
| `EnvName` | `dev` \| `prod` — wchodzi w claim `sub` |
| `NamePrefix` | `cloudops` |
| `ToolShort` | `tf` \| `cfn` \| `sam` — wchodzi w nazwy ról |
| `WorkflowFile` | `terraform.yml` \| `cloudformation.yml` \| `sam.yml` — wchodzi w `job_workflow_ref` |
| `CreateShared` | `true` tylko przy pierwszym przebiegu na koncie (provider OIDC, buckety) |

Trust policy roli apply — dwa claimy naraz:

```yaml
Condition:
  StringEquals:
    token.actions.githubusercontent.com:aud: sts.amazonaws.com
    token.actions.githubusercontent.com:sub: !Sub 'repo:${GitHubRepo}:environment:${EnvName}'
    token.actions.githubusercontent.com:job_workflow_ref: !Sub
      '${GitHubRepo}/.github/workflows/${WorkflowFile}@refs/heads/main'
```

Zasoby współdzielone (`CreateShared=true`) owinięte w `Condition` i z `DeletionPolicy: Retain`: provider OIDC, `cloudops-tfstate-*`, `cloudops-artifacts-*`, rola `cloudops-cicd-cfn-exec-<env>`.

**Pre-flight, obowiązkowo:**

```bash
assert_account() {
  local p=$1 e=$2 a
  a=$(aws sts get-caller-identity --profile "$p" --query Account --output text)
  [[ "$a" == "$e" ]] || { echo "STOP: $p -> $a, oczekiwano $e"; return 1; }
  echo "OK: $p -> $a"
}
assert_account "$PROFILE_DEV" "$DEV_ACCOUNT"
assert_account "$PROFILE_PROD" "$PROD_ACCOUNT"
```

**Deploy:**

```bash
for PAIR in "$PROFILE_DEV:dev" "$PROFILE_PROD:prod"; do
  PROFILE="${PAIR%%:*}"; ENV="${PAIR##*:}"
  FIRST=true
  for TOOL in tf:terraform.yml cfn:cloudformation.yml sam:sam.yml; do
    SHORT="${TOOL%%:*}"; FILE="${TOOL##*:}"
    echo "=== $PROFILE / $ENV / $SHORT (shared=$FIRST) ==="
    aws cloudformation deploy \
      --profile "$PROFILE" --region "$REGION" \
      --stack-name "${PREFIX}-cicd-bootstrap-${SHORT}" \
      --template-file cloudformation/foundation/cicd-bootstrap/template.yaml \
      --capabilities CAPABILITY_NAMED_IAM \
      --no-fail-on-empty-changeset \
      --parameter-overrides \
          GitHubRepo="$REPO" EnvName="$ENV" NamePrefix="$PREFIX" \
          ToolShort="$SHORT" WorkflowFile="$FILE" CreateShared="$FIRST" \
      --tags Environment="$ENV" Domain=cicd ManagedBy=manual-cli Repo=cloudops-platform
    FIRST=false
  done
done
```

**Budżety z konta GENERAL:**

```bash
for PAIR in "development:$DEV_ACCOUNT" "production:$PROD_ACCOUNT"; do
  NAME="${PAIR%%:*}"; ACC="${PAIR##*:}"
  cat > /tmp/budget.json <<EOF
{ "BudgetName": "${PREFIX}-limit-${NAME}",
  "BudgetLimit": {"Amount": "5", "Unit": "USD"},
  "TimeUnit": "MONTHLY", "BudgetType": "COST",
  "CostFilters": { "LinkedAccount": ["$ACC"] } }
EOF
  aws budgets create-budget --profile "$PROFILE_GENERAL" \
    --account-id "$GENERAL_ACCOUNT" \
    --budget file:///tmp/budget.json \
    --notifications-with-subscribers file:///tmp/notif.json
done
```

**Weryfikacja:**

```bash
# Dokladnie jeden provider OIDC na konto
aws iam list-open-id-connect-providers --profile "$PROFILE_PROD"

# Oba claimy w roli produkcyjnej Terraforma, zero gwiazdek w sub
aws iam get-role --role-name cloudops-cicd-tf-apply-prod --profile "$PROFILE_PROD" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' --output json

# Trzy rozne job_workflow_ref w trzech rolach
for T in tf cfn sam; do
  echo -n "$T: "
  aws iam get-role --role-name "cloudops-cicd-${T}-apply-prod" --profile "$PROFILE_PROD" \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:job_workflow_ref"' \
    --output text
done
```

| Zadanie | Czas |
|---|---|
| `.envrc` + `direnv`, `assert_account` | 0,5 h |
| Szablon bootstrapu z 6 parametrami i `Condition` na zasobach współdzielonych | 3 h |
| Pętla 2 × 3, weryfikacja | 1,5 h |
| Budżety z GENERAL | 1 h |

**DoD W1:** sześć stacków `cloudops-cicd-bootstrap-{tf,cfn,sam}` zielonych; dokładnie jeden provider OIDC na konto; trzy role apply na prod mają trzy różne `job_workflow_ref`; w `GENERAL` nic poza budżetami.

### Tydzień 2 — GitHub, workflowy, pierwszy przelot

```bash
gh variable set AWS_REGION         --body "$REGION"
gh variable set DEV_ACCOUNT_ID     --body "$DEV_ACCOUNT"
gh variable set PROD_ACCOUNT_ID    --body "$PROD_ACCOUNT"
gh variable set GENERAL_ACCOUNT_ID --body "$GENERAL_ACCOUNT"

# srodowisko dev: tylko feat/* i main
gh api -X PUT "repos/$REPO/environments/dev" --input - <<'EOF'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
EOF
gh api -X POST "repos/$REPO/environments/dev/deployment-branch-policies" -f name='feat/*'
gh api -X POST "repos/$REPO/environments/dev/deployment-branch-policies" -f name='main'

# srodowisko prod: reviewer + tylko chronione branche
MY_ID=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/prod" --input - <<EOF
{ "wait_timer": 0,
  "reviewers": [{"type": "User", "id": $MY_ID}],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false } }
EOF

# ochrona main
gh api -X PUT "repos/$REPO/branches/main/protection" --input - <<'EOF'
{ "required_status_checks": { "strict": false, "contexts": ["prod-plan-gate"] },
  "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null,
  "allow_force_pushes": false, "allow_deletions": false, "required_linear_history": true }
EOF
```

**Filtry ścieżek — bootstrap musi być wykluczony:**

```yaml
# cloudformation.yml
on:
  push:
    branches: [main]
    paths:
      - 'cloudformation/**'
      - '!cloudformation/foundation/**'     # deploy z laptopa, nie z CI
```

Bez tego pipeline próbowałby wdrożyć bootstrap rolą, która z tego bootstrapu dopiero powstaje.

| Zadanie | Czas |
|---|---|
| Zmienne, środowiska, ochrona `main` przez `gh api` | 1 h |
| `scripts/discover-solutions.py` + test lokalny | 1 h |
| `terraform.yml` z jobami `discover` → `dev-apply` → `prod-plan` → `prod-plan-gate` → `prod-apply` | 2,5 h |
| `cloudformation.yml` i `sam.yml` jako warianty | 1,5 h |
| `scripts/approve-prod.sh` | 0,5 h |
| Pierwszy przelot: `aws_ssm_parameter` w `terraform/networking/vpc` | 2 h |
| Test negatywny: workflow SAM-a próbuje przyjąć rolę `cloudops-cicd-tf-apply-prod` | 1 h |

**DoD Sprintu 1:** commit z brancha `feat/net-vpc-init` przeszedł dev → PR → main → prod; `prod-apply` nie startuje po nieudanym `dev-apply`; `discover` wykrył wyłącznie zmienione rozwiązanie; jedyne kliknięcie to `gh auth login`.

**Post:** „Trzy toolchainy w jednym repo, trzy komplety ról OIDC — jak `job_workflow_ref` domyka monorepo".

---

## SPRINT 2 — VPC (W3–W4)

`terraform/networking/vpc`, `.solution.yml` z `order: 10`.

| Zadanie | Czas |
|---|---|
| Moduł VPC: subnety public/private per AZ, IGW, tabele tras, `for_each` po AZ | 3 h |
| Backend S3 `cloudops-tfstate-<acc>-eu-central-1`, `use_lockfile = true`, klucz `networking/vpc/<env>/terraform.tfstate` | 1,5 h |
| `envs/{dev,prod}` cienkie: tylko `backend.tf`, `providers.tf`, `main.tf`, `terraform.tfvars` | 1 h |
| Trivy `scan-type: config`, `exit-code: 1`, `severity: HIGH,CRITICAL` | 1 h |
| `default_tags`: `Environment`, `Domain`, `Component`, `ManagedBy`, `Repo` | 0,5 h |
| CIDR: dev `10.10.0.0/16`, prod `10.20.0.0/16` | 0,5 h |
| `terraform destroy` na dev na koniec tygodnia | 0,5 h |

**Bez NAT Gateway.**

**DoD:** `cloudops-net-vpc-dev` i `cloudops-net-vpc-prod` postawione wyłącznie pipelinem; zmiana w module przechodzi całą ścieżkę; `plan` na prod po apply zwraca exitcode 0.

**Post:** „Cienkie `envs/`, grube `modules/` — jak wymusić promocję strukturą repo".

---

## SPRINT 3 — Multi-account networking (W5–W6)

`terraform/networking/{tgw,egress}`, `order` 20 i 25 — kolejność wymuszona przez `discover`.

| Zadanie | Czas |
|---|---|
| Moduł TGW w `PRODUCTION` jako hubie + `aws_ram_resource_share` do `DEVELOPMENT` | 3 h |
| Attachmenty VPC z obu kont + akceptacja | 2 h |
| Segmentacja: osobne tabele tras TGW dla spoke i egress | 2 h |
| NAT w prod, trasa `0.0.0.0/0` z dev przez TGW | 2 h |
| Test przepływu potwierdzony w Flow Logs | 1,5 h |
| Diagram `docs/diagrams/hub-spoke.drawio` + eksport PNG | 1,5 h |
| **Destroy NAT tego samego dnia** | 0,5 h |

**Trade-off do README:** centralized egress oszczędza NAT-y, ale dokłada 0,02 USD/GB przez TGW w obie strony i tworzy pojedynczy punkt awarii. Policz próg względem NAT per konto.

**DoD:** pakiet z dev wychodzi przez NAT w prod, potwierdzony w Flow Logs; VPC wdraża się przed TGW dzięki `order`; po destroy koszt dzienny wraca do zera.

**Post:** „Centralized egress: kiedy się opłaca, a kiedy przepłacasz za transfer".

---

## SPRINT 4 — CloudFormation + SAM (W7–W8)

Pierwsze użycie dwóch pozostałych toolchainów. `cloudformation/service-catalog/` i `sam/networking/ipam-allocator/`.

| Zadanie | Czas |
|---|---|
| Portfolio + produkt „VPC" w `PRODUCTION`, share przez Organizations | 2 h |
| Launch role w `DEVELOPMENT` przez StackSet z GENERAL, constraint `LocalRoleName` | 2,5 h |
| Custom resource → Lambda w hubie (`AWS::Lambda::Permission` z `PrincipalOrgID`) | 3 h |
| Lambda SAM: alokacja CIDR, `cfnresponse` w `try/except`, idempotentny `Delete`, stabilny `PhysicalResourceId` | 3 h |
| `cfn-lint` + `cfn-guard` z regułą „VPC musi mieć Flow Logs" w `cloudformation.yml` | 1,5 h |
| `docs/solutions/self-service-vpc.md` spinający kawałki z trzech katalogów | 1 h |
| Test negatywny: rola z samym `servicecatalog:*` wyklikuje VPC; po odebraniu `s3:GetObject` — odmowa | 1 h |

**DoD:** użytkownik w `DEVELOPMENT` z wyłącznie `servicecatalog:*` tworzy VPC z CIDR-em od Lambdy z hubu; terminacja produktu zwraca CIDR; oba workflowy przeszły przez własne role.

**Post:** „Self-service VPC bez launch constraint to antywzorzec" — z diagramem łańcucha uprawnień.

---

## SPRINT 5 — Odporność i obserwowalność (W9–W10)

| Zadanie | Czas |
|---|---|
| Endpoint service + NLB w prod, endpoint interfejsowy w dev, test po prywatnym DNS | 3 h |
| Route 53 Resolver: inbound/outbound, reguły przez RAM (`order: 30`) | 3 h |
| Flow Logs w Parquet do S3, custom format z `pkt-srcaddr` i `tcp-flags` (`order: 80`) | 2 h |
| Athena: zapisane zapytania — top talkers, odrzucenia, ruch cross-AZ | 2 h |
| Alarmy: `BytesDropCountNoRoute` na TGW, błędy Lambdy hub | 1,5 h |
| Nocny drift detection: EventBridge + SNS | 2 h |

**DoD:** ruch dev → prod przez PrivateLink bez wyjścia do internetu; Athena zwraca top talkers z doby; nocny drift wykrywa ręczną zmianę w konsoli.

**Post:** „Flow Logs w Parquet i trzy zapytania Athena warte zapisania".

---

## SPRINT 6 — Skala i hardening (W11–W12)

| Zadanie | Czas |
|---|---|
| Bootstrap z pętli 2×3 do StackSetu na OU, delegacja na GENERAL | 3 h |
| **Zawężenie `cloudops-cicd-cfn-exec-*` z `PowerUserAccess`** na bazie CloudTrail / Access Analyzer | 3 h |
| IPAM: pula per środowisko, moduł VPC pobiera CIDR z IPAM zamiast ze zmiennej | 3 h |
| SCP na OU: blokada regionów spoza `eu-central-1` i `us-east-1` | 1,5 h |
| README per rozwiązanie + diagramy wyeksportowane do PNG | 3 h |
| Cost Explorer po tagach `Environment` i `ManagedBy` | 1 h |

**DoD:** nowe konto w OU dostaje role bez żadnej akcji; `cloudops-cicd-cfn-exec-prod` bez `PowerUserAccess`; każde rozwiązanie ma README z diagramem i szacunkiem kosztu.

**Post:** „Od PowerUserAccess do polityki z 40 akcjami — zawężanie na danych, nie na przeczuciu".

---

## Rytm tygodniowy

**Zestaw 60-minutowy, 3–4×/tydzień:** 20 min teoria (dokumentacja + notatka 5 zdań) · 30 min build/test (jeden commit, jeden PR, zielony pipeline) · 10 min notatka do README lub szkic posta.

**Blok weekendowy 2–4 h:** nowy moduł, debugowanie IAM, diagram.

**Pętla robocza:**

```bash
git switch main && git pull --ff-only
git switch -c feat/net-<opis>
# zmiana w modules/
python3 scripts/discover-solutions.py terraform main HEAD dev    # sanity check
git commit -m "feat(net): <opis w trybie rozkazujacym>"
git push -u origin feat/net-<opis>
gh run watch                                                     # DEV
gh pr create --base main --fill && gh pr checks --watch
gh pr view --comments                                            # plan PROD
gh pr merge --squash --delete-branch
gh run watch && ./scripts/approve-prod.sh                        # PROD
```

---

## KPI

| Metryka | Cel tygodniowy |
|---|---|
| Godziny | 6–10 |
| Merge'e do `main` | ≥ 2 |
| Zielone przeloty prod | ≥ 1 |
| Testy negatywne (celowa odmowa) | ≥ 1 |
| Posty | 2 |
| Koszt AWS | < 1,25 USD/tydzień/konto |
| Zasoby żyjące po niedzieli 20:00 | 0 poza fundamentem |

**Przegląd miesięczny, 30 min:** Cost Explorer po tagach, usunięcie zasobów z `ManagedBy=manual-cli`, aktualizacja README roota.

---

## Fundament, który zostaje na stałe

Provider OIDC (jeden na konto, obsługuje też AWS-Projects) · dziewięć ról CI/CD per konto · buckety stanu i artefaktów z `DeletionPolicy: Retain` · budżety i alarmy · środowiska i ochrona `main`.

Wszystko inne — VPC, TGW, NAT, endpointy — usuwalne jedną komendą i domyślnie usuwane na koniec sesji.

---

## Dług techniczny zaplanowany świadomie

| Pozycja | Spłata |
|---|---|
| `PowerUserAccess` na `cloudops-cicd-cfn-exec-*` | Sprint 6 |
| Bootstrap w pętli `for` zamiast StackSetu | Sprint 6 |
| CIDR ze zmiennej zamiast z IPAM | Sprint 6 |
| `strict: false` w required status checks | po ustabilizowaniu `prod-plan-gate` |

Wpisz to do `docs/tech-debt.md`. Rekruter czytający repo widzi wtedy świadome decyzje, nie przeoczenia.