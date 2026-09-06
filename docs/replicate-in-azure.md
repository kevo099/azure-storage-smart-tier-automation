# Replicate this in Azure — step by step

Build a disposable nine-account fixture, inspect an audit, enable Smart on one named account, verify the
change, and remove the temporary writer permission. Read [gotchas.md](gotchas.md) first. Allow 30–60 minutes
plus Azure deployment and RBAC propagation time. Empty accounts avoid data-capacity charges, but Automation
jobs and any monitoring you add can incur charges; check your subscription's pricing and delete the fixture.

Run the numbered sections in order in **Bash** on Linux, WSL, or Azure Cloud Shell's Bash mode. Keep the same
shell open: later steps reuse its variables and functions. Stop at an unexpected command error or checkpoint.
These commands create resources and run jobs in your subscription; the offline checks in the README do not.
Use a dedicated Bash terminal and enable error handling before the first command. An unexpected error ends
that shell; the private session file described below lets you recover the identifiers.

```bash
set -euo pipefail
umask 077
```

## 0. Tools, source, login, and scope

Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) **2.87.0 or newer**, Git, jq,
Python 3, and standard Bash tools (`diff`, `sed`, `sha256sum`). The current Automation extension needs CLI
2.75.0 or newer; this guide uses the higher [Smart tier tooling minimum](https://learn.microsoft.com/azure/storage/blobs/access-tiers-smart#client-tooling).
The local review used CLI 2.90.0 and Automation extension 1.0.0b2. PowerShell **7.4** is needed locally only
for the PowerShell harness; Azure needs the runtime environment installed in step 1.

```bash
az version
az extension add --name automation --version 1.0.0b2
az extension show --name automation --query version -o tsv
az bicep install
az bicep version
git --version
jq --version
python3 --version
```

**Checkpoint** — the Automation extension reports `1.0.0b2`. If another version is already installed,
agree whether to replace it in this CLI environment or use an isolated installation before proceeding;
do not treat an already-installed message as proof that the requested pin is active.

Clone the full source revision containing the deployment templates and corrected role helper. **Do not
check out only `v1.1.0`**: that release contains the runbook but predates `automation-account.bicep` and the
helper scripts. The runbook imported by Azure remains separately pinned to the `v1.1.0` commit.

```bash
git clone https://github.com/kevo099/azure-storage-smart-tier-automation.git
cd azure-storage-smart-tier-automation
SOURCE_COMMIT='c32ca158d077174bca862d7cfbfbfe6b8de07fc7'
GUIDE_COPY=$(mktemp "${TMPDIR:-/tmp}/smart-tier-walkthrough.XXXXXX")
cp docs/replicate-in-azure.md "$GUIDE_COPY"
printf 'Keep this current walkthrough open: %s\n' "$GUIDE_COPY"
git checkout --detach "$SOURCE_COMMIT"
RUNBOOK_REF='33240e356653dad6c814a9fe6403d8e324b742af'
EXPECTED_RUNBOOK_SHA='ba11f6413b7b5ee1d1d12acee6a7b7fe8cf013efd7602e4e1802998effa872e8'
git rev-parse HEAD
test "$(git cat-file -t "$SOURCE_COMMIT")" = commit
test "$(git cat-file -t "$RUNBOOK_REF")" = commit
test "$(git show "$RUNBOOK_REF:src/Enable-AzStorageSmartTier.ps1" | sha256sum | cut -d' ' -f1)" = "$EXPECTED_RUNBOOK_SHA"
git diff --exit-code "$RUNBOOK_REF" -- src/Enable-AzStorageSmartTier.ps1
```

**Checkpoint** — the source commit matches `SOURCE_COMMIT`; the diff prints nothing and exits zero. Keep
the saved `GUIDE_COPY` (or this guide in your browser) open: the pinned source includes the executable
files, while this walkthrough is newer. A fork must override Bicep's `sourceBaseUrl`; editing a local runbook does not change what the
default remote import deploys.

Use the **commit pointed to by the release tag** for `RUNBOOK_REF`. For an annotated tag, `git rev-parse
v1.1.0` returns a tag-object ID; `git rev-parse 'v1.1.0^{commit}'` returns the commit needed by GitHub's raw
content URL. The live test found that using the tag-object ID `96d05e0…` passed local `git show` checks but
returned HTTP 404 from the raw URL and failed Azure's content-link validation. The checks above require
commit objects and the qualified runbook hash before deployment; the corrected pin keeps the same bytes.

Set the values below. Replace the subscription placeholder with your subscription ID and choose unused
resource-group names. Use 3–11 lowercase letters/digits for `PREFIX`; the nine resulting storage-account
names must be globally unique. The example region must support **ZRS, GZRS and Premium block blob storage**;
change `REGION` if Azure reports an unavailable SKU. Use a separate region for `AA_REGION` if Automation
quota or runtime availability requires it.

```bash
SUB='REPLACE_WITH_YOUR_SUBSCRIPTION_ID'
AA_RG='rg-smart-tier-automation-demo'
AA='aa-smart-tier-demo'
FIXTURE_RG='rg-smart-tier-fixture-demo'
REGION='eastus2'
AA_REGION="$REGION"
PREFIX='stexample01'  # replace with your own globally unique prefix
ARM='https://management.azure.com'
READER_ROLE='Azure Storage Smart Tier Discovery Reader'
WRITER_ROLE='Azure Storage Smart Tier Remediator'
SCOPE="/subscriptions/$SUB/resourceGroups/$FIXTURE_RG"
TARGET="${PREFIX}zrstag"
UNTAGGED="${PREFIX}zrsnotag"
LOCK_TARGET="${PREFIX}zrslock"
mkdir -p .generated
EVIDENCE_DIR=$(mktemp -d "$PWD/.generated/smart-tier-evidence.XXXXXX")
chmod 700 "$EVIDENCE_DIR"
printf 'Private evidence directory: %s\n' "$EVIDENCE_DIR"
declare -p SUB AA_RG AA FIXTURE_RG REGION AA_REGION PREFIX ARM READER_ROLE WRITER_ROLE \
  SCOPE TARGET UNTAGGED LOCK_TARGET EVIDENCE_DIR RUNBOOK_REF EXPECTED_RUNBOOK_SHA SOURCE_COMMIT > "$EVIDENCE_DIR/session.env"

az login  # Cloud Shell is normally already signed in; use az login --tenant TENANT_ID if needed
az account set --subscription "$SUB"
az account show --query '{subscription:id,name:name,tenant:tenantId,user:user.name}' -o table
az cloud show --query name -o tsv
```

**Checkpoint** — verify the intended tenant/subscription and `AzureCloud`. Your CLI login deploys resources;
the Automation Account's separate managed identity runs the runbook. Job IDs and raw resource JSON belong
in your private evidence directory, not in a public commit.

Arrange the following permissions before continuing:

| Actor / operation | Permission and scope |
|---|---|
| Human creates the two resource groups, registers providers | Contributor at subscription scope, or an administrator creates the groups/registers providers first |
| Human deploys/starts jobs and manages the fixture | Contributor on each of the two dedicated groups |
| Human creates/assigns/removes the custom roles in steps 4, 7 and 9 | Owner or User Access Administrator at the fixture group; step 4 explicitly renders its reader definition to that group |
| Human adds/removes the optional lock | `Microsoft.Authorization/locks/*` at the fixture scope, included in Owner/User Access Administrator |
| Automation identity | Initially no roles; later only the discovery reader at the fixture group plus a temporary writer at that same group |

Contributor alone cannot manage these custom roles. A custom role's creator needs permission on **every
assignable scope**: the checked-in reader template defaults to the subscription, so using that template
unchanged needs subscription-level role-definition permission. This guide narrows it before creation.
See [custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles) and
[lock permissions](https://learn.microsoft.com/azure/azure-resource-manager/management/lock-resources#who-can-create-or-delete-locks).

```bash
az provider show --namespace Microsoft.Automation --query registrationState -o tsv
az provider show --namespace Microsoft.Storage --query registrationState -o tsv
az group exists --name "$AA_RG"
az group exists --name "$FIXTURE_RG"
az role definition list --name "$READER_ROLE" --custom-role-only true -o json
az role definition list --name "$WRITER_ROLE" --custom-role-only true -o json
```

**Checkpoint** — providers are `Registered`, both group checks are `false`, and both role lists are `[]`.
These initial role-name checks require subscription-level role-definition read access (included in the
subscription Contributor needed to create the fresh groups). If an administrator precreates your groups
and delegates only RG access, have that administrator perform this name-collision check; then use only
those agreed empty groups and RG-scoped role reads after they exist.
If a provider is unregistered, an authorized subscription administrator can run `az provider register
--namespace Microsoft.Automation --wait` (and the equivalent for `Microsoft.Storage`). If a group or custom
role already exists, stop and agree a reuse plan with its owner; this disposable walkthrough assumes new
objects and exclusive ownership. Do not delete another deployment's role to make the names available.

## 1. Automation Account, PowerShell 7.4 runtime, runbook

The template creates a system-assigned identity, disables local authentication, creates
`PowerShell74-SmartTier` with **Az 12.3.0**, and publishes the pinned runbook linked to that runtime.

```bash
az group create --name "$AA_RG" --location "$AA_REGION"
az deployment group create --resource-group "$AA_RG" --name smart-tier-automation \
  --template-file infra/automation-account.bicep \
  --parameters automationAccountName="$AA" sourceRef="$RUNBOOK_REF"
PRINCIPAL=$(az automation account show --resource-group "$AA_RG" --name "$AA" \
  --query identity.principalId -o tsv)
BASE="$ARM/subscriptions/$SUB/resourceGroups/$AA_RG/providers/Microsoft.Automation/automationAccounts/$AA"
test -n "$PRINCIPAL"
declare -p PRINCIPAL BASE >> "$EVIDENCE_DIR/session.env"
az rest --method get --url "$BASE/runbooks/Enable-AzStorageSmartTier?api-version=2024-10-23" \
  --query '{state:properties.state,runtime:properties.runtimeEnvironment}'
```

**Checkpoint** — the deployment succeeds, `PRINCIPAL` is a GUID, and the runbook reports `Published` and
`PowerShell74-SmartTier`. In the Portal, check Automation Account → Runtime environments →
PowerShell74-SmartTier for PowerShell 7.4 / Az 12.3.0 and completed package provisioning. Do not silently
change the package pin if it fails; a new package version needs validation.

Compare content against the release. The recorded Bicep import added one trailing newline; tolerate only
that difference, not arbitrary whitespace or other source changes:

```bash
git show "$RUNBOOK_REF:src/Enable-AzStorageSmartTier.ps1" > "$EVIDENCE_DIR/release.ps1"
az rest --method get --url "$BASE/runbooks/Enable-AzStorageSmartTier/content?api-version=2023-11-01" \
  -o tsv | tr -d '\r' > "$EVIDENCE_DIR/published.ps1"
python3 - "$EVIDENCE_DIR/release.ps1" "$EVIDENCE_DIR/published.ps1" <<'PY'
from pathlib import Path
import sys
expected, actual = (Path(p).read_bytes() for p in sys.argv[1:])
if actual not in (expected, expected + b'\n'):
    raise SystemExit('STOP: published content differs from the pinned runbook')
print('PASS: pinned content matches, allowing only the observed extra final newline')
PY
```

For a local change or byte-exact CLI fetch-back comparison, use the publisher **after** the Automation
Account, its identity, and this runtime exist. It does not provision them. `LOCATION` must be the Automation
Account's region; its default is `eastus2`.

```bash
SUBSCRIPTION_ID="$SUB" RESOURCE_GROUP="$AA_RG" AUTOMATION_ACCOUNT="$AA" LOCATION="$AA_REGION" \
  scripts/publish-runbook.sh
```

**Checkpoint** — `OK: published bytes equal the local file`; record its hash. If this fails, stop and inspect
the account/runtime and source; do not start jobs with unexplained content differences.

## 2. Fixture: nine empty storage accounts

```bash
az group create --name "$FIXTURE_RG" --location "$REGION"
az deployment group create --resource-group "$FIXTURE_RG" --name smart-tier-fixture \
  --template-file infra/test-environment.bicep --parameters namePrefix="$PREFIX" createLock=false
az storage account list --resource-group "$FIXTURE_RG" \
  --query '[].{name:name,kind:kind,sku:sku.name,tier:accessTier,optIn:tags.SmartTierManaged}' -o table
```

**Checkpoint** — nine accounts: ZRS opted-in (`zrstag`), untagged (`zrsnotag`), wrong tag value (`zrsbadtag`),
GZRS/Cool (`gzrscool`), hierarchical namespace (`zrshns`), already Smart (`zrssmart`), unlocked lock target
(`zrslock`), unsupported LRS (`lrstag`), and unsupported Premium block blob (`premtag`). The eligible targets
are already tagged by the template. Do not upload data or rerun the fixture deployment after remediation:
its declared tiers would reset the accounts and invalidate the before/after checkpoints.

## 3. Start a job and read its result

A successful `runbook start` call only queues a job. It does **not** mean that the runbook completed.
Define this helper once; every later `run_job` call starts exactly one job, waits up to ten minutes, and saves
its metadata and output. It displays terminal failure states without treating them as a CLI error, because
steps 3 and 6 intentionally expect failed jobs. Check the displayed status and last `SUMMARY` every time.

```bash
run_job() {
  JOB_ID=$(az automation runbook start --subscription "$SUB" --resource-group "$AA_RG" \
    --automation-account-name "$AA" --name Enable-AzStorageSmartTier \
    --parameters "$@" --query name -o tsv) || return 1
  [[ "$JOB_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo 'STOP: no job GUID returned' >&2; return 1; }
  printf 'Job: %s\n' "$JOB_ID"
  declare -p JOB_ID >> "$EVIDENCE_DIR/session.env"
  local attempt status
  for ((attempt=0; attempt<60; attempt++)); do
    az rest --method get --url "$BASE/jobs/$JOB_ID?api-version=2024-10-23" \
      -o json > "$EVIDENCE_DIR/$JOB_ID.json" || return 1
    status=$(jq -er '.properties.status' "$EVIDENCE_DIR/$JOB_ID.json") || return 1
    case "$status" in
      Completed|Failed|Stopped|Suspended)
        printf 'Job status: %s\n' "$status"
        az rest --method get --url "$BASE/jobs/$JOB_ID/output?api-version=2024-10-23" \
          -o tsv > "$EVIDENCE_DIR/$JOB_ID-output.txt" || return 1
        cat "$EVIDENCE_DIR/$JOB_ID-output.txt"
        return 0 ;;
    esac
    sleep 10
  done
  cp "$EVIDENCE_DIR/$JOB_ID.json" "$EVIDENCE_DIR/$JOB_ID-timeout.json" || return 1
  date -u +'%Y-%m-%dT%H:%M:%S.%NZ' > "$EVIDENCE_DIR/$JOB_ID-timeout-observed.txt" || return 1
  echo "STOP: job $JOB_ID is still $status; inspect it before starting another job." >&2
  return 1
}

run_job Mode=Audit ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB"
```

**Checkpoint** — with this new identity and no roles, job `Failed`, no account rows or writes, and a
`SUMMARY` with `counts.patchesSubmitted=0`. The recorded empty-subscription case reports
`UnexpectedError` / `Please provide a valid tenant or a valid subscription.` at `Set-AzContext`. If an
unrelated role already makes the subscription visible, a missing target permission instead gives a GET
`403 AuthorizationFailed`. If the job succeeds already, stop and inspect existing/inherited permissions;
you have not demonstrated the no-access baseline.

The helper's ten-minute polling budget is an investigation checkpoint. Microsoft documents that 99.9%
of runbooks should start within 30 minutes of their planned start time; a local timeout alone does not
prove the runbook failed. The helper preserves `JOB_ID-timeout.json` and its observation timestamp before
subsequent reads update the current metadata file. See [execution start-time troubleshooting](https://learn.microsoft.com/troubleshoot/azure/automation/runbooks/job-not-start-as-expected).
Do not call `run_job` again to wait: it submits another job. The helper now saves the latest `JOB_ID` in
`session.env`; if the shell closed, recover that session first. Inspect the same job with read-only calls:

```bash
az rest --method get --url "$BASE/jobs/$JOB_ID?api-version=2024-10-23" \
  -o json > "$EVIDENCE_DIR/$JOB_ID.json"
jq '.properties | {status, creationTime, startTime, endTime, exception}' "$EVIDENCE_DIR/$JOB_ID.json"
az rest --method get --url "$BASE/jobs/$JOB_ID/output?api-version=2024-10-23" \
  -o tsv > "$EVIDENCE_DIR/$JOB_ID-output.txt"
cat "$EVIDENCE_DIR/$JOB_ID-output.txt"
```

Repeat only those GETs while investigating the existing job. Retain the local timeout and its eventual
terminal result separately. Wait for the no-reader job to finish before adding its reader role; changing
permissions while it is pending invalidates that baseline. If a job still has not started after the
30-minute service window, investigate the platform/job details before submitting another job or changing
its runtime.

In the Portal the same result is under Automation Account → Jobs → the job ID → Output / Errors / All Logs.
If no `SUMMARY` exists, inspect Errors and the job's `exception` in the saved metadata; parameter binding,
package loading, or runtime selection may have failed before the script ran. See Microsoft's
[job status](https://learn.microsoft.com/rest/api/automation/job/get?view=rest-automation-2024-10-23) and
[job output API](https://learn.microsoft.com/rest/api/automation/job/get-output?view=rest-automation-2024-10-23).

## 4. Reader role at the fixture scope

The Owner/User Access Administrator performs this step at the fixture group. Render the reader's
**assignable scope to this group**, then capture the precise definition and assignment IDs for cleanup:

```bash
jq --arg scope "$SCOPE" '.AssignableScopes = [$scope]' \
  infra/rbac/discovery-reader-role.template.json > "$EVIDENCE_DIR/reader-role.json"
READER_ROLE_ID=$(az role definition create --role-definition @"$EVIDENCE_DIR/reader-role.json" \
  --query id -o tsv)
test -n "$READER_ROLE_ID"
declare -p READER_ROLE_ID >> "$EVIDENCE_DIR/session.env"
READER_ASSIGNMENT_ID=$(az role assignment create --assignee-object-id "$PRINCIPAL" \
  --assignee-principal-type ServicePrincipal --role "$READER_ROLE_ID" --scope "$SCOPE" \
  --query id -o tsv)
test -n "$READER_ASSIGNMENT_ID"
declare -p READER_ASSIGNMENT_ID >> "$EVIDENCE_DIR/session.env"
printf 'Reader definition: %s\nReader assignment: %s\n' "$READER_ROLE_ID" "$READER_ASSIGNMENT_ID"
az role assignment list --assignee-object-id "$PRINCIPAL" --scope "$SCOPE" --include-inherited \
  --fill-principal-name false -o table
```

**Checkpoint** — both IDs are nonempty and the identity has only the intended discovery reader. Investigate
any existing or inherited writer grant before continuing. Allow up to ten minutes for RBAC propagation;
refresh the human CLI login after a new human RBAC grant if necessary. Subscription-wide audits require a
separately approved subscription reader definition/assignment; they are outside this fixture walkthrough.

If assignment creation returns `RoleDefinitionDoesNotExist`, the new definition may not have propagated.
Its ID was saved before assignment creation. Recover the session as described below, wait until the
RG-scoped definition list shows that ID, then retry **only** the `READER_ASSIGNMENT_ID=$(az role assignment
create ...)` command, its nonempty check, and its `declare -p` save. Do not rerun role-definition creation.

## 5. Successful read-only audit

```bash
run_job Mode=Audit ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB"
```

**Checkpoint** — job `Completed`, nine `Classification` rows: 4 `WouldRemediate`, 1 `AlreadySmart`,
2 `Skipped` (LRS and Premium), and 2 `SkippedNotOptedIn` (missing tag and value `maybe`). The last `SUMMARY`
reports `discovered=9`, `candidates=4`, `patchesSubmitted=0`. A different count means the fixture or
permissions differ; reconcile it before granting write access.

## 6. Guards and the denied-write check

Run the following **while the identity still has only the reader role**. Each command should report
`Failed`; inspect its own job output before running the next. The first five must submit **zero** PATCHes.

```bash
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB"
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" AccountName="$UNTAGGED"
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" AccountName=nosuchaccount0
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" AccountName="$UNTAGGED" RequireOptInTag=false
run_job Mode=Remediate ScopeType=Subscription SubscriptionId="$SUB" AccountName="$TARGET"
```

Expected `abortReason`, in order: `InvalidParameters`, `TargetNotEligible`, `NoAccountMatched`,
`InvalidParameters`, `InvalidParameters`. Now prove the reader cannot write:

```bash
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" \
  AccountName="$TARGET" ExpectedChanges=1 MaxChanges=1
az storage account show --name "$TARGET" --resource-group "$FIXTURE_RG" --query accessTier -o tsv
```

**Checkpoint** — `Failed`, `abortReason=Forbidden`, one `INTENT`, `patchesSubmitted=1` (one refused request),
and account still `Hot`. This is an attempted write denied by RBAC; it is not a zero-request guard. Save the
job ID. If it succeeds, stop: another grant or writer is present.

## 7. Ring of one, verification, and immediate revoke

The Owner/User Access Administrator grants the temporary writer at the fixture group. The role allows
**all storage-account updates**, not just `accessTier`; Azure has no field-level action for this property.
Keep the Automation Account dedicated and run only one job at a time.

Record the deployment operator's confirmed object ID, which differs from the Automation identity in
`PRINCIPAL`. For an interactive human login,
[`az ad signed-in-user show`](https://learn.microsoft.com/cli/azure/ad/signed-in-user#az-ad-signed-in-user-show)
provides it:

```bash
DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
test -n "$DEPLOYER_OBJECT_ID"
declare -p DEPLOYER_OBJECT_ID >> "$EVIDENCE_DIR/session.env"
```

A service-principal or managed-identity operator should set `DEPLOYER_OBJECT_ID` to its already verified
principal object ID instead of running the interactive-user lookup. Stop if the operator's identity is
uncertain. Save the grant invocation's time window, complete output and exit code even if the helper fails:

```bash
WRITER_GRANT_STARTED_UTC=$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')
declare -p WRITER_GRANT_STARTED_UTC >> "$EVIDENCE_DIR/session.env"
if scripts/ring-role.sh grant "$SUB" "$FIXTURE_RG" "$PRINCIPAL" > "$EVIDENCE_DIR/writer-grant.log" 2>&1; then
  WRITER_GRANT_EXIT=0
else
  WRITER_GRANT_EXIT=$?
fi
WRITER_GRANT_FINISHED_UTC=$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')
declare -p WRITER_GRANT_FINISHED_UTC WRITER_GRANT_EXIT >> "$EVIDENCE_DIR/session.env"
cat "$EVIDENCE_DIR/writer-grant.log"
test "$WRITER_GRANT_EXIT" -eq 0
az storage account show --name "$TARGET" --resource-group "$FIXTURE_RG" \
  -o json > "$EVIDENCE_DIR/before.json"
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" \
  AccountName="$TARGET" ExpectedChanges=1 MaxChanges=1
```

If the helper stops with `Created role is not readable yet`, its definition creation already succeeded.
The final exit-code check closes this dedicated shell on failure; recover `session.env` using the recovery
section before running the commands below. Retain `writer-grant.log` and its saved time window.
Do not repeatedly invoke the whole grant after a missing list result: role reads can lag or alternate during
propagation. Inspect and save the definition once it becomes visible:

```bash
az role definition list --subscription "$SUB" --scope "$SCOPE" --name "$WRITER_ROLE" \
  --custom-role-only true -o json > "$EVIDENCE_DIR/writer-role-readback.json"
jq '.[] | {id, roleName, assignableScopes, permissions, description, createdBy, createdOn, updatedBy, updatedOn}' \
  "$EVIDENCE_DIR/writer-role-readback.json"
```

Verify that exactly one returned definition matches the checked-in
[writer permission/description template](../infra/rbac/storage-remediator-role.template.json), has **only**
`$SCOPE` as its assignable scope, has `createdBy`/`updatedBy` equal to `$DEPLOYER_OBJECT_ID`,
and has `createdOn`/`updatedOn` inside `$WRITER_GRANT_STARTED_UTC`–`$WRITER_GRANT_FINISHED_UTC`. Preserve its exact ID. Stop if any ownership field
is uncertain; a matching display name alone is insufficient. The [live-test recovery](LIVE-TEST-2026-09-06.md#writer-definition-propagation-recovery)
required three stable exact-ID reads before retrying only the assignment command below:

```bash
WRITER_ROLE_ID='PASTE_THE_VERIFIED_ROLE_DEFINITION_ID'
declare -p WRITER_ROLE_ID >> "$EVIDENCE_DIR/session.env"
for attempt in 1 2 3; do
  az rest --method get --url "$ARM$WRITER_ROLE_ID?api-version=2022-04-01" \
    -o json > "$EVIDENCE_DIR/writer-role-guid-$attempt.json"
  jq '.properties | {roleName, assignableScopes, permissions, description, createdBy, createdOn, updatedBy, updatedOn}' \
    "$EVIDENCE_DIR/writer-role-guid-$attempt.json"
  if [ "$attempt" -lt 3 ]; then sleep 10; fi
done
diff <(jq -S . "$EVIDENCE_DIR/writer-role-guid-1.json") <(jq -S . "$EVIDENCE_DIR/writer-role-guid-2.json")
diff <(jq -S . "$EVIDENCE_DIR/writer-role-guid-1.json") <(jq -S . "$EVIDENCE_DIR/writer-role-guid-3.json")
```

**Checkpoint** — all three exact-ID reads succeeded, both diffs are empty, and the fields match the
verified template, scope and creation event. Stop on a missing or changed read; do not recreate the role.
See Microsoft's [Role Definitions — Get](https://learn.microsoft.com/rest/api/authorization/role-definitions/get?view=rest-authorization-2022-04-01).
Then retry only the existing definition's assignment:

```bash
WRITER_ASSIGNMENT_ID=$(az role assignment create --subscription "$SUB" --assignee-object-id "$PRINCIPAL" \
  --assignee-principal-type ServicePrincipal --role "$WRITER_ROLE_ID" --scope "$SCOPE" \
  --query id -o tsv)
test -n "$WRITER_ASSIGNMENT_ID"
declare -p WRITER_ASSIGNMENT_ID >> "$EVIDENCE_DIR/session.env"
```

This recovery creates no new definition. Verify the identity's exact writer assignment and unchanged
account tier, then continue with the `before.json` capture and named-target `run_job` command from the
original block; do not repeat its helper invocation. Keep the initial helper failure in the evidence;
a successful direct assignment is an explicit recovery, not a successful initial helper invocation.

**Checkpoint** — job `Completed`; `WouldRemediate` → `INTENT` → `Remediated` (`Hot→Smart`, stage `Verify`);
last `SUMMARY` has `remediated=1`, `patchesSubmitted=1`. A `Forbidden` result can mean propagation lag or a
wrong/missing assignment: verify the exact identity/scope and current account tier before retrying. For
`WriteOutcomeUnknown`, inspect the account and job first; do not automatically resubmit a write.

```bash
az storage account show --name "$TARGET" --resource-group "$FIXTURE_RG" \
  -o json > "$EVIDENCE_DIR/after.json"
jq -e '.accessTier == "Smart"' "$EVIDENCE_DIR/after.json"
diff <(jq -S 'del(.accessTier)' "$EVIDENCE_DIR/before.json") \
     <(jq -S 'del(.accessTier)' "$EVIDENCE_DIR/after.json")
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" \
  AccountName="$TARGET" ExpectedChanges=1 MaxChanges=1
```

**Checkpoint** — Smart check is `true`, the property diff is empty, and the repeat is `Completed` with
`AlreadySmart`, `remediated=0`, `patchesSubmitted=0`. Investigate a nonempty property diff; do not discard
unexplained changes. Optionally repeat this before/after/repeat sequence for `${PREFIX}gzrscool` and
`${PREFIX}zrshns` to reproduce the additional historical qualification cases.

Optional lock check, while the writer is still present (requires lock permission):

```bash
az lock create --name smart-tier-fixture-lock --lock-type ReadOnly --resource-group "$FIXTURE_RG" \
  --resource-name "$LOCK_TARGET" --resource-type Microsoft.Storage/storageAccounts
run_job Mode=Remediate ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB" \
  AccountName="$LOCK_TARGET" ExpectedChanges=1 MaxChanges=1
az storage account show --name "$LOCK_TARGET" --resource-group "$FIXTURE_RG" --query accessTier -o tsv
az lock delete --name smart-tier-fixture-lock --resource-group "$FIXTURE_RG" \
  --resource-name "$LOCK_TARGET" --resource-type Microsoft.Storage/storageAccounts
```

**Checkpoint** — intentionally `Failed`, `BlockedScopeLock`, `locked=1`, target still `Hot`; the lock is
removed afterward. Remove only the fixture lock created above.

**Revoke immediately after testing, including if a job failed:**

```bash
scripts/ring-role.sh revoke "$SUB" "$FIXTURE_RG" "$PRINCIPAL"
az role assignment list --assignee-object-id "$PRINCIPAL" --scope "$SCOPE" --include-inherited \
  --fill-principal-name false -o table
run_job Mode=Audit ScopeType=ResourceGroup ResourceGroupName="$FIXTURE_RG" SubscriptionId="$SUB"
```

**Checkpoint** — helper exits zero after verified role removal, and only the reader remains. A nonzero
exit, shared-role conflict, or remaining/inherited writer requires administrator review; do not call the
write window closed. The helper checks its exact custom role, not every other possible grant. Final audit
must complete with nine accounts and zero PATCHes. With only the main target changed, expect 2 AlreadySmart
and 3 candidates; optional GZRS/HNS writes increase AlreadySmart and decrease candidates accordingly.

## 8. Troubleshooting and ongoing operation

| Symptom | Next check |
|---|---|
| `az: ... automation is not recognized` / incompatible extension | Verify CLI version, install/update the Automation extension, rerun `az version` |
| Automation account quota or unavailable runtime/package | Inspect the deployment error; choose another supported account region or request quota. Do not change the Az pin without validation |
| Storage name taken / SKU unavailable | Inspect the failed fixture deployment; choose a new prefix or supported region. Inspect/clean any partial fixture before starting again |
| Deployment `AuthorizationFailed` / provider unregistered | Check the signed-in tenant/subscription, the human's role scope, and provider registration |
| Job stays queued/running or produces no `SUMMARY` | Inspect its job ID in the Portal, Errors, runtime/packages, and saved metadata; do not start another writer job |
| Reader works but remediation is `Forbidden` | Check the managed identity's exact ring assignment, propagation, inherited deny assignments and locks |
| Revocation fails or a role is shared | Keep the error visible; have the role owner remove the exact assignment and verify access. Do not delete a shared definition |
| Teardown fails | Check remaining fixture lock, active jobs, role cleanup and the human's delete permission |

For ongoing use, schedule **Audit only**; every write remains a human-started, named-target job. Alert on
`counts.unknown > 0` or `counts.errors > 0`; investigate `locked` / `deferred`. Large audits may need job
stream export to Log Analytics because streams are bounded. No recurring schedule or Log Analytics
workspace is created by these templates. Record new source/runtime pins and fetch-back content when updating.

## Recover after closing the shell

The ignored `.generated/smart-tier-evidence.*` directory contains `session.env`, job results and account
evidence. Keep it until cleanup is verified. In a new Bash shell at the repository root, find your evidence
directory, load that exact session file, and reselect the subscription:

```bash
set -euo pipefail
umask 077
ls -d "$PWD"/.generated/smart-tier-evidence.*
read -r -p 'Paste the absolute evidence directory for this run: ' EVIDENCE_DIR
cat "$EVIDENCE_DIR/session.env"
```

Inspect the file locally: it should contain only the variable declarations saved by your own run. Confirm
the resource-group names and subscription before sourcing it; do not source a downloaded session file.

```bash
source "$EVIDENCE_DIR/session.env"
az account set --subscription "$SUB"
az account show --query '{subscription:id,name:name,tenant:tenantId}' -o table
```

Confirm the displayed subscription. Redefine `run_job` from step 3 only if you need another job. Inspect
active jobs before any write or teardown. If execution stopped between creation and saving a reader ID,
recover it with these read-only commands and inspect the returned exact scope/principal before cleanup:

```bash
az role definition list --scope "$SCOPE" --name "$READER_ROLE" --custom-role-only true -o json
az role assignment list --assignee-object-id "$PRINCIPAL" --scope "$SCOPE" \
  --fill-principal-name false -o json
```

Assign the confirmed IDs to `READER_ROLE_ID` and `READER_ASSIGNMENT_ID`; never substitute another principal's
assignment. If step 1 did not save `PRINCIPAL`, recover it with the account-show command in that step.
A partial deployment may leave resources: inspect them and revoke any writer before returning to cleanup.

## 9. Teardown the dedicated fixture

Keep your job IDs, summaries and before/after evidence privately. Finish or stop any active job in the
Portal, remove the optional fixture lock, and verify the writer revoke from step 7 **before** deleting
resources. These commands delete both dedicated groups and their contents; check their inventory first.

```bash
az resource list --resource-group "$FIXTURE_RG" --query '[].{name:name,type:type}' -o table
az resource list --resource-group "$AA_RG" --query '[].{name:name,type:type}' -o table
az lock list --resource-group "$FIXTURE_RG" -o table
az role assignment delete --ids "$READER_ASSIGNMENT_ID"
az role assignment list --assignee-object-id "$PRINCIPAL" --scope "$SCOPE" --include-inherited \
  --fill-principal-name false -o json
az role definition delete --name "${READER_ROLE_ID##*/}" --scope "$SCOPE"
az role definition list --scope "$SCOPE" --name "$READER_ROLE" --custom-role-only true -o json
```

**Checkpoint** — no unexpected resources/locks, the identity's assignment list is `[]`, and the reader
role list is `[]`. Stop if another principal now uses the reader definition; resolve that reuse before
continuing. The stored IDs identify only the objects created by this walkthrough.

A successful DELETE can precede consistent readback. The live test retained a strict post-delete failure
and later observed a stale writer name-list even while that role's exact-ID GET returned NotFound. Preserve
those results and continue only read-only observation of the saved role/assignment IDs and lists until
repeated checks agree on absence. Do not recreate or regrant a deleted role to recover cleanup, and do not
count authorization or transport errors as NotFound. The
[cleanup record](LIVE-TEST-2026-09-06.md#test-rbac-cleanup-and-final-inventory) shows the separate deletion and
read-convergence evidence.

```bash
az group delete --name "$FIXTURE_RG" --yes
az group delete --name "$AA_RG" --yes
az group exists --name "$FIXTURE_RG"
az group exists --name "$AA_RG"
```

**Checkpoint** — both are `false`. Deletion waits for Azure; a submitted asynchronous delete alone is not
proof of cleanup. Never use these group deletes for shared resources or storage containing real data.
Leaving Smart on a real account is a priced migration; this fixture teardown is not a production rollback.

## What has been proven

[validation.md](validation.md) records the earlier live runbook qualification: nine-account audit, guards,
named writes, property comparison, GZRS/HNS, idempotence and the live lock. Matching the basic walkthrough
proves the main ring-of-one path; optional cases need their own results before claiming full reproduction.
The 2026-09-05 documentation/helper review used offline validation and mocked Azure CLI regression tests.
It did not redeploy Azure. The [2026-09-06 live walkthrough test](LIVE-TEST-2026-09-06.md) subsequently found
and corrected the annotated-tag pin error. Its second attempt passed all sixteen expected job outcomes,
including the additional GZRS/HNS cases, full property comparisons, repeats, lock and test-identity RBAC
cleanup. A delayed first job, writer-definition propagation and post-delete visibility required the explicit
recoveries recorded there; the initial writer-helper grant did not pass unchanged. Final account/group and
temporary operator-grant teardown remains pending in that record.
