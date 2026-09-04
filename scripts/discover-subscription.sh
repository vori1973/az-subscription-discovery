#!/usr/bin/env bash
#
# discover-subscription.sh — read-only Azure subscription discovery.
#
# Queries one or more Azure subscriptions (and, optionally, a parent management group) for
# existing resource groups, networking topology, effective policy constraints, and observed
# naming conventions, and emits a single structured JSON document describing the findings.
#
# This script performs NO write/mutating Azure CLI calls. See scripts/README.md for details.
#
set -uo pipefail
# Intentionally not using `set -e`: a failure gathering one section must not abort the whole run.

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--subscription <id>]... [--management-group <id>] [--output <path>]

Read-only Azure subscription discovery. Emits a single JSON document describing existing
resource groups, VNets/subnets/peerings, effective policy constraints, and observed naming
conventions for one or more target subscriptions. Performs no write operations against Azure.

Options:
  --subscription <id>       Target subscription ID or name (repeatable). May be given multiple
                            times to scan several subscriptions in one run. Defaults to the
                            subscription currently active in the caller's Azure CLI context
                            (\`az account show\`) when omitted.
  --management-group <id>   Optional management group ID. If supplied and accessible, the script
                            attempts direct policy discovery at that scope in addition to the
                            subscription-level fallback (\`az policy state list\`).
  --output <path>           File path to write the JSON output. Defaults to stdout.
  -h, --help                Show this help text and exit.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --subscription 00000000-0000-0000-0000-000000000000 --output discovery.json
  ${SCRIPT_NAME} --subscription sub-a --subscription sub-b --management-group mg-contoso

Requires: Azure CLI (az), logged in; jq. Reader role on each target subscription is sufficient.
No write permissions are required or used.
EOF
}

log_warn() {
  echo "[warn] $*" >&2
}

log_info() {
  echo "[info] $*" >&2
}

log_error() {
  echo "[error] $*" >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

SUBSCRIPTIONS=()
MANAGEMENT_GROUP=""
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)
      if [[ $# -lt 2 ]]; then
        log_error "--subscription requires a value"
        usage
        exit 1
      fi
      SUBSCRIPTIONS+=("$2")
      shift 2
      ;;
    --management-group)
      if [[ $# -lt 2 ]]; then
        log_error "--management-group requires a value"
        usage
        exit 1
      fi
      MANAGEMENT_GROUP="$2"
      shift 2
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        log_error "--output requires a value"
        usage
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

command -v az >/dev/null 2>&1 || { log_error "Azure CLI ('az') not found on PATH."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "'jq' not found on PATH."; exit 1; }

SCRATCH_DIR=$(mktemp -d)
trap 'rm -rf "${SCRATCH_DIR}"' EXIT

# Runs an az CLI command, capturing stdout as JSON. On failure, logs a warning (without aborting
# the script) and returns a non-zero exit status; callers are expected to substitute an empty
# JSON array/object in that case so downstream sections remain independent.
run_az_json() {
  local desc="$1"
  shift
  local err_file
  err_file=$(mktemp "${SCRATCH_DIR}/err.XXXXXX")
  local out
  if out=$("$@" 2>"${err_file}"); then
    rm -f "${err_file}"
    printf '%s' "${out}"
    return 0
  else
    log_warn "${desc} failed: $(tr '\n' ' ' < "${err_file}")"
    rm -f "${err_file}"
    return 1
  fi
}

if [[ ${#SUBSCRIPTIONS[@]} -eq 0 ]]; then
  current_sub=$(az account show --query id -o tsv 2>/dev/null) || true
  if [[ -z "${current_sub:-}" ]]; then
    log_error "No --subscription supplied and unable to determine the active subscription via 'az account show'. Are you logged in?"
    exit 1
  fi
  SUBSCRIPTIONS=("${current_sub}")
fi

# ---------------------------------------------------------------------------
# meta
# ---------------------------------------------------------------------------

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null) || TENANT_ID=""
RUN_AS=$(az account show --query user.name -o tsv 2>/dev/null) || RUN_AS=""

# ---------------------------------------------------------------------------
# 1. Resource groups
# ---------------------------------------------------------------------------

rg_files=()
idx=0
for sub in "${SUBSCRIPTIONS[@]}"; do
  idx=$((idx + 1))
  if rg_raw=$(run_az_json "resource group listing for subscription ${sub}" \
      az group list --subscription "${sub}" -o json); then
    rg_annotated=$(jq --arg sub "${sub}" \
      '[.[] | {name: .name, location: .location, tags: (.tags // {}), subscriptionId: $sub}]' \
      <<<"${rg_raw}")
  else
    rg_annotated="[]"
  fi
  printf '%s' "${rg_annotated}" > "${SCRATCH_DIR}/rg_${idx}.json"
  rg_files+=("${SCRATCH_DIR}/rg_${idx}.json")
done
RESOURCE_GROUPS_JSON=$(jq -s 'add // []' "${rg_files[@]}")

# ---------------------------------------------------------------------------
# 2. Networking: VNets, subnets, peerings
# ---------------------------------------------------------------------------

vnet_entries_file="${SCRATCH_DIR}/vnets.jsonl"
: > "${vnet_entries_file}"

for sub in "${SUBSCRIPTIONS[@]}"; do
  if vnets_raw=$(run_az_json "VNet listing for subscription ${sub}" \
      az network vnet list --subscription "${sub}" -o json); then
    :
  else
    # Older Azure CLI versions require --resource-group for 'az network vnet list' (it isn't
    # subscription-wide). Fall back to listing per resource group discovered in section 1.
    log_info "Falling back to per-resource-group VNet listing for subscription ${sub} (subscription-wide 'az network vnet list' was rejected by this Azure CLI version)."
    rg_names_for_sub=$(jq -r --arg sub "${sub}" '[.[] | select(.subscriptionId == $sub) | .name][]' <<<"${RESOURCE_GROUPS_JSON}")
    per_rg_files=()
    rg_idx=0
    while IFS= read -r rg_name; do
      [[ -z "${rg_name}" ]] && continue
      rg_idx=$((rg_idx + 1))
      if rg_vnets=$(run_az_json "VNet listing for resource group ${rg_name} (subscription ${sub})" \
          az network vnet list --resource-group "${rg_name}" --subscription "${sub}" -o json); then
        printf '%s' "${rg_vnets}" > "${SCRATCH_DIR}/rgvnets_${sub//[^A-Za-z0-9]/_}_${rg_idx}.json"
        per_rg_files+=("${SCRATCH_DIR}/rgvnets_${sub//[^A-Za-z0-9]/_}_${rg_idx}.json")
      fi
    done <<<"${rg_names_for_sub}"
    if [[ ${#per_rg_files[@]} -gt 0 ]]; then
      vnets_raw=$(jq -s 'add // []' "${per_rg_files[@]}")
    else
      continue
    fi
  fi

  while IFS= read -r vnet; do
    [[ -z "${vnet}" ]] && continue
    v_name=$(jq -r '.name' <<<"${vnet}")
    v_rg=$(jq -r '.resourceGroup' <<<"${vnet}")
    v_id=$(jq -r '.id' <<<"${vnet}")
    v_address_space=$(jq -c '.addressSpace.addressPrefixes // []' <<<"${vnet}")

    if subnets_raw=$(run_az_json "subnet listing for VNet ${v_name} (subscription ${sub})" \
        az network vnet subnet list --resource-group "${v_rg}" --vnet-name "${v_name}" \
        --subscription "${sub}" -o json); then
      subnets_json=$(jq -c '[.[] | {
          name: .name,
          prefix: (.addressPrefix // (.addressPrefixes // [] | join(","))),
          delegation: ((.delegations // [])[0].serviceName // null)
        }]' <<<"${subnets_raw}")
    else
      subnets_json="[]"
    fi

    if peerings_raw=$(run_az_json "peering listing for VNet ${v_name} (subscription ${sub})" \
        az network vnet peering list --resource-group "${v_rg}" --vnet-name "${v_name}" \
        --subscription "${sub}" -o json); then
      peerings_json=$(jq -c '[.[] | {
          remoteVnetId: (.remoteVirtualNetwork.id // null),
          remoteSubscriptionId: ((.remoteVirtualNetwork.id // "") | (try capture("/subscriptions/(?<sid>[^/]+)/"; "i").sid catch null) // null)
        }]' <<<"${peerings_raw}")
    else
      peerings_json="[]"
    fi

    jq -n --arg name "${v_name}" --arg id "${v_id}" --arg sub "${sub}" --arg rg "${v_rg}" \
      --argjson addressSpace "${v_address_space}" --argjson subnets "${subnets_json}" \
      --argjson peerings "${peerings_json}" \
      '{name: $name, resourceId: $id, subscriptionId: $sub, resourceGroup: $rg,
        addressSpace: $addressSpace, subnets: $subnets, peerings: $peerings}' \
      >> "${vnet_entries_file}"
  done < <(jq -c '.[]' <<<"${vnets_raw}")
done

if [[ -s "${vnet_entries_file}" ]]; then
  VNETS_JSON=$(jq -s '.' "${vnet_entries_file}")
else
  VNETS_JSON="[]"
fi

# ---------------------------------------------------------------------------
# 3. Policy
# ---------------------------------------------------------------------------

assignments_files=()
compliance_files=()
idx=0
for sub in "${SUBSCRIPTIONS[@]}"; do
  idx=$((idx + 1))

  if assignments_raw=$(run_az_json "policy assignment listing for subscription ${sub}" \
      az policy assignment list --disable-scope-strict-match --subscription "${sub}" -o json); then
    assignments_annotated=$(jq --arg sub "${sub}" '[.[] | . + {subscriptionId: $sub}]' <<<"${assignments_raw}")
  else
    assignments_annotated="[]"
  fi
  printf '%s' "${assignments_annotated}" > "${SCRATCH_DIR}/assign_${idx}.json"
  assignments_files+=("${SCRATCH_DIR}/assign_${idx}.json")

  if compliance_raw=$(run_az_json "policy compliance state listing for subscription ${sub}" \
      az policy state list --subscription "${sub}" -o json); then
    compliance_tuples=$(jq --arg sub "${sub}" '[.[] | {
        assignmentName: (.policyAssignmentName // .PolicyAssignmentName // null),
        definitionName: (.policyDefinitionName // .PolicyDefinitionName // null),
        definitionId: (.policyDefinitionId // .PolicyDefinitionId // null),
        scope: (.policyAssignmentScope // .PolicyAssignmentScope // null),
        effect: (.policyDefinitionAction // .PolicyDefinitionAction // null),
        subscriptionId: $sub
      }] | unique' <<<"${compliance_raw}")
  else
    compliance_tuples="[]"
  fi
  printf '%s' "${compliance_tuples}" > "${SCRATCH_DIR}/compliance_${idx}.json"
  compliance_files+=("${SCRATCH_DIR}/compliance_${idx}.json")
done

ASSIGNMENTS_VISIBLE_JSON=$(jq -s 'add // []' "${assignments_files[@]}")
EFFECTIVE_COMPLIANCE_JSON=$(jq -s 'add // [] | unique' "${compliance_files[@]}")

RELEVANT_DENY_MODIFY_JSON=$(jq -c '[.[] | select(
    (((.effect // "") | ascii_downcase) as $e | ($e == "deny" or $e == "modify"))
    or ((.definitionName // "") | test("PublicNetwork|LocalAuth|SKU|Limit|Capacity"; "i"))
  )]' <<<"${EFFECTIVE_COMPLIANCE_JSON}")

# ---------------------------------------------------------------------------
# 3a. Policy definition + assignment detail expansion for the Deny/Modify shortlist
# ---------------------------------------------------------------------------

# Attach assignment detail (from the already-collected ASSIGNMENTS_VISIBLE_JSON) to each
# shortlist entry, keyed by assignmentName. Assignments inherited from an inaccessible
# management-group scope won't be in ASSIGNMENTS_VISIBLE_JSON, so assignmentDetail is null there.
RELEVANT_DENY_MODIFY_JSON=$(jq -c --argjson assignments "${ASSIGNMENTS_VISIBLE_JSON}" '
  ($assignments | INDEX(.name)) as $byName
  | [.[] | . + {assignmentDetail: (
      $byName[.assignmentName // ""] as $a
      | if $a == null then null else {
          name: $a.name, displayName: $a.displayName, scope: $a.scope,
          policyDefinitionId: $a.policyDefinitionId, parameters: ($a.parameters // {}),
          enforcementMode: $a.enforcementMode, notScopes: ($a.notScopes // []),
          nonComplianceMessages: ($a.nonComplianceMessages // []), identity: $a.identity
        } end
    )}]
' <<<"${RELEVANT_DENY_MODIFY_JSON}")

# Resolve the full policy definition (via `az policy definition show`) for every distinct
# definition name in the shortlist, plus a simplified best-effort constraint summary derived
# from its policyRule. Best-effort/independent per definition: an unresolvable definition is
# reported as {name, error} rather than aborting discovery.
DEFINITIONS_TO_RESOLVE_JSON=$(jq -c '
  [ .[] | select(.definitionName != null) ]
  | group_by(.definitionName)
  | map({
      definitionName: .[0].definitionName,
      definitionId: (.[0].definitionId // null),
      subscriptionId: (.[0].subscriptionId // null),
      effect: (.[0].effect // null)
    })
' <<<"${RELEVANT_DENY_MODIFY_JSON}")

definitions_detail_files=()
didx=0
while IFS= read -r entry; do
  didx=$((didx + 1))
  def_name=$(jq -r '.definitionName' <<<"${entry}")
  def_id=$(jq -r '.definitionId // empty' <<<"${entry}")
  def_sub=$(jq -r '.subscriptionId // empty' <<<"${entry}")
  def_effect=$(jq -r '.effect // empty' <<<"${entry}")

  # Derive the correct scope flag from the compliance record's definitionId when available (it
  # encodes whether the definition lives under a management group, a subscription, or is a
  # tenant-wide built-in) - this avoids guessing at scope.
  scope_args=()
  if [[ -n "${def_id}" ]]; then
    def_id_lc="${def_id,,}"
    if [[ "${def_id_lc}" == *"/managementgroups/"* ]]; then
      mg_id=$(sed -E 's#.*/managementgroups/([^/]+)/.*#\1#' <<<"${def_id_lc}")
      scope_args=(--management-group "${mg_id}")
    elif [[ "${def_id_lc}" == *"/subscriptions/"* ]]; then
      sub_id=$(sed -E 's#.*/subscriptions/([^/]+)/.*#\1#' <<<"${def_id_lc}")
      scope_args=(--subscription "${sub_id}")
    fi
  fi

  definition_raw=""
  if [[ ${#scope_args[@]} -gt 0 ]]; then
    definition_raw=$(run_az_json "policy definition show for '${def_name}'" \
      az policy definition show --name "${def_name}" "${scope_args[@]}" -o json) || true
  fi
  if [[ -z "${definition_raw}" ]]; then
    definition_raw=$(run_az_json "policy definition show for '${def_name}' (bare name)" \
      az policy definition show --name "${def_name}" -o json) || true
  fi
  if [[ -z "${definition_raw}" && -n "${def_sub}" ]]; then
    definition_raw=$(run_az_json "policy definition show for '${def_name}' (subscription fallback)" \
      az policy definition show --name "${def_name}" --subscription "${def_sub}" -o json) || true
  fi
  if [[ -z "${definition_raw}" && -n "${MANAGEMENT_GROUP}" ]]; then
    definition_raw=$(run_az_json "policy definition show for '${def_name}' (management-group fallback)" \
      az policy definition show --name "${def_name}" --management-group "${MANAGEMENT_GROUP}" -o json) || true
  fi

  if [[ -n "${definition_raw}" ]]; then
    detail=$(jq -c --arg name "${def_name}" --arg effect "${def_effect}" '
      def contains_rg_segment($v):
        if ($v | type) == "string" then ($v | ascii_downcase | test("/resourcegroups/"))
        elif ($v | type) == "array" then any($v[]; (type == "string") and (. | ascii_downcase | test("/resourcegroups/")))
        else false end;
      def bucket_of($f; $v):
        ($f | ascii_downcase) as $fl
        | if $fl == "type" then "resourceTypesAffected"
          elif $fl == "name" then "namingRules"
          elif ($fl == "resourcegroup" or $fl == "resourcegroup.name" or $fl == "resourcegroupname") then "resourceGroupRules"
          elif ($fl == "id" or $fl == "fullname") and contains_rg_segment($v) then "resourceGroupRules"
          elif $fl == "location" then "locationRules"
          elif ($fl | startswith("tags")) then "tagRules"
          elif (($fl | startswith("microsoft.network/")) or ($fl | test("subnet|vnet|virtualnetwork|networksecuritygroup|publicip"))) then "networkRules"
          else null
          end;
      def field_conditions:
        if type == "object" then
          (if has("field") then
             ([keys[] | select(. != "field")] | first) as $opKey
             | [{field: .field, operator: $opKey, value: (if $opKey == null then null else .[$opKey] end)}]
           else [] end)
          + ([.[]? | field_conditions] | add // [])
        elif type == "array" then
          ([.[] | field_conditions] | add // [])
        else [] end;
      . as $def
      | ($def.policyRule.if // {} | field_conditions) as $conds
      | ($conds | map(select(bucket_of(.field; .value) == "resourceTypesAffected") | .value) | select(. != null) | flatten) as $typesRaw
      | ($typesRaw // [] | unique) as $types
      | ($conds | map(select(bucket_of(.field; .value) == "namingRules"))) as $naming
      | ($conds | map(select(bucket_of(.field; .value) == "resourceGroupRules"))) as $rgRules
      | ($conds | map(select(bucket_of(.field; .value) == "locationRules"))) as $locRules
      | ($conds | map(select(bucket_of(.field; .value) == "networkRules"))) as $netRules
      | ($conds | map(select(bucket_of(.field; .value) == "tagRules"))) as $tagRules
      | {
          definition: {
            name: ($def.name // $name),
            id: ($def.id // null),
            displayName: ($def.displayName // null),
            description: ($def.description // null),
            policyType: ($def.policyType // null),
            mode: ($def.mode // null),
            version: ($def.version // ($def.metadata.version) // null),
            metadata: ($def.metadata // {}),
            parameters: ($def.parameters // {}),
            policyRule: ($def.policyRule // {}),
            roleDefinitionIds: ($def.policyRule.then.details.roleDefinitionIds // [])
          },
          summary: {
            definitionName: ($def.name // $name),
            displayName: ($def.displayName // null),
            effect: (if $effect == "" then null else $effect end),
            resourceTypesAffected: $types,
            namingRules: $naming,
            resourceGroupRules: $rgRules,
            locationRules: $locRules,
            networkRules: $netRules,
            tagRules: $tagRules
          }
        }
    ' <<<"${definition_raw}")
  else
    log_warn "Unable to resolve policy definition '${def_name}'; reporting as unresolved."
    detail=$(jq -c -n --arg name "${def_name}" '{definition: {name: $name, error: "unresolved"}, summary: null}')
  fi

  printf '%s' "${detail}" > "${SCRATCH_DIR}/def_${didx}.json"
  definitions_detail_files+=("${SCRATCH_DIR}/def_${didx}.json")
done < <(jq -c '.[]' <<<"${DEFINITIONS_TO_RESOLVE_JSON}")

if [[ ${#definitions_detail_files[@]} -gt 0 ]]; then
  DEFINITIONS_DETAIL_COMBINED_JSON=$(jq -s '.' "${definitions_detail_files[@]}")
else
  DEFINITIONS_DETAIL_COMBINED_JSON="[]"
fi

POLICY_DEFINITIONS_DETAIL_JSON=$(jq -c '[.[].definition]' <<<"${DEFINITIONS_DETAIL_COMBINED_JSON}")
POLICY_DEFINITIONS_SIMPLIFIED_JSON=$(jq -c '[.[].summary | select(. != null)]' <<<"${DEFINITIONS_DETAIL_COMBINED_JSON}")

MG_ASSIGNMENTS_JSON="[]"
if [[ -n "${MANAGEMENT_GROUP}" ]]; then
  if mg_raw=$(run_az_json "policy assignment listing for management group ${MANAGEMENT_GROUP}" \
      az policy assignment list --disable-scope-strict-match \
      --scope "/providers/Microsoft.Management/managementGroups/${MANAGEMENT_GROUP}" -o json); then
    MG_ASSIGNMENTS_JSON=$(jq '[.[] | . + {managementGroupId: "'"${MANAGEMENT_GROUP}"'"}]' <<<"${mg_raw}")
  else
    log_warn "Direct policy discovery at management group '${MANAGEMENT_GROUP}' was not accessible; relying on subscription-level 'policy state list' results only."
  fi
fi

POLICY_JSON=$(jq -n \
  --argjson assignmentsVisible "${ASSIGNMENTS_VISIBLE_JSON}" \
  --argjson effectiveFromComplianceState "${EFFECTIVE_COMPLIANCE_JSON}" \
  --argjson relevantDenyOrModify "${RELEVANT_DENY_MODIFY_JSON}" \
  --argjson managementGroupAssignments "${MG_ASSIGNMENTS_JSON}" \
  --argjson definitionsDetail "${POLICY_DEFINITIONS_DETAIL_JSON}" \
  --argjson definitionsSimplified "${POLICY_DEFINITIONS_SIMPLIFIED_JSON}" \
  '{assignmentsVisible: $assignmentsVisible,
    effectiveFromComplianceState: $effectiveFromComplianceState,
    relevantDenyOrModify: $relevantDenyOrModify,
    managementGroupAssignments: $managementGroupAssignments,
    definitionsDetail: $definitionsDetail,
    definitionsSimplified: $definitionsSimplified}')

# ---------------------------------------------------------------------------
# 4. Platform readiness discovery (RBAC, providers, private endpoints, private DNS, quotas)
# ---------------------------------------------------------------------------
# Each of these is independent and best-effort: a failure or access denial in one SHALL NOT
# prevent any other section (new or pre-existing) from being gathered and reported.

# --- 4a. RBAC: role assignments + custom role definitions ---

rbac_assignment_files=()
rbac_customrole_files=()
idx=0
for sub in "${SUBSCRIPTIONS[@]}"; do
  idx=$((idx + 1))

  if assignments_raw=$(run_az_json "role assignment listing for subscription ${sub}" \
      az role assignment list --all --subscription "${sub}" -o json); then
    assignments_annotated=$(jq --arg sub "${sub}" '[.[] | {
        principalId: (.principalId // null),
        principalType: (.principalType // null),
        roleDefinitionName: (.roleDefinitionName // null),
        scope: (.scope // null),
        subscriptionId: $sub
      }]' <<<"${assignments_raw}")
  else
    assignments_annotated="[]"
  fi
  printf '%s' "${assignments_annotated}" > "${SCRATCH_DIR}/rbac_assign_${idx}.json"
  rbac_assignment_files+=("${SCRATCH_DIR}/rbac_assign_${idx}.json")

  if customroles_raw=$(run_az_json "custom role definition listing for subscription ${sub}" \
      az role definition list --custom-role-only true --subscription "${sub}" -o json); then
    customroles_annotated=$(jq --arg sub "${sub}" '[.[] | {
        name: (.roleName // .name // null),
        id: (.id // null),
        assignableScopes: (.assignableScopes // []),
        subscriptionId: $sub
      }]' <<<"${customroles_raw}")
  else
    customroles_annotated="[]"
  fi
  printf '%s' "${customroles_annotated}" > "${SCRATCH_DIR}/rbac_customrole_${idx}.json"
  rbac_customrole_files+=("${SCRATCH_DIR}/rbac_customrole_${idx}.json")
done

RBAC_ASSIGNMENTS_JSON=$(jq -s 'add // []' "${rbac_assignment_files[@]}")
RBAC_CUSTOM_ROLES_JSON=$(jq -s 'add // [] | unique_by(.id)' "${rbac_customrole_files[@]}")

RBAC_OWNERSHIP_SUMMARY_JSON=$(jq -c '
  group_by(.roleDefinitionName)
  | map({key: (.[0].roleDefinitionName // "unknown"), value: length})
  | from_entries
' <<<"${RBAC_ASSIGNMENTS_JSON}")

RBAC_JSON=$(jq -n \
  --argjson assignments "${RBAC_ASSIGNMENTS_JSON}" \
  --argjson customRoles "${RBAC_CUSTOM_ROLES_JSON}" \
  --argjson ownershipSummary "${RBAC_OWNERSHIP_SUMMARY_JSON}" \
  '{assignments: $assignments, customRoles: $customRoles, ownershipSummary: $ownershipSummary}')

# --- 4b. Resource provider registration (fixed priority list) ---

PRIORITY_PROVIDERS_JSON='["Microsoft.CognitiveServices","Microsoft.ApiManagement","Microsoft.Search","Microsoft.ContainerService","Microsoft.KeyVault","Microsoft.Web","Microsoft.Network","Microsoft.OperationalInsights"]'

provider_files=()
idx=0
for sub in "${SUBSCRIPTIONS[@]}"; do
  idx=$((idx + 1))
  if providers_raw=$(run_az_json "provider listing for subscription ${sub}" \
      az provider list --subscription "${sub}" -o json); then
    providers_annotated=$(jq --arg sub "${sub}" --argjson priority "${PRIORITY_PROVIDERS_JSON}" '
      ($priority | map({key: ., value: "NotFound"}) | from_entries) as $defaults
      | ([.[] | {key: .namespace, value: (.registrationState // "Unknown")}] | from_entries) as $found
      | ($defaults + $found) as $merged
      | [$priority[] | {namespace: ., registrationState: $merged[.], subscriptionId: $sub}]
    ' <<<"${providers_raw}")
  else
    providers_annotated=$(jq -n --arg sub "${sub}" --argjson priority "${PRIORITY_PROVIDERS_JSON}" \
      '[$priority[] | {namespace: ., registrationState: "Unknown", subscriptionId: $sub}]')
  fi
  printf '%s' "${providers_annotated}" > "${SCRATCH_DIR}/providers_${idx}.json"
  provider_files+=("${SCRATCH_DIR}/providers_${idx}.json")
done
PROVIDERS_JSON=$(jq -s 'add // []' "${provider_files[@]}")

# --- 4c. Private Endpoint discovery ---

pe_files=()
idx=0
for sub in "${SUBSCRIPTIONS[@]}"; do
  idx=$((idx + 1))
  if pe_raw=$(run_az_json "private endpoint listing for subscription ${sub}" \
      az network private-endpoint list --subscription "${sub}" -o json); then
    pe_annotated=$(jq --arg sub "${sub}" '[.[] | {
        name: .name,
        resourceGroup: .resourceGroup,
        subnet: (.subnet.id // null),
        subscriptionId: $sub,
        connections: [
          (.privateLinkServiceConnections // [])[]?,
          (.manualPrivateLinkServiceConnections // [])[]?
          | {targetResourceId: (.privateLinkServiceId // null),
             status: (.privateLinkServiceConnectionState.status // null)}
        ]
      }]' <<<"${pe_raw}")
  else
    pe_annotated="[]"
  fi
  printf '%s' "${pe_annotated}" > "${SCRATCH_DIR}/pe_${idx}.json"
  pe_files+=("${SCRATCH_DIR}/pe_${idx}.json")
done
PRIVATE_ENDPOINTS_JSON=$(jq -s 'add // []' "${pe_files[@]}")

# --- 4d. Private DNS discovery (zones + VNet links) ---

dns_entries_file="${SCRATCH_DIR}/dns_zones.jsonl"
: > "${dns_entries_file}"

for sub in "${SUBSCRIPTIONS[@]}"; do
  if zones_raw=$(run_az_json "private DNS zone listing for subscription ${sub}" \
      az network private-dns zone list --subscription "${sub}" -o json); then
    :
  else
    zones_raw="[]"
  fi

  while IFS= read -r zone; do
    [[ -z "${zone}" ]] && continue
    z_name=$(jq -r '.name' <<<"${zone}")
    z_rg=$(jq -r '.resourceGroup' <<<"${zone}")
    if links_raw=$(run_az_json "private DNS VNet link listing for zone ${z_name} (subscription ${sub})" \
        az network private-dns link vnet list --resource-group "${z_rg}" --zone-name "${z_name}" \
        --subscription "${sub}" -o json); then
      linked_vnets=$(jq -c '
        [.[] | (.virtualNetwork.id // "") | (try capture("/virtualNetworks/(?<n>[^/]+)$"; "i").n catch null)]
        | map(select(. != null))
      ' <<<"${links_raw}")
    else
      linked_vnets="[]"
    fi
    jq -n --arg name "${z_name}" --arg rg "${z_rg}" --arg sub "${sub}" --argjson linkedVnets "${linked_vnets}" \
      '{name: $name, resourceGroup: $rg, subscriptionId: $sub, linkedVnets: $linkedVnets}' \
      >> "${dns_entries_file}"
  done < <(jq -c '.[]' <<<"${zones_raw}")
done

if [[ -s "${dns_entries_file}" ]]; then
  PRIVATE_DNS_JSON=$(jq -s '.' "${dns_entries_file}")
else
  PRIVATE_DNS_JSON="[]"
fi

# --- 4e. Quota/usage discovery ---
# Regions are derived from already-discovered resource group locations (deduplicated), avoiding
# any new region-discovery API call. Falls back to a fixed default region when the subscription
# has no discovered resource groups (e.g. a brand-new, empty subscription).

QUOTA_REGIONS_JSON=$(jq -c '[.[].location] | map(select(. != null and . != "")) | unique' <<<"${RESOURCE_GROUPS_JSON}")
if [[ "$(jq 'length' <<<"${QUOTA_REGIONS_JSON}")" -eq 0 ]]; then
  QUOTA_REGIONS_JSON='["eastus"]'
  log_info "No resource group locations discovered; defaulting quota region to eastus."
fi

quota_entries_file="${SCRATCH_DIR}/quotas.jsonl"
: > "${quota_entries_file}"

for sub in "${SUBSCRIPTIONS[@]}"; do
  while IFS= read -r region; do
    [[ -z "${region}" ]] && continue
    if vm_usage_raw=$(run_az_json "VM usage listing for region ${region} (subscription ${sub})" \
        az vm list-usage --location "${region}" --subscription "${sub}" -o json); then
      jq -c --arg region "${region}" --arg sub "${sub}" --arg category "compute" '
        .[] | {region: $region, category: $category,
               name: (.localName // .name.value // .name // null),
               currentValue: .currentValue, limit: .limit, subscriptionId: $sub}
      ' <<<"${vm_usage_raw}" >> "${quota_entries_file}"
    fi
    if net_usage_raw=$(run_az_json "network usage listing for region ${region} (subscription ${sub})" \
        az network list-usages --location "${region}" --subscription "${sub}" -o json); then
      jq -c --arg region "${region}" --arg sub "${sub}" --arg category "network" '
        .[] | {region: $region, category: $category,
               name: (.localName // .name.value // .name // null),
               currentValue: .currentValue, limit: .limit, subscriptionId: $sub}
      ' <<<"${net_usage_raw}" >> "${quota_entries_file}"
    fi
  done < <(jq -r '.[]' <<<"${QUOTA_REGIONS_JSON}")
done

if [[ -s "${quota_entries_file}" ]]; then
  QUOTAS_JSON=$(jq -s '.' "${quota_entries_file}")
else
  QUOTAS_JSON="[]"
fi

# ---------------------------------------------------------------------------
# 5. Observed naming conventions (best-effort, not authoritative)
# ---------------------------------------------------------------------------

RG_NAMES_JSON=$(jq -c '[.[].name]' <<<"${RESOURCE_GROUPS_JSON}")
VNET_NAMES_JSON=$(jq -c '[.[].name]' <<<"${VNETS_JSON}")
SUBNET_NAMES_JSON=$(jq -c '[.[].subnets[].name]' <<<"${VNETS_JSON}")

naming_summary() {
  # $1: JSON array of names -> {commonPrefixes, sampleSize}
  jq -n --argjson names "$1" '
    ($names | map(split("-")[0])) as $prefixes
    | ($prefixes | group_by(.) | map({prefix: .[0], count: length}) | sort_by(-.count)) as $counts
    | {commonPrefixes: [$counts[] | select(.count > 1) | .prefix], sampleSize: ($names | length)}
  '
}

RG_NAMING_JSON=$(naming_summary "${RG_NAMES_JSON}")

NAMING_OBSERVED_JSON=$(jq -n \
  --argjson resourceGroups "${RG_NAMING_JSON}" \
  --argjson vnetNames "${VNET_NAMES_JSON}" \
  --argjson subnetNames "${SUBNET_NAMES_JSON}" \
  '{resourceGroups: $resourceGroups,
    byResourceType: {
      "Microsoft.Network/virtualNetworks": ($vnetNames | unique),
      "Microsoft.Network/virtualNetworks/subnets": ($subnetNames | unique)
    }}')

# ---------------------------------------------------------------------------
# 6. Architecture constraint synthesis (best-effort, cross-section)
# ---------------------------------------------------------------------------
# Runs last: reads from networking, policy, and naming sections already assembled above rather
# than issuing any new 'az' calls itself.

# Hub VNet identification: the VNet with the strictly highest number of peerings. On a tie
# (including zero peerings for every VNet) the hub is left unidentified (null), per design.md.
HUB_JSON=$(jq -c '
  ([.[] | {name, resourceGroup, addressSpace, peeringCount: (.peerings | length)}]) as $counted
  | ($counted | map(.peeringCount) | (max // 0)) as $maxCount
  | ($counted | map(select(.peeringCount == $maxCount))) as $top
  | if ($maxCount > 0) and (($top | length) == 1) then $top[0] else null end
' <<<"${VNETS_JSON}")

HUB_PEERING_JSON=$(jq -c '.name // null' <<<"${HUB_JSON}")
NETWORK_RESOURCE_GROUP_JSON=$(jq -c '.resourceGroup // null' <<<"${HUB_JSON}")
VNET_ADDRESS_SPACE_JSON=$(jq -c '.addressSpace // null' <<<"${HUB_JSON}")

# resourceGroupNaming: direct pass-through of namingObserved.resourceGroups (no re-derivation).
RESOURCE_GROUP_NAMING_JSON="${RG_NAMING_JSON}"

# requiredTags: distinct tag keys referenced by any resolved definition's tagRules bucket
# (produced by expand-policy-definitions), extracted from field values like tags['Environment']
# or tags["Environment"] (bracket notation) or tags.Environment (dot notation).
REQUIRED_TAGS_JSON=$(jq -c '
  [
    .definitionsSimplified[]? .tagRules[]? .field
    | select(type == "string")
    | ( try (capture("tags\\[[\u0027\"](?<k>[^\u0027\"]+)[\u0027\"]\\]")).k catch null )
      // ( try (capture("^tags\\.(?<k>.+)$")).k catch null )
  ]
  | map(select(. != null))
  | unique
' <<<"${POLICY_JSON}")

ARCHITECTURE_CONSTRAINTS_JSON=$(jq -n \
  --argjson networkResourceGroup "${NETWORK_RESOURCE_GROUP_JSON}" \
  --argjson resourceGroupNaming "${RESOURCE_GROUP_NAMING_JSON}" \
  --argjson requiredTags "${REQUIRED_TAGS_JSON}" \
  --argjson vnetAddressSpace "${VNET_ADDRESS_SPACE_JSON}" \
  --argjson hubPeering "${HUB_PEERING_JSON}" \
  '{networkResourceGroup: $networkResourceGroup,
    resourceGroupNaming: $resourceGroupNaming,
    requiredTags: $requiredTags,
    vnetAddressSpace: $vnetAddressSpace,
    hubPeering: $hubPeering}')

# ---------------------------------------------------------------------------
# 7. Assemble output
# ---------------------------------------------------------------------------

SUBSCRIPTIONS_JSON=$(printf '%s\n' "${SUBSCRIPTIONS[@]}" | jq -R . | jq -s .)

# Large sections (e.g. quotas, policy) can exceed the OS's single-argument length limit
# (MAX_ARG_STRLEN, typically 128KB on Linux) if passed via --argjson on the command line. Write
# each section to a scratch file and load it with --slurpfile instead, which has no such limit.
final_json_dir="${SCRATCH_DIR}/final"
mkdir -p "${final_json_dir}"
printf '%s' "${SUBSCRIPTIONS_JSON}" > "${final_json_dir}/subscriptions.json"
printf '%s' "${RESOURCE_GROUPS_JSON}" > "${final_json_dir}/resourceGroups.json"
printf '%s' "${VNETS_JSON}" > "${final_json_dir}/vnets.json"
printf '%s' "${POLICY_JSON}" > "${final_json_dir}/policy.json"
printf '%s' "${RBAC_JSON}" > "${final_json_dir}/rbac.json"
printf '%s' "${PROVIDERS_JSON}" > "${final_json_dir}/providers.json"
printf '%s' "${PRIVATE_ENDPOINTS_JSON}" > "${final_json_dir}/privateEndpoints.json"
printf '%s' "${PRIVATE_DNS_JSON}" > "${final_json_dir}/privateDns.json"
printf '%s' "${QUOTAS_JSON}" > "${final_json_dir}/quotas.json"
printf '%s' "${NAMING_OBSERVED_JSON}" > "${final_json_dir}/namingObserved.json"
printf '%s' "${ARCHITECTURE_CONSTRAINTS_JSON}" > "${final_json_dir}/architectureConstraints.json"

FINAL_JSON=$(jq -n \
  --arg generatedAt "${GENERATED_AT}" \
  --arg tenantId "${TENANT_ID}" \
  --arg runAs "${RUN_AS}" \
  --slurpfile subscriptions "${final_json_dir}/subscriptions.json" \
  --slurpfile resourceGroups "${final_json_dir}/resourceGroups.json" \
  --slurpfile vnets "${final_json_dir}/vnets.json" \
  --slurpfile policy "${final_json_dir}/policy.json" \
  --slurpfile rbac "${final_json_dir}/rbac.json" \
  --slurpfile providers "${final_json_dir}/providers.json" \
  --slurpfile privateEndpoints "${final_json_dir}/privateEndpoints.json" \
  --slurpfile privateDns "${final_json_dir}/privateDns.json" \
  --slurpfile quotas "${final_json_dir}/quotas.json" \
  --slurpfile namingObserved "${final_json_dir}/namingObserved.json" \
  --slurpfile architectureConstraints "${final_json_dir}/architectureConstraints.json" \
  '{
    meta: {generatedAt: $generatedAt, tenantId: $tenantId, subscriptions: $subscriptions[0], runAs: $runAs},
    resourceGroups: $resourceGroups[0],
    networking: {vnets: $vnets[0]},
    policy: $policy[0],
    rbac: $rbac[0],
    providers: $providers[0],
    privateEndpoints: $privateEndpoints[0],
    privateDns: $privateDns[0],
    namingObserved: $namingObserved[0],
    quotas: $quotas[0],
    architectureConstraints: $architectureConstraints[0]
  }')

if [[ -z "${FINAL_JSON}" ]] || ! jq empty <<<"${FINAL_JSON}" >/dev/null 2>&1; then
  log_error "Assembled output failed JSON validation; aborting before write."
  exit 1
fi

if [[ -n "${OUTPUT_PATH}" ]]; then
  output_dir=$(dirname -- "${OUTPUT_PATH}")
  if [[ -n "${output_dir}" && "${output_dir}" != "." && ! -d "${output_dir}" ]]; then
    if ! mkdir -p -- "${output_dir}" 2>/dev/null; then
      log_error "Failed to create output directory '${output_dir}'."
      exit 1
    fi
  fi
  if printf '%s\n' "${FINAL_JSON}" | jq '.' > "${OUTPUT_PATH}" 2>"${SCRATCH_DIR}/write_err"; then
    log_info "Discovery output written to ${OUTPUT_PATH}"
  else
    log_error "Failed to write output to '${OUTPUT_PATH}': $(tr '\n' ' ' < "${SCRATCH_DIR}/write_err")"
    exit 1
  fi
else
  printf '%s\n' "${FINAL_JSON}" | jq '.'
fi
