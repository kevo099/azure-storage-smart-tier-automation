# Gotchas

Everything on this page was hit for real while building, reviewing or live-qualifying this runbook.
Read it before the first `Remediate`.

## Cost and irreversibility
- **Enabling is cheap; leaving is not.** Smart tier bills a monitoring fee per 10,000 objects larger than
  128 KiB, and switching an account *off* Smart costs one cool-write per object. A blob that is ever given
  an explicit tier stops moving and cannot return to Smart. The runbook is control-plane only — it cannot
  see object counts, explicit-tier blobs or lifecycle policies — so approve each account with your own
  inventory or Azure Monitor metrics.
- **Lifecycle management changes meaning.** Lifecycle *tiering* rules stop affecting Smart-managed blobs;
  *delete* rules keep firing. Review the account's policy before enabling.
- First benefit is slow: block blobs move hot → cool after 30 days without access, cool → cold after 90.
  Do not expect a bill change in the first month.

## Behaviour that looks like a bug but is the contract
- `BlockedScopeLock`, `Deferred`, `WriteOutcomeUnknown` and every budget skip **fail the Remediate job on
  purpose**. Do not wire "job Failed" to "runbook broken" — read the last `SUMMARY` line.
- Consent is exact: `SmartTierManaged=true`. `True`, `yes` or `"true "` are not consent — Azure tag values
  are case-sensitive. The `SkippedNotOptedIn` reason shows the value that was found.
- `Remediate` writes **one named account per run** at resource-group scope. Subscription scope is audit
  only. Count-based fleet writes were reviewed and rejected; widen a ring by running again per account.
- `ExpectedChanges=1` against an already-Smart account is a success, not a mismatch (idempotent rerun).
- `RequireOptInTag=false` is refused unless `AllowUntaggedRemediation=true` is passed as well; the
  exclusion tag still wins.
- A missing or malformed `SubscriptionId` can fail at parameter *binding*, before the script body, and
  produces no `SUMMARY`. Runtime or package-startup failures can also prevent the script from emitting
  one; inspect the job's exception and error streams before assuming which cause applies.
- There is no conditional PATCH for storage accounts, so a tag removed between the fresh read and the
  write is not detected. Serialise writers; never run this next to an Azure Policy `DeployIfNotExists`
  on the same accounts.

## Azure Automation platform
- The runbook needs a **PowerShell 7.4 runtime environment** with the **Az** default package pinned
  (validated with 12.3.0). A Portal-created runbook may land on the legacy runtime; link it explicitly
  (`scripts/publish-runbook.sh` does) and check the runbook's `runtimeEnvironment` property.
- A fresh job can remain `Activating` beyond the walkthrough's ten-minute polling budget, without a
  start time or exception. That timeout is a local investigation checkpoint: Microsoft documents a
  30-minute start SLA for 99.9% of runbooks. Keep observing the same job ID; calling `run_job` again submits
  a duplicate. Preserve both the timeout and eventual result, and leave the no-reader identity unchanged
  while that baseline job is pending. See [execution start-time troubleshooting](https://learn.microsoft.com/troubleshoot/azure/automation/runbooks/job-not-start-as-expected).
- Azure Automation does not support `#requires`; the runbook uses an explicit PowerShell 7 guard instead.
- Job streams are capped at 1 MiB per job (about 200 KB in the Portal view). Audit large subscriptions per
  resource group or ship job streams to Log Analytics.
- The platform can restart an interrupted job from the beginning. Writes stay idempotent, but rows from the
  first attempt remain in the stream — trust the last `SUMMARY`.
- Text `true`/`false` job parameters bind to `[bool]` correctly (proved live); `1`/`0` were not tested.
- Sovereign clouds: only Azure Government and 21Vianet, as documented previews with feature registration,
  and only with `AllowNonPublicCloud=true`; any other environment is refused for writes.

## RBAC
- `Microsoft.Storage/storageAccounts/write` is full account-update authority (network rules, TLS, shared
  key, public access…). There is no property-level permission and ABAC cannot inspect a control-plane
  PATCH body. Use the custom remediator role, assign it only at the ring resource group, only for the
  window, then remove it. Never the built-in Storage Account Contributor — it carries `listKeys`.
- Expect **propagation lag and stale tokens**. Creating the ring role right after a User Access
  Administrator grant failed with `AuthorizationFailed … refresh your credentials` until the CLI token
  rolled over, although the assignment was correct. Wait, or refresh the login, before concluding the
  grant is wrong. The runbook side is safe either way: its writes are simply refused (`Forbidden`).
- A role-definition create can succeed while its immediate scoped list returns empty. The writer helper
  then stops before assignment with `Created role is not readable yet`. Preserve the failure and recover
  the created GUID by checking the exact template, sole assignable scope, creator and creation time.
  Require stable exact-GUID readback, then retry only assignment creation with that saved ID; an absent
  name-list result is not evidence that a new definition is needed. See the
  [recorded recovery](LIVE-TEST-2026-09-06.md#writer-definition-propagation-recovery).
- After successful role/assignment DELETEs, role-name lists can disagree with exact-GUID GETs or show a
  deleted definition again after earlier empty reads. Preserve the strict failure, continue read-only
  observation until repeated checks agree, and keep deletion evidence separate from visibility checks.
  Never recreate/regrant a role to resolve cleanup, and never treat permission/network failures as proof
  of absence. See the [cleanup record](LIVE-TEST-2026-09-06.md#test-rbac-cleanup-and-final-inventory).
- Creating a custom role definition needs `Microsoft.Authorization/roleDefinitions/write` on every
  assignable scope — User Access Administrator at the ring resource group is enough when the role's
  assignable scope is that resource group.

## Reusing or modifying the code
- An annotated release tag has its own Git object ID. Git commands can silently peel that object to
  read a file, while a GitHub raw-content URL containing the tag-object SHA returns 404. Use
  `git rev-parse 'v1.1.0^{commit}'` for the commit pin and check `git cat-file -t` reports `commit` before
  passing it as Bicep `sourceRef`. An invalid raw URL fails Azure deployment with `Validation errors
  while reading content link`; inspect the partially created account/runtime before retrying only the
  Automation deployment. Do not rerun a storage fixture whose accounts have already been remediated.
- Run the harness **non-interactively**: `pwsh -NonInteractive -NoProfile -File tests/BehaviorHarness.ps1`
  (CI also closes stdin). One scenario omits the mandatory `SubscriptionId` on purpose; an interactive host
  prompts for it forever.
- `Invoke-AzRestMethod` rejects an empty `-Payload` on GET — pass the payload only for PATCH.
- `PSHttpResponse.Headers` is `System.Net.Http.Headers.HttpResponseHeaders`, not a dictionary; read it with
  `TryGetValues`. Mocks must mimic that or they hide the bug (ours did, once).
- On PowerShell 7.4, `Write-Output -NoEnumerate` wraps scalars in a `List` and turns `$null` into an empty
  list. To return an enumerable (headers, arrays) from a function intact, use the comma operator — see
  `Protect-Enumerable` in the runbook.
- `ConvertFrom-Json` rewrites date-like strings into `DateTime`; the runbook keeps every value as text with
  `System.Text.Json.Nodes`. Keep it that way if you touch tag handling.
- The `az automation` CLI group is marked experimental (noisy warnings) and cannot link a runtime
  environment; the link is a REST `PATCH …/runbooks/{name}?api-version=2024-10-23`.
- Importing a runbook through `publishContentLink` (the Bicep path) appends one trailing newline, so the
  fetch-back SHA-256 differs from the file by that byte; `diff` shows only an empty last line. Upload with
  `scripts/publish-runbook.sh` when you need hash-exact provenance.
- Automation Accounts are quota-limited per region on small subscriptions (`Conflict … exceeded your quota
  for Automation accounts`); the RG's region does not matter, the account's `location` does.
- A managed identity with **no** role assignment anywhere in the subscription fails at `Set-AzContext`
  ("Please provide a valid tenant or a valid subscription") — before any ARM call. Any assignment inside
  the subscription makes it visible; the reader role at the fixture RG is enough.
- Custom-role creation and role-assignment cleanup also need Owner/User Access Administrator at the
  relevant scopes. The reader template defaults to subscription assignability; the walkthrough renders
  it to the fixture group. Contributor can deploy resources, but cannot perform these RBAC steps.
- `ring-role.sh revoke` must finish successfully and its access checks must show no remaining writer.
  Read/delete errors now stop the helper; a shared or differently scoped definition is retained for its
  owner to review. This verifies that custom role only, so inspect other/inherited grants separately.
- CLI commands cannot combine `az role assignment list --all` with `--scope`. For custom-role deletion,
  `az role definition delete --name` takes a role name or GUID, not the full ARM resource ID.
