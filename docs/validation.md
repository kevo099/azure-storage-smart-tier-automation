# Validation

Identifiers (subscription, tenant, principal, job) and live account names are omitted.

The [2026-09-06 walkthrough test](LIVE-TEST-2026-09-06.md) records a corrected release-pin import, successful
fixture/publication/no-reader checks, and verified deletion of the test Automation Account and all nine
Storage accounts. Both resource-group shells remain empty with their original tags unchanged; no active
test resources remain inside them. RBAC-dependent scenarios and the custom-role/assignment deletion
lifecycle remain untested in this run because no roles or assignments were created. This partial run is
separate from the historical full runbook qualification below.

## 1.0 — as published (2026-08-24)

Source SHA-256 `b7e85626…` (the first commit of this repository, tag `v1.0.0`). Ten jobs ran against a
since-deleted eight-account fixture (ZRS opted-in, GZRS opted-in, ZRS Cool opted-in, ZRS hierarchical
namespace opted-in, ZRS already Smart, ZRS untagged, ZRS wrong tag value, LRS opted-in):

| Job | Parameters | Result |
|---|---|---|
| Audit, RG scope | opt-in required | 8 discovered, 4 `WouldRemediate`, 3 `Skipped` (`MissingOptInTag` ×2, `UnsupportedSku` ×1), 1 `AlreadySmart` |
| Audit, subscription scope | same | identical classification |
| Audit, RG scope | opt-in **not** required | 6 candidates (the untagged and wrong-tag accounts joined) |
| Remediate, RG scope, `MaxChanges=1` | 4 candidates | job **Failed** at preflight, no writes — and **no output document** |
| Remediate, subscription scope, `MaxChanges=4` | 4 candidates | 3 `Remediated`, 1 `Failed`: HTTP **409 `ScopeLocked`** (a `ReadOnly` lock on the GZRS account); job Failed after the other three had changed |
| Remediate, RG scope, `MaxChanges=1` (×3) | one candidate each | `Remediated`; the formerly locked account succeeded once its lock was removed; a manually reset Cool account was re-enabled |

The identity that authorised those writes was not captured; today the account's identity holds only a
read-only custom role.

## 1.0 — baseline audit against the new fixture (2026-08-25)

A fresh nine-account fixture (`infra/test-environment.bicep`, no lock) was created and the 1.0 runbook run
in Audit mode at resource-group scope: 9 discovered, 4 `WouldRemediate` (ZRS opted-in, GZRS Cool, ZRS
hierarchical namespace, the future lock target), 4 `Skipped` (`UnsupportedSku:Standard_LRS`;
`UnsupportedKind:BlockBlobStorage` + `UnsupportedSku:Premium_LRS`; `MissingOptInTag` ×2 — one untagged,
one tagged `maybe`), 1 `AlreadySmart`. Zero writes.

## 1.1 — offline verification (2026-08-25)

`tests/BehaviorHarness.ps1` executes the unmodified runbook with mocked Az cmdlets (`Connect-AzAccount`,
`Set-AzContext`, `Disable-AzContextAutosave`, `Invoke-AzRestMethod`, one scenario with a real
`HttpResponseHeaders` object) and asserts per-account statuses and reasons, `event` typing, counters and
their invariants, `INTENT`-before-every-wire-PATCH ordering, PATCH bodies, abort reasons, sleeps, request-id
capture and thrown errors. **50 scenario executions (S01–S45 with variants), 50 pass** on PowerShell 7.4.19
and on 7.6.5 for runbook SHA-256 `ba11f6413b7b5ee1…`. The harness was written by an independent model
against the contract, first ran 27/35 against the draft, then proved four real defects in the fixed draft
(a retried PATCH without its own `INTENT`, `Retry-After` lost through pipeline enumeration of the real
header object, candidates without a terminal row after a preflight abort, `ScopeLocked` losing to a 403)
before the final 50/50. Run it non-interactively (`pwsh -NonInteractive -NoProfile -File
./tests/BehaviorHarness.ps1`): one scenario omits the mandatory `SubscriptionId` on purpose.

## 1.1 — live qualification (2026-08-25, demo Automation Account, PowerShell 7.4 runtime `PowerShell74-SmartTier`, Az 12.3.0)

The candidate bytes were published as the **additive** runbook `Enable-AzStorageSmartTier-v11` (the 1.0
runbook stayed untouched until release) and driven with `az automation runbook start`. The identity was the
account's system-assigned managed identity holding only the discovery-reader permissions, so no write could
succeed — which makes the last guard a genuine negative RBAC test.

| Run | Parameters | Result |
|---|---|---|
| `q2-audit` | `Mode=Audit ScopeType=ResourceGroup` on the nine-account fixture | **Completed**; 9 `Classification` rows: 4 `WouldRemediate` (ZRS/Hot, GZRS/Cool, ZRS/HNS, the lock target), 1 `AlreadySmart`, 2 `Skipped` (`UnsupportedSku:Standard_LRS`; `UnsupportedKind:BlockBlobStorage` + `UnsupportedSku:Premium_LRS`), 2 `SkippedNotOptedIn` (reasons `MissingOptInTag:SmartTierManaged=true (absent)` and `(found 'maybe')`); `patchesSubmitted=0` |
| `q3a` | `Mode=Remediate` without `AccountName` | Failed closed before any ARM call: `SUMMARY … abortReason=InvalidParameters` |
| `q3b` | `Mode=Audit ScopeType=Subscription` with a `ResourceGroupName` | `InvalidParameters` |
| `q3c` | `Mode=Remediate AccountName=<not-opted-in account>` | one `Classification` row (`SkippedNotOptedIn`), `abortReason=TargetNotEligible`, `patchesSubmitted=0` |
| `q3d` | `Mode=Remediate AccountName=nosuchaccount0` | `abortReason=NoAccountMatched` |
| `q3e` | `Mode=Remediate AccountName=… RequireOptInTag=false` without `AllowUntaggedRemediation` | `InvalidParameters` — also proves the CLI's textual `false` binds as `[bool] $false` |
| `q3f` | `Mode=Remediate ScopeType=Subscription AccountName=…` | `InvalidParameters` (writes are resource-group scoped) |
| `q3g` | `Mode=Remediate AccountName=<eligible ZRS account> ExpectedChanges=1` with the reader-only identity | one `INTENT` line, exactly one PATCH (`patchesSubmitted=1`), HTTP **403** → `Outcome` row `Failed` (`Forbidden`, with request id), `abortReason=Forbidden`; the account still reads `Hot` |

Earlier iterations of the same day caught two real runtime facts that the offline mocks could not:
`Invoke-AzRestMethod` rejects an empty `-Payload` on GET (the first live audit aborted with
`UnexpectedError` — fixed by passing the payload only for PATCH) and `PSHttpResponse.Headers` is
`HttpResponseHeaders`, not a dictionary (header reading now uses `TryGetValues`).

### Ring of one, live (2026-08-25 15:39–15:46Z, remediator role assigned at the fixture RG for the duration)

The custom **Azure Storage Smart Tier Remediator** role (`storageAccounts/read` + `write`, assignable only to
the fixture RG) was created and assigned to the Automation identity, the runs below were executed with the
released bytes (`ba11f641…`), and the assignment, the role definition and the lock were removed afterwards.

| Run | Target | Result |
|---|---|---|
| `q4a` | ZRS / Hot, opted in, `ExpectedChanges=1` | **Completed** — `Classification` `WouldRemediate`, one `INTENT`, one PATCH, `Outcome` **`Remediated`** `Hot→Smart` verified by same-id re-read; `patchesSubmitted=1` |
| `q4a` diff | same account, full `az storage account show` before/after | **84 properties compared, 1 differs: `accessTier: Hot → Smart`** — tags, network rules, TLS, shared-key and public-access settings untouched |
| `q4b` | same account again, `ExpectedChanges=1` | **Completed** — `AlreadySmart`, `patchesSubmitted=0`, no mismatch abort (idempotent success) |
| `q4c` | GZRS / Cool, opted in | **Completed** — `Remediated` `Cool→Smart` |
| `q4d` | ZRS / hierarchical namespace, opted in | **Completed** — `Remediated` `Hot→Smart` (HNS accounts are eligible, as the review established) |
| `q4e` | GZRS account again, no `ExpectedChanges` | **Completed** — `AlreadySmart`, zero PATCHes |
| `q4f` | ZRS account under a `ReadOnly` lock | **Failed (by design)** — one `INTENT`, one PATCH, live `409 ScopeLocked` → `Outcome` **`BlockedScopeLock`** (`ReadOnlyLock, ScopeLocked`), `locked=1`, account unchanged; not retried, not green |
| `q4g` | final fixture audit | **Completed** — 9/9: 4 `AlreadySmart`, 1 `WouldRemediate` (the lock target), 2 `Skipped`, 2 `SkippedNotOptedIn`, `patchesSubmitted=0` |

Before the role propagated, four Remediate attempts against the same target were refused by ARM with
HTTP 403 and reported as `Failed`/`Forbidden` with one PATCH each and the account still `Hot` — the
negative half of the RBAC proof (the grant is the only thing that separated those runs from `q4a`).

Every branch of the write contract has now been exercised against Azure except the ambiguous-response
paths (5xx / lost response / undocumented 2xx) and throttling, which cannot be provoked on demand and
remain harness-proven.

The guard set above was run twice: on an earlier candidate (`5215c3210d4e9fba…`) and again on the released
bytes — fetch-back of the published `-v11` runbook SHA-256 **`ba11f6413b7b5ee1…`**, identical to
`src/Enable-AzStorageSmartTier.ps1` at `v1.1.0` and to the 50/50 harness run. Tested bytes are shipped bytes.
