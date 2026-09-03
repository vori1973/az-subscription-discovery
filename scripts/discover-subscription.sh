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
  if ! vnets_raw=$(run_az_json "VNet listing for subscription ${sub}" \
      az network vnet list --subscription "${sub}" -o json); then
    continue
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
  '{assignmentsVisible: $assignmentsVisible,
    effectiveFromComplianceState: $effectiveFromComplianceState,
    relevantDenyOrModify: $relevantDenyOrModify,
    managementGroupAssignments: $managementGroupAssignments}')

# ---------------------------------------------------------------------------
# 4. Observed naming conventions (best-effort, not authoritative)
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
# 5. Assemble output
# ---------------------------------------------------------------------------

SUBSCRIPTIONS_JSON=$(printf '%s\n' "${SUBSCRIPTIONS[@]}" | jq -R . | jq -s .)

FINAL_JSON=$(jq -n \
  --arg generatedAt "${GENERATED_AT}" \
  --arg tenantId "${TENANT_ID}" \
  --arg runAs "${RUN_AS}" \
  --argjson subscriptions "${SUBSCRIPTIONS_JSON}" \
  --argjson resourceGroups "${RESOURCE_GROUPS_JSON}" \
  --argjson vnets "${VNETS_JSON}" \
  --argjson policy "${POLICY_JSON}" \
  --argjson namingObserved "${NAMING_OBSERVED_JSON}" \
  '{
    meta: {generatedAt: $generatedAt, tenantId: $tenantId, subscriptions: $subscriptions, runAs: $runAs},
    resourceGroups: $resourceGroups,
    networking: {vnets: $vnets},
    policy: $policy,
    namingObserved: $namingObserved,
    quotas: {}
  }')

if ! jq empty <<<"${FINAL_JSON}" >/dev/null 2>&1; then
  log_error "Assembled output failed JSON validation; aborting before write."
  exit 1
fi

if [[ -n "${OUTPUT_PATH}" ]]; then
  printf '%s\n' "${FINAL_JSON}" | jq '.' > "${OUTPUT_PATH}"
  log_warn "Discovery output written to ${OUTPUT_PATH}"
else
  printf '%s\n' "${FINAL_JSON}" | jq '.'
fi
