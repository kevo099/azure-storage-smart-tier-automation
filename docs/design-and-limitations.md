# Design, alternatives and limitations

## Decision summary

This repository is a bounded, opt-in, human-started wave tool: it audits which storage accounts *could*
have smart tier enabled, refuses to write unless every guard passes, changes exactly one property on
exactly the accounts an operator expected, and reports every outcome honestly — including the ones it
could not determine. It is deliberately **not** a continuous-enforcement engine; Azure Policy already is
one (see the matrix).

Smart tier is an account-level default (`properties.accessTier = Smart`) set through a partial `PATCH`
on `Microsoft.Storage/storageAccounts`. The PATCH only carries that property; Azure applies it to block
blobs that do not have an explicitly set tier.

## Why the runbook keeps the Az.Accounts transport

The 1.0 runbook authenticates with `Connect-AzAccount -Identity` and calls ARM through
`Invoke-AzRestMethod`. The sibling backup project went module-free (raw `Invoke-WebRequest` against the
Automation identity endpoint). Here the Az path is kept because it is live-proven, it resolves the
Resource Manager endpoint for the current cloud, it handles token lifetime, and it exposes response
headers (`Retry-After`, `x-ms-request-id`) on the `PSHttpResponse` object. The cost is a mutable runtime
dependency: pin the Az default package version in a dedicated runtime environment and record it. All Az
calls receive the explicit `-DefaultProfile` context, per Microsoft's context-switching guidance for the
Automation sandbox.

## Alternative matrix

| Method | Best fit | Limitation |
|---|---|---|
| Azure Policy `AuditIfNotExists` | Standing compliance reporting over all eligible accounts, including new ones | Reports only; no opt-in semantics |
| Azure Policy `DeployIfNotExists` (the owner's July 2026 design) | Smart tier mandatory organisation-wide, with exemptions | No opt-in, no change cap, no per-account outcome record; requires a subscription-wide writer identity; would defeat this runbook's exclusions if both ran on one scope |
| Azure Portal / `az storage account update` | One account | Not repeatable; the stable CLI flag may lag the `Smart` value |
| ARM/Bicep full desired state | Accounts whose entire configuration is managed as code | Not a safe merge mechanism for accounts you do not own end-to-end |
| Blob lifecycle management | Rule-based tiering/deletion by age or last access | Different mechanism; lifecycle *tiering* actions do not affect smart-tier objects, delete actions do |
| Storage Actions | Bulk blob operations | Does not offer smart tier |
| This runbook | Approved, bounded, per-account waves with evidence | Human-started; serial; control-plane only (no object counts) |

Recommended combination: Policy `AuditIfNotExists` for visibility, this runbook for waves. Run Policy
`DeployIfNotExists` only when smart tier is mandatory, and never both writers on the same scope.

## Limitations (1.1)

- Control-plane only. The runbook cannot see object counts, sizes or explicit blob tiers, so it cannot
  estimate the monitoring fee, the share of blobs that will actually be enrolled, or the cost of leaving
  smart tier later. Approve with your own inventory or Azure Monitor metrics.
- Eligibility follows Microsoft's prerequisites (StorageV2 + ZRS/GZRS/RA-GZRS, `Succeeded`). It does not
  detect redundancy conversions in progress beyond `provisioningState`, and it does not check region-level
  availability. Microsoft lists smart tier as generally available in zone-redundant regions of the public cloud,
  Azure Government and 21Vianet, and available by default (documentation read 2026-11-11). This project recorded
  the two sovereign clouds as documented previews needing feature registration when 1.1.0 was written. The
  runbook still fails closed for writes there unless explicitly allowed, because it has not been run live there;
  other environments are refused. Its `UnsupportedCloud` message keeps the older preview wording until the next
  runbook release.
- No conditional update exists for storage accounts, so the opt-in check and the PATCH are not atomic:
  a tag removed in the milliseconds between the fresh read and the write does not stop the write. Serialise
  runs against a scope; do not run two writers.
- `Microsoft.Storage/storageAccounts/write` is full account-update authority; the runbook's payload is
  minimal but the identity's power is not. Assign the remediator role only at ring resource groups and
  only while a wave runs.
- The opt-in tag is consent, not authorisation: anyone allowed to tag an account can enrol it.
- `ReadOnly` locks are not enumerated — no `locks/read`, no preflight, by judged decision. A locked target
  surfaces as `409 ScopeLocked` from the PATCH, is reported as `BlockedScopeLock`, is never retried, and
  fails the Remediate job so the lock is removed deliberately rather than skipped silently.
- Serial execution. Each write costs a fresh read, a PATCH and up to twelve verification reads; the job
  time budget (default 8,400 s) stops new writes well inside Azure Automation's three-hour limit and
  reports what was left. There is no checkpoint/resume across jobs beyond re-running (idempotent).
- Output is JSON Lines per account plus a final `SUMMARY`; a job killed by the platform still leaves the
  rows emitted so far. Azure Automation limits a single job stream to 1 MiB and the Portal view to
  200 KB — for large estates ship job streams to Log Analytics.
- Reverting an account from Smart is a priced migration (one cool-write per object); blobs given an
  explicit tier never move and cannot return to Smart. The runbook never reverts automatically.
- A platform interruption can restart an Automation job from the beginning. The pre-write re-check makes
  the write idempotent (`AlreadySmart`), but the first run's rows remain in the job stream; read the last
  `SUMMARY`.
- Only parameter-*binding* errors (a missing or malformed `SubscriptionId`) fail before the script body and
  therefore before `SUMMARY`; every other refusal is reported as `abortReason=InvalidParameters`.

## Hardening status (1.0 → 1.1)

| Item | 1.0 | 1.1 |
|---|---|---|
| Opt-in tag value comparison | case-insensitive, configurable value | fixed `true`, exact (Azure tag values are case-sensitive); the reason shows the value found |
| Exclusion tag | none | `SmartTierExclude`, exclusion wins |
| Target fence | `MaxChanges` (default 10); count-based writes at subscription scope | one named account per run (`AccountName` required, RG scope), listing/point-read/request id+name coherence, `TargetNotEligible`, `MaxChanges` default 1, `ExpectedChanges`, explicit `AllowUntaggedRemediation`, `SubscriptionId` mandatory, RG rejected at subscription scope |
| Locks | discovered only by `409`, reported as `Failed` with the old tier | `409 ScopeLocked` → `BlockedScopeLock` with ARM code/request id; not retried; Remediate fails closed; no preflight and no `locks/read` by design |
| Write scope | subscription-wide writes allowed | Remediate is resource-group scoped; `INTENT` line and `patchesSubmitted` counter before/after every PATCH |
| Write outcomes | `Remediated` / `Failed` | `Remediated` / `Deferred` / `Failed` / `WriteOutcomeUnknown`; `403` aborts the run; lost responses reconciled by re-read, never resubmitted |
| Throttling | fixed 2/4/8/16 s, `Retry-After` ignored, transport errors not retried | `Retry-After` honoured with jitter; transport failures retried for reads; job time budget |
| Output | one JSON document at the end; nothing on preflight abort | JSON Lines per account + `SUMMARY` on every path, including aborts and unexpected errors |
| Pre-state | enumeration-time tier, `"(default)"` for null | fresh pre-write tier, nullable |
| Cloud | silent fallback to public endpoint | environment recorded; non-public clouds fail closed for writes |
| Az context | `Set-AzContext` result discarded | context retained and passed as `-DefaultProfile` |
| Repository, tests, CI, RBAC templates, fixture, docs | none | this repository |
