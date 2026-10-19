# Changelog

## Unreleased

Runbook bytes are unchanged (`src/Enable-AzStorageSmartTier.ps1`, SHA-256 `ba11f641…`, `runbookVersion` 1.1.0).

- **Publisher.** `scripts/publish-runbook.sh` now uploads the runbook as raw bytes and verifies the draft and the
  published content byte-for-byte, matching the Azure Backup automation repository. The previous helper used
  `--content @file`, which Azure CLI 2.90+ expands without the final newline, and compared a `-o tsv` read that
  restores one, so it could report a match while the published runbook was one byte short (observed live on
  2026-10-19). It also discovers the Automation Account region instead of defaulting to `eastus2`.
- **Tests.** `tests/test_publish_runbook.py` (mocked Azure CLI) covers byte preservation and the upload gates; CI runs it.
- **Evidence.** [LIVE-TEST-2026-10-19](docs/LIVE-TEST-2026-10-19.md): the full walkthrough in a second tenant.

Earlier changes on `main` after the v1.1.0 tag: the Automation Account Bicep, publish and ring-role helpers,
the step-by-step walkthrough, the verified writer revocation fix and the 2026-09-06 live records.

## 1.1.0 — 2026-08-25

Hardening release driven by an adversarial multi-model review of 1.0 (seven GPT-5.6 review lenses, a
Claude cross-check, an executed offline harness, four-side cross-examination and two judges — all with
Microsoft Learn access), followed by a second review of 1.1 before anything touched Azure. The behaviour
of a supervised single-account wave did not change; every item below closes a confirmed finding.

### Runbook (`src/Enable-AzStorageSmartTier.ps1`)
- **Exact target fence.** `Remediate` writes exactly one named account per run: `AccountName` is required,
  the listing, the point read and the request must agree on id and name, an ineligible target aborts
  (`TargetNotEligible`) and an already-Smart target is the idempotent success; `MaxChanges`
  now defaults to 1 (was 10); `SubscriptionId` is mandatory (1.0 inferred it from the identity's context);
  `ResourceGroupName` with `ScopeType=Subscription` is rejected (1.0 silently ignored it); whitespace-only
  names are rejected.
- **Opt-in semantics.** `RequireOptInTag` is a real Boolean; the consent value is fixed to `true` and
  compared exactly (Azure tag values are case-sensitive, so `True` is not consent — `RequiredTagValue` is
  gone) and the reason string shows the value actually found; a new exclusion tag
  (`SmartTierExclude`) always wins; remediating without the opt-in tag requires the explicit
  `AllowUntaggedRemediation` switch.
- **Locks.** A `ReadOnly` lock is recognised from the `409 ScopeLocked` the PATCH returns and reported as
  `BlockedScopeLock` with the ARM code and request id: never retried, never green (the Remediate job fails
  closed so the lock is removed deliberately). There is deliberately no lock preflight and the roles carry
  no `locks/read` — the review's judges ruled that a lock must never become a silent skip and that the
  extra permission is not worth it. 1.0 reported the live lock as a generic `Failed` with the old tier.
- **Remediate is resource-group scoped.** `Mode=Remediate` with `ScopeType=Subscription` is refused before
  any ARM call; subscription scope remains available for audits.
- **Intent before write.** An `INTENT` line (id, name, pre-write tier, attempt number, the exact payload)
  precedes every PATCH attempt — a 429 retry included — and `counts.patchesSubmitted` counts every PATCH
  request that reached the wire, so a job killed mid-write still shows what was attempted. When a run
  aborts in preflight, every candidate still gets a terminal `SkippedRunAborted` row.
- **Honest write outcomes.** `Remediated` (verified by re-read), `SkippedPreconditionChanged`,
  `BlockedScopeLock`, `Deferred` (other 409 / exhausted 429), `Failed` (definitive 4xx) and
  `WriteOutcomeUnknown` (5xx or lost response that six re-reads could not resolve — never resubmitted).
  A `403` aborts the run (`abortReason=Forbidden`) instead of failing every account. 1.0 collapsed all of
  these into `Failed` and could report a committed change as failed with the old tier.
- **Two-phase execution with structured aborts.** Everything is classified before the first PATCH; aborts
  (`InvalidParameters`, `JobBudgetExhausted`, `DiscoveryErrors`, `UnsupportedCloud`, `NoAccountMatched`,
  `TargetNotEligible`, `ExpectedChangesMismatch`, `MaxChangesExceeded`, `Forbidden`, `UnexpectedError`)
  always emit the
  `SUMMARY` line first — 1.0's `MaxChanges` abort produced no output at all. Only parameter *binding*
  errors (a missing or malformed `SubscriptionId`) fail before the script body and therefore before
  `SUMMARY`.
- **Transport.** `Retry-After` honoured exactly — never shortened: a delay over 300 s or over the remaining
  job budget stops the retry instead — with jitter for reads and throttled PATCHes; every 5xx and transport
  failure retried for reads; only HTTP 200 counts as a write success (any other 2xx is reconciled by
  re-read, as the Update API documents only 200); only `StorageAccountOperationInProgress` defers, every
  other 409 is definitive; a failed GET carries HTTP status, ARM code and request id into its `Error` row;
  response headers are read from `HttpResponseHeaders` (what `PSHttpResponse` actually exposes); every Az call carries the explicit
  `-DefaultProfile` context (Microsoft's guidance for the Automation sandbox); every URL is validated
  against the environment's Resource Manager endpoint; responses are parsed with `System.Text.Json`
  so tag values that look like dates are not rewritten.
- **Job time budget.** `JobTimeBudgetSeconds` (default 8400) stops new writes before Azure Automation's
  three-hour limit; unwritten candidates are reported and the job fails closed.
- **Output.** One JSON line per account as soon as its state is known (schema 1.1: timestamp, `event`
  = `Classification` or `Outcome`, ids, kind,
  SKU, HNS, fresh nullable before/after tier, status, reasons, stage, HTTP status, ARM error code,
  request id) plus a final `SUMMARY` with truthful counters, the identity/environment used, and the
  explicit-tier and exit-cost notes. 1.0 emitted a single document at the end.
- **Cloud gate.** Non-public clouds fail closed for `Remediate`; `AllowNonPublicCloud` is honoured only for
  Azure Government and 21Vianet (the documented previews, feature registration required); the endpoint is
  never guessed outside `AzureCloud`.
- **No `#requires` directive** (unsupported in Automation runbooks); an explicit PowerShell 7 guard instead.
- Removed: `ManagedIdentityClientId` (caller-selected identity). The runbook always uses the account's
  system-assigned identity.

### Repository (new)
- `tests/BehaviorHarness.ps1`: dependency-free behavioural harness executing the real runbook with mocked
  Az cmdlets; `tests/StaticValidation.ps1`; CI with PSScriptAnalyzer (warnings fail), SHA-pinned checkout
  and exact RBAC assertions.
- `infra/rbac/`: discovery-reader and remediator custom-role templates (never built-in Storage Account
  Contributor, which carries key access); `infra/test-environment.bicep`: nine-account fixture with an
  optional `ReadOnly` lock.
- README with product disambiguation, cost and exit-cost disclosure, RBAC/ring procedure, Policy-vs-runbook
  decision matrix and teardown; `docs/design-and-limitations.md`; `docs/validation.md`; `SECURITY.md`; MIT
  `LICENSE`.

### Known limitations carried forward
- Control-plane only: no object counts or capacity, so no monitoring-fee estimate.
- No conditional update exists for storage accounts; the opt-in check and the PATCH are not atomic.
- Serial execution; no checkpoint/resume beyond idempotent re-runs.

### Release provenance
- Tag `v1.1.0` = commit `33240e3` (squash of the reviewed branch, PR #1). Published to the demo Automation
  Account on 2026-08-25 as runbook `Enable-AzStorageSmartTier` (PowerShell 7.4 runtime); fetch-back content
  SHA-256 `ba11f6413b7b5ee1…` equals `src/Enable-AzStorageSmartTier.ps1` at this tag and the bytes that
  passed the 50/50 harness and the live guard set. The qualification copy `Enable-AzStorageSmartTier-v11`
  was retained; the 1.0 bytes remain in git history (`bd2fcb0`, tag `v1.0.0`).

## 1.0.0 — 2026-08-24
Runbook as published in the owner's Automation account and exercised against an eight-account fixture
(audit, capped remediation, one `ScopeLocked` failure, idempotence). Imported verbatim as the first commit
of this repository.
