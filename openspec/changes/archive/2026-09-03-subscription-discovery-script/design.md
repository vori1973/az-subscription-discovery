# Design: Subscription Discovery Script

## Problem

The `agentic-ai-enterprise-blueprint` project generates Azure infrastructure (VNets, subnets,
Foundry, APIM, etc.) assuming a greenfield, single-subscription deployment. Real customer
subscriptions rarely match that assumption: a VNet/subnet may already exist, may live in a
different subscription (hub-spoke), and the subscription (or its parent management group) may
carry policy constraints — naming rules, deny rules, required configurations — that the
blueprint's generation logic doesn't know about.

Written requirements docs from customers (e.g. a one-page docx naming a target resource group,
subscription ID, and "use existing VNet") are typically too sparse to capture these constraints.
The only reliable source is the live subscription itself.

This change defines a **read-only discovery script** that queries a subscription (and, where
visible, its parent management group) and emits a single structured JSON artifact describing what
exists and what's constrained. That JSON is meant to be handed back as input for reasoning about
how the blueprint's Bicep modules should be parametrized for a given customer — the script itself
does not interpret the findings or modify the blueprint.

## Non-goals

- This script does not modify the blueprint's Bicep modules (that is separate, future work).
- This script does not write to Azure — it is read-only / diagnostic only.
- Naming convention detection is best-effort pattern mining, not authoritative — it is only
  authoritative when backed by a discoverable policy definition.

## Grounding: what we confirmed by running commands against a live subscription

- `az policy assignment list` (even with `--disable-scope-strict-match`) only reliably shows
  policy assigned at or below the scope the caller has Reader/similar access to. On a subscription
  where the caller only has subscription-level access, management-group-level assignments were
  invisible via this command.
- `az policy state list` (compliance evaluation results) surfaced the same management-group-level
  policies (an initiative called `Azure_Security_Baseline`, assigned at the Tenant Root
  Management Group) even though the assignment object itself was not visible. This is the more
  reliable signal for "what governance actually applies to me," and must be the primary source for
  the policy section of this script, not `policy assignment list`.
- The custom policy definitions discovered this way are mostly Deny/Modify/Audit rules on
  specific resource shapes (e.g. `AzureOpenAI_ProvisionedCapacity_Deny`,
  `StorageAccount_PublicNetwork_Modify`, `*_DisableLocalAuth_Modify`, `VirtualMachine_SKU_Deny`,
  `AKS_LimitNodeCount_Deny`) — these are the kind of "requirement" most likely to force changes to
  how the blueprint provisions a given resource type, more so than a naming convention would.
- A subnet always lives in the same subscription as its parent VNet. The "subnet must be created
  in a different subscription" scenario described by the user is understood to mean: workload
  resources deploy into subscription A, while the VNet/subnet they attach to (via cross-subscription
  resource ID reference / VNet injection) lives in subscription B. Discovery must therefore capture
  the subscription ID on every VNet/subnet resource, not assume it matches the resource group being
  targeted for deployment.

## Output shape

A single JSON document with independent, best-effort sections (a failure in one section — e.g. no
management group access — must not block the others):

```jsonc
{
  "meta": {
    "generatedAt": "...",
    "tenantId": "...",
    "subscriptions": ["..."],
    "runAs": "user@..."
  },
  "resourceGroups": [
    { "name": "...", "location": "...", "tags": {} }
  ],
  "networking": {
    "vnets": [
      {
        "name": "...",
        "resourceId": "...",
        "subscriptionId": "...",
        "resourceGroup": "...",
        "addressSpace": ["10.0.0.0/16"],
        "subnets": [
          { "name": "...", "prefix": "...", "delegation": "..." }
        ],
        "peerings": [
          { "remoteVnetId": "...", "remoteSubscriptionId": "..." }
        ]
      }
    ]
  },
  "policy": {
    "assignmentsVisible": [],
    "effectiveFromComplianceState": [],
    "relevantDenyOrModify": []
  },
  "namingObserved": {
    "resourceGroups": { "commonPrefixes": ["rg-", "..."], "sampleSize": 0 },
    "byResourceType": { "Microsoft.Network/virtualNetworks": ["..."] }
  },
  "quotas": {}
}
```

### Section notes

- `policy.assignmentsVisible`: raw output of `az policy assignment list --disable-scope-strict-match`.
  Included for completeness, but known to be incomplete when the caller lacks Reader at the scope
  where a policy is assigned.
- `policy.effectiveFromComplianceState`: distinct `(assignmentName, definitionName, scope, effect)`
  tuples derived from `az policy state list`. This is the primary source of truth for "what
  governance actually applies," including management-group-inherited rules invisible to
  `assignmentsVisible`.
- `policy.relevantDenyOrModify`: subset of the above filtered to definitions whose name/effect
  suggests they constrain resource shape — matching on effect (`Deny`, `Modify`) or name patterns
  (`PublicNetwork`, `LocalAuth`, `SKU`, `Limit`, `Capacity`). This is the shortlist meant to be
  reviewed first.
- `namingObserved`: explicitly labeled "observed," not "enforced." A simple frequency/prefix
  heuristic over existing resource names, grouped by resource type. Not to be treated as a rule
  unless corroborated by an actual policy definition in the `policy` section.
- `quotas`: placeholder for a later iteration (e.g. `az cognitiveservices usage list`,
  `az vm list-usage`) — out of scope for the first version of this script but reserved in the
  schema so downstream consumers don't need a schema change to add it.

## Inputs

- One or more subscription IDs (defaults to current `az account show` subscription if omitted).
- Optional management group ID, to attempt policy discovery at that scope directly if the caller
  has access (falls back to the `policy state list` method above if not).

## Permissions

- `Reader` on each target subscription is sufficient for the resource/networking sections.
- The policy section works even without management-group-level Reader, per the grounding notes
  above, because `az policy state list` surfaces compliance evaluation results rather than
  requiring access to the assignment object itself.
- No write permissions are required or used anywhere in this script.

## Open questions (deferred, not blocking a first version)

- Exact mechanism by which this JSON later informs the blueprint's Bicep parametrization
  (report consumed by a human vs. direct machine input to an "existing vs. create" branch in the
  network module) is intentionally out of scope for this change — to be addressed once real
  output from this script has been reviewed.
- Whether quota discovery belongs in this script or a separate one is deferred until the first
  version is validated against a real customer subscription.
