#!/usr/bin/env bash
# Grant or revoke the temporary writer role for one ring (the resource group of the accounts you will change). The role definition is created with that
# scope as its only assignable scope and removed again on revoke.
# Usage: scripts/ring-role.sh grant|revoke <subscription-id> <ring-resource-group> <automation-identity-principal-id>
# Needs: az, jq; Owner or User Access Administrator on the ring resource group (roleDefinitions/write + roleAssignments/write).
set -euo pipefail
ACTION=${1:?grant|revoke}; SUB=${2:?subscription id}; RG=${3:?ring resource group}; PRINCIPAL=${4:?principal id of the Automation Account identity}
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"; ROLE="Azure Storage Smart Tier Remediator"; TEMPLATE="$(dirname "$0")/../infra/rbac/storage-remediator-role.template.json"

# Resolve by name, then use the immutable id. A same-named role from another ring or a
# shared definition must never be reused or deleted by this single-ring helper.
read_role() {
  ROLE_JSON=$(az role definition list --subscription "$SUB" --scope "$SCOPE" --name "$ROLE" --custom-role-only true -o json)
  jq -e 'type == "array" and length <= 1' <<< "$ROLE_JSON" >/dev/null
  ROLE_ID=''
  if [ "$(jq 'length' <<< "$ROLE_JSON")" -eq 1 ]; then
    if ! jq -e --arg role "$ROLE" --arg scope "$SCOPE" \
      '.[0] | .roleName == $role and (.assignableScopes | map(ascii_downcase)) == [($scope | ascii_downcase)] and (.id | type == "string" and length > 0)' \
      <<< "$ROLE_JSON" >/dev/null; then
      echo "Refusing a same-named role whose only assignable scope is not $SCOPE; ask its owner to review it." >&2
      exit 1
    fi
    ROLE_ID=$(jq -er '.[0].id' <<< "$ROLE_JSON")
  fi
}

read_assignments() {
  ASSIGNMENTS=$(az role assignment list --subscription "$SUB" --scope "$SCOPE" \
    --fill-principal-name false --fill-role-definition-name false -o json)
  jq -e 'type == "array"' <<< "$ASSIGNMENTS" >/dev/null
}

case "$ACTION" in
  grant)
    read_role
    RENDERED=$(mktemp); sed "s#<subscription-id>#$SUB#; s#<ring-resource-group>#$RG#; s#REPLACE_WITH_SUBSCRIPTION_ID#$SUB#" "$TEMPLATE" > "$RENDERED"
    trap 'rm -f "$RENDERED"' EXIT
    if [ -n "$ROLE_ID" ]; then echo "role definition exists at the exact ring scope"; else
      az role definition create --subscription "$SUB" --role-definition @"$RENDERED" -o none
      echo "role definition created (assignable scope: $SCOPE)"
      read_role
      [ -n "$ROLE_ID" ] || { echo "Created role is not readable yet; wait and retry the grant." >&2; exit 1; }
    fi
    rm -f "$RENDERED"
    az role assignment create --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal --role "$ROLE_ID" --scope "$SCOPE" -o none
    echo "assigned to $PRINCIPAL at $SCOPE"
    echo "RBAC can take several minutes to propagate; a write refused with 403 before then is reported as Forbidden and nothing is changed." ;;
  revoke)
    read_role
    read_assignments
    if [ -z "$ROLE_ID" ]; then
      echo "No matching custom role definition exists; no assignment or definition was deleted."
      exit 0
    fi
    TARGET_IDS=$(jq -r --arg principal "$PRINCIPAL" --arg role "$ROLE_ID" --arg scope "$SCOPE" \
      '.[] | select((.principalId | ascii_downcase) == ($principal | ascii_downcase) and
        (.roleDefinitionId | ascii_downcase) == ($role | ascii_downcase) and
        (.scope | ascii_downcase) == ($scope | ascii_downcase)) | .id' <<< "$ASSIGNMENTS")
    while IFS= read -r assignment_id; do
      [ -n "$assignment_id" ] || continue
      az role assignment delete --subscription "$SUB" --ids "$assignment_id" -o none
    done <<< "$TARGET_IDS"
    read_assignments
    # Retain the definition if any visible assignment still uses it, including other
    # principals. Azure also refuses definition deletion while any assignment exists.
    if jq -e --arg role "$ROLE_ID" \
      'any(.[]; (.roleDefinitionId | ascii_downcase) == ($role | ascii_downcase))' \
      <<< "$ASSIGNMENTS" >/dev/null; then
      echo "Role assignments still use $ROLE_ID; definition retained. Review access before continuing." >&2
      exit 1
    fi
    az role definition delete --subscription "$SUB" --name "${ROLE_ID##*/}" --scope "$SCOPE" -o none
    read_role
    [ -z "$ROLE_ID" ] || { echo "Role definition still visible; revocation is not fully verified." >&2; exit 1; }
    echo "Verified: the ring role has no visible assignments and its definition is absent."
    echo "This checks this custom role only; inspect other and inherited roles separately." ;;
  *) echo "usage: $0 grant|revoke <subscription-id> <ring-resource-group> <principal-id>" >&2; exit 2 ;;
esac
