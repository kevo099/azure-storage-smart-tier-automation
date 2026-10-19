#!/usr/bin/env bash
# Publish (or update) the runbook in an Azure Automation account, link it to its PowerShell 7.4 runtime
# environment, and prove that the published bytes equal the local file (fetch-back SHA-256).
# Usage: SUBSCRIPTION_ID=… RESOURCE_GROUP=… AUTOMATION_ACCOUNT=… [RUNBOOK_NAME=Enable-AzStorageSmartTier] [RUNTIME_ENVIRONMENT=PowerShell74-SmartTier] \
#        [RUNBOOK_FILE=src/Enable-AzStorageSmartTier.ps1] [LOCATION=<explicit override>] scripts/publish-runbook.sh
# Needs: az CLI logged in with Contributor on the Automation Account's resource group. Exits non-zero on
# any mismatch, so it is safe to use in a release pipeline.
set -euo pipefail
umask 077
: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}" "${RESOURCE_GROUP:?set RESOURCE_GROUP}" "${AUTOMATION_ACCOUNT:?set AUTOMATION_ACCOUNT}"
RUNBOOK_NAME=${RUNBOOK_NAME:-Enable-AzStorageSmartTier}; RUNTIME_ENVIRONMENT=${RUNTIME_ENVIRONMENT:-PowerShell74-SmartTier}; RUNBOOK_FILE=${RUNBOOK_FILE:-src/Enable-AzStorageSmartTier.ps1}; LOCATION=${LOCATION:-}
ARM=https://management.azure.com; BASE="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT"
[ -f "$RUNBOOK_FILE" ] || { echo "runbook file not found: $RUNBOOK_FILE" >&2; exit 2; }
if [ -z "$LOCATION" ]; then
  LOCATION=$(az rest --method get --url "$BASE?api-version=2024-10-23" --query location -o tsv)
fi
[ -n "$LOCATION" ] || { echo "could not determine the Automation Account location; set LOCATION explicitly" >&2; exit 2; }
PUBLISH_WORK=$(mktemp -d)
trap 'rm -rf "$PUBLISH_WORK"' EXIT
REMOTE_CONTENT="$PUBLISH_WORK/published.ps1"
LOCAL_SHA=$(sha256sum "$RUNBOOK_FILE" | cut -c1-64)
echo "local  $RUNBOOK_FILE  sha256=$LOCAL_SHA"
echo "target Automation Account location=$LOCATION"
# 1 create the runbook if it does not exist (the CLI 'automation' group is marked experimental; warnings are harmless)
if ! az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" -o none 2>/dev/null; then
  az automation runbook create --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name "$RUNBOOK_NAME" --type PowerShell --location "$LOCATION" -o none 2>/dev/null
  echo "runbook created"
fi
# 2 upload exact bytes. Azure CLI's @file expansion strips trailing line endings,
# so both `automation runbook replace-content --content @file` and `az rest --body
# @file` can publish different bytes. Keep the token on stdin, never argv or disk.
arm_upload_request() {
  local method="$1" request_url="$2" response_file="$3" header_file="$4" token
  shift 4
  case "$request_url" in
    "$ARM"/*) ;;
    *) echo "Refusing an untrusted draft-operation URL" >&2; return 1 ;;
  esac
  token=$(az account get-access-token --subscription "$SUBSCRIPTION_ID" --resource "$ARM/" --query accessToken -o tsv)
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - \
    --silent --show-error --proto '=https' --connect-timeout 30 --max-time 120 \
    --request "$method" --url "$request_url" --output "$response_file" \
    --dump-header "$header_file" --write-out '%{http_code}' "$@"
}
response_header() {
  awk -v name="$1" 'tolower($1) == tolower(name) ":" {
    sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
  }' "$2"
}
DRAFT_STATUS=$(arm_upload_request PUT "$BASE/runbooks/$RUNBOOK_NAME/draft/content?api-version=2024-10-23" \
  "$PUBLISH_WORK/draft-response.json" "$PUBLISH_WORK/draft-headers.txt" \
  --header 'Content-Type: text/plain; charset=utf-8' --data-binary @"$RUNBOOK_FILE")
case "$DRAFT_STATUS" in
  200|201|204) ;;
  202)
    DRAFT_OPERATION_URL=$(response_header Azure-AsyncOperation "$PUBLISH_WORK/draft-headers.txt")
    DRAFT_OPERATION_KIND=async
    if [ -z "$DRAFT_OPERATION_URL" ]; then
      DRAFT_OPERATION_URL=$(response_header Location "$PUBLISH_WORK/draft-headers.txt")
      DRAFT_OPERATION_KIND=location
    fi
    [ -n "$DRAFT_OPERATION_URL" ] || { echo "Draft upload returned 202 without an operation URL" >&2; exit 1; }
    DRAFT_DEADLINE=$(( $(date +%s) + 600 ))
    DRAFT_DONE=false
    while [ "$(date +%s)" -lt "$DRAFT_DEADLINE" ]; do
      DRAFT_RETRY_AFTER=$(response_header Retry-After "$PUBLISH_WORK/draft-headers.txt")
      case "$DRAFT_RETRY_AFTER" in ''|*[!0-9]*) DRAFT_RETRY_AFTER=5 ;; esac
      [ "$DRAFT_RETRY_AFTER" -le 60 ] || DRAFT_RETRY_AFTER=60
      sleep "$DRAFT_RETRY_AFTER"
      DRAFT_STATUS=$(arm_upload_request GET "$DRAFT_OPERATION_URL" \
        "$PUBLISH_WORK/draft-response.json" "$PUBLISH_WORK/draft-headers.txt")
      case "$DRAFT_STATUS" in
        200|201|204)
          if [ "$DRAFT_OPERATION_KIND" = location ]; then DRAFT_DONE=true; break; fi
          DRAFT_OPERATION_STATE=$(jq -r '.status // .properties.status // empty' "$PUBLISH_WORK/draft-response.json")
          case "${DRAFT_OPERATION_STATE,,}" in
            succeeded) DRAFT_DONE=true; break ;;
            failed|canceled|cancelled) echo "Draft upload operation $DRAFT_OPERATION_STATE" >&2; exit 1 ;;
          esac
          ;;
        202) ;;
        *) echo "Draft upload poll returned HTTP $DRAFT_STATUS" >&2; exit 1 ;;
      esac
    done
    [ "$DRAFT_DONE" = true ] || { echo "Timed out waiting for draft upload" >&2; exit 1; }
    ;;
  *) echo "Draft upload returned HTTP $DRAFT_STATUS" >&2; exit 1 ;;
esac
az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME/draft/content?api-version=2024-10-23" \
  --output-file "$PUBLISH_WORK/draft.ps1"
DRAFT_SHA=$(sha256sum "$PUBLISH_WORK/draft.ps1" | cut -c1-64)
[ "$DRAFT_SHA" = "$LOCAL_SHA" ] || { echo "MISMATCH: draft bytes differ from the local file" >&2; exit 1; }
echo "draft content replaced and exact bytes verified"
# 3 link the runtime environment (not possible through the CLI; ARM PATCH)
az rest --method patch --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --body "{\"properties\":{\"runtimeEnvironment\":\"$RUNTIME_ENVIRONMENT\"}}" -o none
echo "runtime environment linked"
# 4 publish
az automation runbook publish --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --automation-account-name "$AUTOMATION_ACCOUNT" --name "$RUNBOOK_NAME" -o none 2>/dev/null
echo "publish request completed"
# 5 wait for publication to converge, then fetch back and compare
STATE=""; REMOTE_RUNTIME=""; REMOTE_SHA=""
for _ in $(seq 1 60); do
  STATE=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --query properties.state -o tsv)
  REMOTE_RUNTIME=$(az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME?api-version=2024-10-23" --query properties.runtimeEnvironment -o tsv)
  if az rest --method get --url "$BASE/runbooks/$RUNBOOK_NAME/content?api-version=2023-11-01" --output-file "$REMOTE_CONTENT" 2>/dev/null; then
    REMOTE_SHA=$(sha256sum "$REMOTE_CONTENT" | cut -c1-64)
    if [ "$STATE" = "Published" ] && [ "$REMOTE_RUNTIME" = "$RUNTIME_ENVIRONMENT" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
      break
    fi
  fi
  sleep 5
done
echo "remote state/runtime: $STATE $REMOTE_RUNTIME"
echo "remote sha256=$REMOTE_SHA"
[ "$STATE" = "Published" ] || { echo "MISMATCH: runbook is not Published" >&2; exit 1; }
[ "$REMOTE_RUNTIME" = "$RUNTIME_ENVIRONMENT" ] || { echo "MISMATCH: runtime environment differs" >&2; exit 1; }
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "MISMATCH: published bytes differ from the local file" >&2; exit 1; }
echo "OK: published bytes equal the local file"
