# Azure Blob Storage smart tier automation

An audit-first Azure Automation runbook that enables **Azure Blob Storage smart tier**
(`properties.accessTier = Smart`) on eligible storage accounts that have explicitly opted in, one
bounded, verified wave at a time.

> **Not to be confused with** Azure Backup "Smart Tiering" (moving recovery points into the vault-archive
> tier), which is a different product with its own repository
> ([azure-backup-smart-tiering-automation](https://github.com/kevo099/azure-backup-smart-tiering-automation)).
> This runbook changes exactly one thing: a storage account's default blob access tier.

> **Status:** 1.0 is the runbook as published in the owner's Automation account on 2026-08-24 and exercised
> against an eight-account fixture; 1.1 is the hardening release produced by an adversarial multi-model
> review (see [CHANGELOG.md](CHANGELOG.md) and [docs/validation.md](docs/validation.md) for exactly what
> has and has not been proven live). The 2026-09-05 human walkthrough/helper review was validated offline;
> it did not repeat the Azure deployment. A [2026-09-06 live walkthrough test](docs/LIVE-TEST-2026-09-06.md)
> first found and corrected a release-pin error. Its second attempt passed all sixteen expected job outcomes,
> including guards, three named writes, full property comparisons, repeats, the lock and test-identity RBAC cleanup,
> with the recorded startup/propagation recoveries. Both test groups, their resources and the temporary operator
> grant were subsequently removed and verified absent.

## What smart tier does — and what it costs

Smart tier is an account-level default: block blobs land in **hot**, move to **cool** after 30 days without
access and to **cold** after 60 more, and return to hot when accessed. Azure manages the moves; there are no
transition, early-deletion or retrieval charges inside smart tier. Two things an approver must know:

- **Monitoring fee.** Azure charges a monthly monitoring fee per 10,000 objects larger than 128 KiB. The
  runbook cannot see object counts (control plane only); approve with your own inventory or metrics.
- **Leaving smart tier is not free.** Moving blobs *out* of smart tier costs one cool-write operation per
  object (blobs given an explicit tier never move and cannot return to Smart). "Undo" is a priced migration, never automatic.
- Blobs that carry an explicitly set tier are **not** enrolled by the account-level change; the first
  automatic move happens 30 days after enablement; redundancy can no longer be converted to LRS/GRS.

Prerequisites Azure enforces: Standard general-purpose v2 accounts with ZRS, GZRS or RA-GZRS; block blobs
only. Generally available in public-cloud regions; preview in Azure Government and 21Vianet.

## What the runbook does

| Account state | Audit result | Remediate behaviour |
|---|---|---|
| Not `StorageV2`, or SKU not ZRS/GZRS/RA-GZRS, or not `Succeeded` | `Skipped` (with reasons) | No write |
| Exclusion tag present (`SmartTierExclude`) | `SkippedExcluded` | No write — exclusion always wins |
| Opt-in tag missing or not matching `SmartTierManaged=true` | `SkippedNotOptedIn` (reason shows the value found) | No write |
| Already `Smart` | `AlreadySmart` | No write |
| A `ReadOnly` lock blocks the PATCH (`409 ScopeLocked`, Remediate only) | `BlockedScopeLock` | Not retried, never green: remove the lock deliberately and rerun |
| Eligible and opted in | `WouldRemediate` | `PATCH {"properties":{"accessTier":"Smart"}}`, verify by re-read → `Remediated` |

Writes only happen with `Mode=Remediate` — resource-group scope, **one named account per run** — after the whole scope has been classified, and only when the
preflight guards pass: no discovery errors, candidates ≤ `MaxChanges` (default **1**), candidates =
`ExpectedChanges` when set, opt-in enforced unless `AllowUntaggedRemediation` is set, the named account
eligible (a target that is neither `WouldRemediate` nor `AlreadySmart` aborts with `TargetNotEligible`; an
already-Smart target is the idempotent success), and public cloud unless `AllowNonPublicCloud` (honoured
only for the documented Azure Government / 21Vianet previews, which need feature registration).

Every write outcome is reported honestly: `Remediated` (verified), `BlockedScopeLock`,
`SkippedPreconditionChanged`, `Deferred` (a transient conflict — try the next run), `Failed`
(definitive), or `WriteOutcomeUnknown` (a lost response that re-reads could not resolve — the job fails
and nothing is resubmitted). A `403` on the first write aborts the rest of the run rather than failing
every account one by one.

## Repository contents

```text
src/Enable-AzStorageSmartTier.ps1         Azure Automation runbook (PowerShell 7.4, Az.Accounts)
infra/automation-account.bicep            Automation Account + PowerShell 7.4 runtime (Az pinned) + runbook imported from a release tag
infra/test-environment.bicep              Nine-account disposable fixture (optional ReadOnly lock)
infra/rbac/*.template.json                Discovery reader and remediator custom-role templates
tests/StaticValidation.ps1                Parser and safety-marker checks
tests/BehaviorHarness.ps1                 Behavioural harness: real runbook + mocked Az cmdlets (50 scenarios)
tests/RingRoleHarness.py                  Role-helper regression with mocked Azure CLI
scripts/publish-runbook.sh                Publish + link runtime + fetch-back hash check (release pipeline safe)
scripts/ring-role.sh                      Grant / revoke the ring-scoped remediator role
docs/replicate-in-azure.md                Step-by-step replication with the checkpoint expected at each step
docs/gotchas.md                           Everything that bit us — read before the first Remediate
docs/design-and-limitations.md            Method comparison, limitations, hardening status
docs/validation.md                        Sanitised live evidence for 1.0 and 1.1
CHANGELOG.md · LICENSE · SECURITY.md
.github/workflows/validate.yml            Static checks, harness, PSScriptAnalyzer, RBAC, Bicep CI
```

Raw subscription, tenant, principal and job identifiers and live account names are intentionally excluded.

> **Replicating this?** Follow [docs/replicate-in-azure.md](docs/replicate-in-azure.md) end to end and read
> [docs/gotchas.md](docs/gotchas.md) first. The sections below are the reference behind those two pages.

## Prerequisites and first deployment

Use **Bash** on Linux, WSL, or Azure Cloud Shell (Bash), with Git, jq, Python 3 and Azure CLI **2.87.0+**,
the `automation` extension, and Bicep. The guide includes installation checks, login, explicit subscription
selection, region/name choices and a private evidence directory. Local PowerShell **7.4** is needed only
for the offline PowerShell tests. Azure uses a PowerShell 7.4 runtime with **Az 12.3.0** pinned; review any
runtime/package change because it affects every linked runbook.

Follow [the numbered Azure walkthrough](docs/replicate-in-azure.md#0-tools-source-login-and-scope) from a
fresh source checkout. It deploys one dedicated Automation Account and nine empty storage accounts, runs
no-access and read-only checks, enables one named account, verifies the result, and removes writer access.
The fixture already tags its eligible test targets; you do not need to find or tag a production account.

The source checkout and runbook release are separate pins: `v1.1.0` contains the runbook but predates the
Automation Account template and helper scripts. Use the full source revision specified by the walkthrough;
Bicep imports the runbook from its separately pinned release commit. A local edit does not change the
remote import unless you change `sourceBaseUrl`/`sourceRef` or explicitly publish the local file.

The human needs Contributor for resource deployment and job operation, plus Owner/User Access Administrator
for custom roles at their assignable scopes and role assignments at the fixture group. Creating new groups
or registering providers also needs subscription-level permission, or an administrator must prepare them.
The walkthrough narrows both custom-role definitions to the fixture group. Using the checked-in reader
template's subscription-wide assignable scope unchanged requires role-definition permission there.

## RBAC model

Render both templates (`<subscription-id>`, and `<ring-resource-group>` for the remediator), create them with
`az role definition create --role-definition @<file>`, then assign to the Automation Account's
system-assigned identity — `scripts/ring-role.sh grant|revoke` does the remediator half:

- **Azure Storage Smart Tier Discovery Reader** (`storageAccounts/read`, subscription and resource-group
  reads) — at resource-group scope for `ScopeType=ResourceGroup`, at subscription scope only
  for subscription discovery.
- **Azure Storage Smart Tier Remediator** (`storageAccounts/read`, `storageAccounts/write`) —
  **only** at the resource group(s) of the current ring.

Be explicit about what the remediator is: `Microsoft.Storage/storageAccounts/write` is full account-update
authority (network rules, shared-key access, TLS, public access…); there is no field-level action for
`accessTier`, and ABAC conditions cannot inspect a control-plane PATCH body. The runbook only ever sends
`accessTier=Smart`, but anyone who can publish or start runbooks in the account can send anything with that
identity — keep the account dedicated, the assignment narrow and temporary, and treat "start runbook" as
writer-equivalent. Do **not** use built-in *Storage Account Contributor*: it also grants key access.

Also decide who may set the opt-in tag: tagging is consent, and a Tag Contributor can enrol an account
they could not otherwise change.

## Publish the runbook

The Bicep template creates the account, managed identity and runtime and publishes a release runbook.
For an update, `scripts/publish-runbook.sh` uploads a local file, links the runtime, publishes it and
compares the CLI fetch-back SHA-256. It requires an **existing** account and runtime. See
[step 1](docs/replicate-in-azure.md#1-automation-account-powershell-74-runtime-runbook) for the complete
command, region parameter and source-content checkpoint.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `Mode` | `Audit` | `Audit` or `Remediate` |
| `ScopeType` | `ResourceGroup` | `ResourceGroup` or `Subscription`; `Remediate` requires `ResourceGroup` |
| `SubscriptionId` | required | Target subscription — never inferred from the identity |
| `ResourceGroupName` | | Required for `ResourceGroup`; rejected for `Subscription` |
| `AccountName` | | Exact storage-account name. **Required for `Remediate`** (one account per run); optional filter for `Audit` |
| `RequireOptInTag` | `true` | Only accounts tagged `<RequiredTagName>=true` are candidates |
| `RequiredTagName` | `SmartTierManaged` | Opt-in tag name (matched case-insensitively, as Azure does). The consent value is fixed to `true` and compared exactly — Azure tag values are case-sensitive, so `True` is **not** consent; the reason string shows the value found |
| `ExclusionTagName` | `SmartTierExclude` | Any value present excludes the account |
| `AllowUntaggedRemediation` | `false` | Required to remediate with `RequireOptInTag=false` (the named account is written without the tag; the exclusion tag still wins) |
| `MaxChanges` | `1` | Preflight abort before the first write if more accounts would change (a named target yields at most one) |
| `ExpectedChanges` | `0` | Optional assertion (0 or 1 with a named target): if set and the account would change, the candidate count must equal it; an already-Smart target is not a mismatch |
| `JobTimeBudgetSeconds` | `8400` | No new write starts after this; the job fails closed with the remainder reported |
| `AllowNonPublicCloud` | `false` | Required to remediate outside public Azure; honoured only for Azure Government and 21Vianet (documented previews, feature registration required) — other environments are refused |

## Run audit first, then one account

Use [steps 3–7](docs/replicate-in-azure.md#3-start-a-job-and-read-its-result) for complete commands that
capture a job ID, wait, fetch output, check the last `SUMMARY`, verify the before/after account properties,
and repeat the job to prove idempotence. `az automation runbook start` only queues a job: its successful
exit does not prove `Completed` or `Remediated`.

Each write requires `Mode=Remediate`, `ScopeType=ResourceGroup`, the explicit subscription/resource group,
and one `AccountName`; use `ExpectedChanges=1 MaxChanges=1` for the first named write. The fixture's first
successful write should report `remediated=1`; its repeat should report `AlreadySmart` and `remediated=0`.
Revoke the writer after testing and verify remaining/inherited access. No recurring schedule is created;
if you schedule anything, schedule **Audit**.

## Policy or runbook?

The owner's earlier Azure Policy solution (DeployIfNotExists on the same eligibility) enforces smart tier
continuously on every eligible account, including new ones, with no opt-in. This runbook is the opposite:
bounded, opt-in, per-account evidence. Use Policy in `AuditIfNotExists` for standing compliance reporting and
this runbook for approved waves; run Policy `DeployIfNotExists` only if smart tier is mandatory
organisation-wide — and never both writers on the same scope.

## Teardown

Follow [step 9](docs/replicate-in-azure.md#9-teardown-the-dedicated-fixture): finish active jobs, remove only
the fixture lock, verify writer revocation, remove the exact reader assignment and unused definition,
then delete the dedicated groups and check that both are absent. Stop on any cleanup error. This deletes
the fixture accounts and Automation Account; use it only for the empty, exclusively owned demo resources.
Reverting a real account from Smart is a priced migration, not this teardown.

## Local validation

Run from the repository root. Install PowerShell 7.4 and PSScriptAnalyzer for the PowerShell checks;
Python 3, jq and Bicep are needed for the remaining checks. Installing the analyzer downloads a package:

```bash
pwsh -NonInteractive -NoProfile -Command 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Repository PSGallery -Force'
```

The checks below are offline and use mocked Az cmdlets/CLI; they do not log in, deploy, or start Azure jobs.
The behavior harness must be noninteractive because it intentionally omits a mandatory parameter once.

```bash
pwsh -NonInteractive -NoProfile -File tests/StaticValidation.ps1
pwsh -NonInteractive -NoProfile -File tests/BehaviorHarness.ps1 < /dev/null
pwsh -NonInteractive -NoProfile -Command '$findings = @(Invoke-ScriptAnalyzer -Path src/Enable-AzStorageSmartTier.ps1 -Severity Error,Warning); $findings; if ($findings.Count) { exit 1 }'
python3 tests/RingRoleHarness.py
for script in scripts/*.sh; do bash -n "$script"; done
jq empty infra/rbac/*.json
az bicep build --file infra/test-environment.bicep --stdout > /dev/null
az bicep build --file infra/automation-account.bicep --stdout > /dev/null
```

## Official references

- [Optimize Azure Blob Storage costs with smart tier](https://learn.microsoft.com/azure/storage/blobs/access-tiers-smart)
- [Access tiers for blob data](https://learn.microsoft.com/azure/storage/blobs/access-tiers-overview)
- [Storage Accounts — Update (REST, 2025-08-01)](https://learn.microsoft.com/rest/api/storagerp/storage-accounts/update?view=rest-storagerp-2025-08-01)
- [Lock your Azure resources](https://learn.microsoft.com/azure/azure-resource-manager/management/lock-resources)
- [ARM request limits and throttling](https://learn.microsoft.com/azure/azure-resource-manager/management/request-limits-and-throttling)
- [Invoke-AzRestMethod](https://learn.microsoft.com/powershell/module/az.accounts/invoke-azrestmethod)
- [Azure Automation runtime environments](https://learn.microsoft.com/azure/automation/runtime-environment-overview)
- [Azure Automation limits](https://learn.microsoft.com/azure/automation/automation-subscription-limits-faq)
