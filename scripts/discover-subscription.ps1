<#
.SYNOPSIS
    Read-only Azure subscription discovery.
.DESCRIPTION
    Queries one or more Azure subscriptions (and, optionally, a parent management group) for
    existing resource groups, networking topology, effective policy constraints, and observed
    naming conventions, and emits a single structured JSON document describing the findings.

    This script performs NO write/mutating Azure CLI calls. See scripts/README.md for details.
    Functionally equivalent to discover-subscription.sh, for use on PowerShell-only hosts
    (Windows PowerShell 5.1 is not supported; requires PowerShell 7+).
.PARAMETER Subscription
    One or more target subscription IDs or names (e.g. -Subscription sub-a,sub-b). Defaults to
    the subscription currently active in the caller's Azure CLI context (az account show) when
    omitted.
.PARAMETER ManagementGroup
    Optional management group ID. If supplied and accessible, attempts direct policy discovery
    at that scope in addition to the subscription-level fallback (az policy state list).
.PARAMETER Output
    File path to write the JSON output. Defaults to stdout.
.EXAMPLE
    ./discover-subscription.ps1
.EXAMPLE
    ./discover-subscription.ps1 -Subscription 00000000-0000-0000-0000-000000000000 -Output discovery.json
.EXAMPLE
    ./discover-subscription.ps1 -Subscription sub-a,sub-b -ManagementGroup mg-contoso
.NOTES
    Requires: Azure CLI (az), logged in. Reader role on each target subscription is sufficient.
    No write permissions are required or used.
#>
[CmdletBinding()]
param(
    [string[]] $Subscription = @(),
    [string] $ManagementGroup = '',
    [string] $Output = ''
)

# Intentionally not using `Set-StrictMode`/throwing on every error: a failure gathering one
# section must not abort the whole run.
$ErrorActionPreference = 'Continue'

function Write-Warn {
    param([string] $Message)
    Write-Warning $Message
}

function Write-Info {
    param([string] $Message)
    [Console]::Error.WriteLine("[info] $Message")
}

function Write-ErrorAndExit {
    param([string] $Message, [int] $Code = 1)
    Write-Error $Message
    exit $Code
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-ErrorAndExit "Azure CLI ('az') not found on PATH."
}

# Runs an az CLI command, capturing stdout as JSON. On failure, logs a warning (without aborting
# the script) and returns $null; callers are expected to substitute an empty JSON array/object in
# that case so downstream sections remain independent.
function Invoke-AzJson {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & az @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $errText = ((Get-Content -Raw -Path $stderrFile -ErrorAction SilentlyContinue) -replace "`r?`n", ' ').Trim()
            Write-Warn "$Description failed: $errText"
            return $null
        }
        $joined = ($stdout -join "`n")
        if ([string]::IsNullOrWhiteSpace($joined)) {
            return @()
        }
        try {
            return , (ConvertFrom-Json -InputObject $joined -Depth 100)
        }
        catch {
            Write-Warn "$Description returned output that could not be parsed as JSON: $($_.Exception.Message)"
            return $null
        }
    }
    finally {
        Remove-Item -Path $stderrFile -ErrorAction SilentlyContinue
    }
}

# Normalizes ConvertFrom-Json results to a PowerShell array (a single-element JSON array
# deserializes to a scalar object, not a collection, unless unrolled explicitly).
function ConvertTo-ArrayOrEmpty {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

if ($Subscription.Count -eq 0) {
    $currentSub = (& az account show --query id -o tsv 2>$null)
    if ([string]::IsNullOrWhiteSpace($currentSub)) {
        Write-ErrorAndExit "No -Subscription supplied and unable to determine the active subscription via 'az account show'. Are you logged in?"
    }
    $Subscription = @($currentSub.Trim())
}

# ---------------------------------------------------------------------------
# meta
# ---------------------------------------------------------------------------

$GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$TenantId = (& az account show --query tenantId -o tsv 2>$null)
$RunAs = (& az account show --query user.name -o tsv 2>$null)

# ---------------------------------------------------------------------------
# 1. Resource groups
# ---------------------------------------------------------------------------

$ResourceGroups = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $Subscription) {
    $rgRaw = Invoke-AzJson -Description "resource group listing for subscription $sub" `
        -Arguments @('group', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($rg in (ConvertTo-ArrayOrEmpty $rgRaw)) {
        $ResourceGroups.Add([ordered]@{
            name           = $rg.name
            location       = $rg.location
            tags           = if ($rg.tags) { $rg.tags } else { [ordered]@{} }
            subscriptionId = $sub
        })
    }
}

# ---------------------------------------------------------------------------
# 2. Networking: VNets, subnets, peerings
# ---------------------------------------------------------------------------

$Vnets = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $Subscription) {
    $vnetsRaw = Invoke-AzJson -Description "VNet listing for subscription $sub" `
        -Arguments @('network', 'vnet', 'list', '--subscription', $sub, '-o', 'json')
    if ($null -eq $vnetsRaw) {
        # Older Azure CLI versions require --resource-group for 'az network vnet list' (it isn't
        # subscription-wide). Fall back to listing per resource group discovered in section 1.
        Write-Info "Falling back to per-resource-group VNet listing for subscription $sub (subscription-wide 'az network vnet list' was rejected by this Azure CLI version)."
        $rgNamesForSub = @($ResourceGroups | Where-Object { $_.subscriptionId -eq $sub } | ForEach-Object { $_.name })
        $vnetsAccum = [System.Collections.Generic.List[object]]::new()
        foreach ($rgName in $rgNamesForSub) {
            $rgVnets = Invoke-AzJson -Description "VNet listing for resource group $rgName (subscription $sub)" `
                -Arguments @('network', 'vnet', 'list', '--resource-group', $rgName, '--subscription', $sub, '-o', 'json')
            foreach ($v in (ConvertTo-ArrayOrEmpty $rgVnets)) {
                $vnetsAccum.Add($v)
            }
        }
        if ($vnetsAccum.Count -eq 0) { continue }
        $vnetsRaw = $vnetsAccum
    }

    foreach ($vnet in (ConvertTo-ArrayOrEmpty $vnetsRaw)) {
        $vName = $vnet.name
        $vRg = $vnet.resourceGroup
        $vId = $vnet.id
        # NOTE: assigning inside each branch (not capturing the whole if-statement's output)
        # avoids PowerShell unwrapping a single-element array result to a bare scalar.
        if ($vnet.addressSpace.addressPrefixes) {
            $addressSpace = [string[]]@($vnet.addressSpace.addressPrefixes)
        }
        else {
            $addressSpace = [string[]]@()
        }

        $subnetsJson = @()
        $subnetsRaw = Invoke-AzJson -Description "subnet listing for VNet $vName (subscription $sub)" `
            -Arguments @('network', 'vnet', 'subnet', 'list', '--resource-group', $vRg, '--vnet-name', $vName, '--subscription', $sub, '-o', 'json')
        if ($null -ne $subnetsRaw) {
            foreach ($subnet in (ConvertTo-ArrayOrEmpty $subnetsRaw)) {
                $prefix = if ($subnet.addressPrefix) { $subnet.addressPrefix }
                          elseif ($subnet.addressPrefixes) { ($subnet.addressPrefixes -join ',') }
                          else { $null }
                $delegation = if ($subnet.delegations -and $subnet.delegations.Count -gt 0) { $subnet.delegations[0].serviceName } else { $null }
                $subnetsJson += [ordered]@{
                    name       = $subnet.name
                    prefix     = $prefix
                    delegation = $delegation
                }
            }
        }

        $peeringsJson = @()
        $peeringsRaw = Invoke-AzJson -Description "peering listing for VNet $vName (subscription $sub)" `
            -Arguments @('network', 'vnet', 'peering', 'list', '--resource-group', $vRg, '--vnet-name', $vName, '--subscription', $sub, '-o', 'json')
        if ($null -ne $peeringsRaw) {
            foreach ($peering in (ConvertTo-ArrayOrEmpty $peeringsRaw)) {
                $remoteId = $peering.remoteVirtualNetwork.id
                $remoteSub = $null
                if ($remoteId -and ($remoteId -match '/subscriptions/(?<sid>[^/]+)/')) {
                    $remoteSub = $Matches['sid']
                }
                $peeringsJson += [ordered]@{
                    remoteVnetId         = $remoteId
                    remoteSubscriptionId = $remoteSub
                }
            }
        }

        $Vnets.Add([ordered]@{
            name           = $vName
            resourceId     = $vId
            subscriptionId = $sub
            resourceGroup  = $vRg
            addressSpace   = $addressSpace
            subnets        = $subnetsJson
            peerings       = $peeringsJson
        })
    }
}

# ---------------------------------------------------------------------------
# 3. Policy
# ---------------------------------------------------------------------------

$AssignmentsVisible = [System.Collections.Generic.List[object]]::new()
$ComplianceTuplesAll = [System.Collections.Generic.List[object]]::new()

foreach ($sub in $Subscription) {
    $assignmentsRaw = Invoke-AzJson -Description "policy assignment listing for subscription $sub" `
        -Arguments @('policy', 'assignment', 'list', '--disable-scope-strict-match', '--subscription', $sub, '-o', 'json')
    foreach ($assignment in (ConvertTo-ArrayOrEmpty $assignmentsRaw)) {
        $withSub = [ordered]@{}
        foreach ($prop in $assignment.PSObject.Properties) {
            $withSub[$prop.Name] = $prop.Value
        }
        $withSub['subscriptionId'] = $sub
        $AssignmentsVisible.Add($withSub)
    }

    $complianceRaw = Invoke-AzJson -Description "policy compliance state listing for subscription $sub" `
        -Arguments @('policy', 'state', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($state in (ConvertTo-ArrayOrEmpty $complianceRaw)) {
        $assignmentName = if ($state.policyAssignmentName) { $state.policyAssignmentName } else { $state.PolicyAssignmentName }
        $definitionName = if ($state.policyDefinitionName) { $state.policyDefinitionName } else { $state.PolicyDefinitionName }
        $definitionId = if ($state.policyDefinitionId) { $state.policyDefinitionId } else { $state.PolicyDefinitionId }
        $scope = if ($state.policyAssignmentScope) { $state.policyAssignmentScope } else { $state.PolicyAssignmentScope }
        $effect = if ($state.policyDefinitionAction) { $state.policyDefinitionAction } else { $state.PolicyDefinitionAction }
        $ComplianceTuplesAll.Add([ordered]@{
            assignmentName = $assignmentName
            definitionName = $definitionName
            definitionId   = $definitionId
            scope          = $scope
            effect         = $effect
            subscriptionId = $sub
        })
    }
}

# Dedupe distinct (assignmentName, definitionName, definitionId, scope, effect, subscriptionId)
# tuples. (Sort-Object -Unique is unreliable for ordered-hashtable equality, so dedupe explicitly
# via a composite string key instead.)
$seenTuples = [System.Collections.Generic.HashSet[string]]::new()
$EffectiveCompliance = [System.Collections.Generic.List[object]]::new()
foreach ($tuple in $ComplianceTuplesAll) {
    $key = "$($tuple.assignmentName)|$($tuple.definitionName)|$($tuple.definitionId)|$($tuple.scope)|$($tuple.effect)|$($tuple.subscriptionId)"
    if ($seenTuples.Add($key)) {
        $EffectiveCompliance.Add($tuple)
    }
}

$NamingPatternRegex = 'PublicNetwork|LocalAuth|SKU|Limit|Capacity'
$RelevantDenyOrModify = @($EffectiveCompliance | Where-Object {
    $effect = [string]$_.effect
    $definitionName = [string]$_.definitionName
    ($effect -ieq 'deny') -or ($effect -ieq 'modify') -or ($definitionName -match $NamingPatternRegex)
})

$ManagementGroupAssignments = [System.Collections.Generic.List[object]]::new()
if ($ManagementGroup) {
    $mgScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroup"
    $mgRaw = Invoke-AzJson -Description "policy assignment listing for management group $ManagementGroup" `
        -Arguments @('policy', 'assignment', 'list', '--disable-scope-strict-match', '--scope', $mgScope, '-o', 'json')
    if ($null -ne $mgRaw) {
        foreach ($assignment in (ConvertTo-ArrayOrEmpty $mgRaw)) {
            $withMg = [ordered]@{}
            foreach ($prop in $assignment.PSObject.Properties) {
                $withMg[$prop.Name] = $prop.Value
            }
            $withMg['managementGroupId'] = $ManagementGroup
            $ManagementGroupAssignments.Add($withMg)
        }
    }
    else {
        Write-Warn "Direct policy discovery at management group '$ManagementGroup' was not accessible; relying on subscription-level 'policy state list' results only."
    }
}

# ---------------------------------------------------------------------------
# 3a. Policy definition + assignment detail expansion for the Deny/Modify shortlist
# ---------------------------------------------------------------------------

# Attach assignment detail (when the assignment is visible via 'policy assignment list') to each
# shortlisted Deny/Modify/naming-pattern entry. Copies are built explicitly rather than mutating
# $EffectiveCompliance entries in place, since those hashtable objects are shared references and
# mutating them would leak 'assignmentDetail' into effectiveFromComplianceState too.
$AssignmentsByName = @{}
foreach ($a in $AssignmentsVisible) {
    $an = [string]$a.name
    if ($an -and -not $AssignmentsByName.ContainsKey($an)) {
        $AssignmentsByName[$an] = $a
    }
}

$RelevantDenyOrModifyWithDetail = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $RelevantDenyOrModify) {
    $assignmentDetail = $null
    $an = [string]$entry.assignmentName
    if ($an -and $AssignmentsByName.ContainsKey($an)) {
        $a = $AssignmentsByName[$an]
        $assignmentDetail = [ordered]@{
            name                  = $a.name
            displayName           = $a.displayName
            scope                 = $a.scope
            policyDefinitionId    = $a.policyDefinitionId
            parameters            = if ($a.parameters) { $a.parameters } else { [ordered]@{} }
            enforcementMode       = $a.enforcementMode
            notScopes             = if ($a.notScopes) { @($a.notScopes) } else { @() }
            nonComplianceMessages = if ($a.nonComplianceMessages) { @($a.nonComplianceMessages) } else { @() }
            identity              = $a.identity
        }
    }
    $withDetail = [ordered]@{}
    foreach ($key in $entry.Keys) { $withDetail[$key] = $entry[$key] }
    $withDetail['assignmentDetail'] = $assignmentDetail
    $RelevantDenyOrModifyWithDetail.Add($withDetail)
}
$RelevantDenyOrModify = @($RelevantDenyOrModifyWithDetail)

# Derives the '--management-group <id>' or '--subscription <id>' scope arguments for
# 'az policy definition show' from a compliance record's policyDefinitionId path, which reliably
# encodes the scope the definition actually lives at (management group, subscription, or a bare
# tenant-wide built-in with no scope segment at all).
function Get-PolicyDefinitionScopeArgs {
    param([string] $DefinitionId)
    if (-not $DefinitionId) { return , (@()) }
    $lc = $DefinitionId.ToLowerInvariant()
    if ($lc -match '/managementgroups/([^/]+)') {
        return , (@('--management-group', $Matches[1]))
    }
    elseif ($lc -match '/subscriptions/([^/]+)') {
        return , (@('--subscription', $Matches[1]))
    }
    return , (@())
}

# Recursively walks a deserialized policyRule.if object graph, collecting every {field, operator,
# value} condition found (operator is whichever sibling key accompanies 'field', e.g. 'equals',
# 'like', 'match', 'notIn', 'exists' - this generalizes across all Azure Policy comparison
# operators without enumerating them individually).
function Get-PolicyRuleFieldConditions {
    param($Node)
    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Node) { return , (@($results)) }
    if ($Node -is [array]) {
        foreach ($item in $Node) {
            foreach ($r in (Get-PolicyRuleFieldConditions -Node $item)) { $results.Add($r) }
        }
        return , (@($results))
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $props = @($Node.PSObject.Properties)
        $fieldProp = $props | Where-Object { $_.Name -eq 'field' } | Select-Object -First 1
        if ($fieldProp) {
            $opProp = $props | Where-Object { $_.Name -ne 'field' } | Select-Object -First 1
            $results.Add([ordered]@{
                field    = $fieldProp.Value
                operator = if ($opProp) { $opProp.Name } else { $null }
                value    = if ($opProp) { $opProp.Value } else { $null }
            })
        }
        foreach ($prop in $props) {
            foreach ($r in (Get-PolicyRuleFieldConditions -Node $prop.Value)) { $results.Add($r) }
        }
        return , (@($results))
    }
    return , (@($results))
}

# True when a field's value (string or array of strings) contains a '/resourceGroups/' path
# segment - real Azure Policy has no literal 'resourceGroup' field alias, so resource-group
# constraints are expressed via the 'id'/'fullName' field with a like/match pattern instead.
function Test-ContainsResourceGroupSegment {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [array]) {
        foreach ($v in $Value) {
            if ($v -is [string] -and $v.ToLowerInvariant().Contains('/resourcegroups/')) { return $true }
        }
        return $false
    }
    if ($Value -is [string]) { return $Value.ToLowerInvariant().Contains('/resourcegroups/') }
    return $false
}

function Get-PolicyRuleFieldBucket {
    param([string] $Field, $Value)
    $fl = if ($Field) { $Field.ToLowerInvariant() } else { '' }
    if ($fl -eq 'type') { return 'resourceTypesAffected' }
    if ($fl -eq 'name') { return 'namingRules' }
    if ($fl -eq 'resourcegroup' -or $fl -eq 'resourcegroup.name' -or $fl -eq 'resourcegroupname') { return 'resourceGroupRules' }
    if (($fl -eq 'id' -or $fl -eq 'fullname') -and (Test-ContainsResourceGroupSegment -Value $Value)) { return 'resourceGroupRules' }
    if ($fl -eq 'location') { return 'locationRules' }
    if ($fl.StartsWith('tags')) { return 'tagRules' }
    if ($fl.StartsWith('microsoft.network/') -or ($fl -match 'subnet|vnet|virtualnetwork|networksecuritygroup|publicip')) { return 'networkRules' }
    return $null
}

function ConvertTo-PolicyDefinitionDetail {
    param($RawDefinition, [string] $FallbackName)
    $roleDefinitionIds = [string[]]@()
    if ($RawDefinition.policyRule -and $RawDefinition.policyRule.then -and $RawDefinition.policyRule.then.details -and $RawDefinition.policyRule.then.details.roleDefinitionIds) {
        $roleDefinitionIds = [string[]]@($RawDefinition.policyRule.then.details.roleDefinitionIds)
    }
    $version = $null
    if ($RawDefinition.version) { $version = $RawDefinition.version }
    elseif ($RawDefinition.metadata -and $RawDefinition.metadata.version) { $version = $RawDefinition.metadata.version }
    return [ordered]@{
        name              = if ($RawDefinition.name) { $RawDefinition.name } else { $FallbackName }
        id                = $RawDefinition.id
        displayName       = $RawDefinition.displayName
        description       = $RawDefinition.description
        policyType        = $RawDefinition.policyType
        mode              = $RawDefinition.mode
        version           = $version
        metadata          = if ($RawDefinition.metadata) { $RawDefinition.metadata } else { [ordered]@{} }
        parameters        = if ($RawDefinition.parameters) { $RawDefinition.parameters } else { [ordered]@{} }
        policyRule        = if ($RawDefinition.policyRule) { $RawDefinition.policyRule } else { [ordered]@{} }
        roleDefinitionIds = $roleDefinitionIds
    }
}

function ConvertTo-PolicyDefinitionSummary {
    param($RawDefinition, [string] $FallbackName, [string] $Effect)
    $conditions = @()
    if ($RawDefinition.policyRule -and $RawDefinition.policyRule.if) {
        $conditions = Get-PolicyRuleFieldConditions -Node $RawDefinition.policyRule.if
    }
    $typesSeen = [System.Collections.Generic.List[string]]::new()
    $typesSeenSet = [System.Collections.Generic.HashSet[string]]::new()
    $namingRules = [System.Collections.Generic.List[object]]::new()
    $resourceGroupRules = [System.Collections.Generic.List[object]]::new()
    $locationRules = [System.Collections.Generic.List[object]]::new()
    $networkRules = [System.Collections.Generic.List[object]]::new()
    $tagRules = [System.Collections.Generic.List[object]]::new()

    foreach ($cond in $conditions) {
        $bucket = Get-PolicyRuleFieldBucket -Field ([string]$cond.field) -Value $cond.value
        switch ($bucket) {
            'resourceTypesAffected' {
                $vals = if ($cond.value -is [array]) { @($cond.value) } elseif ($null -ne $cond.value) { , ($cond.value) } else { @() }
                foreach ($v in $vals) {
                    $vs = [string]$v
                    if ($typesSeenSet.Add($vs)) { $typesSeen.Add($vs) }
                }
            }
            'namingRules' { $namingRules.Add($cond) }
            'resourceGroupRules' { $resourceGroupRules.Add($cond) }
            'locationRules' { $locationRules.Add($cond) }
            'networkRules' { $networkRules.Add($cond) }
            'tagRules' { $tagRules.Add($cond) }
        }
    }

    return [ordered]@{
        definitionName        = if ($RawDefinition.name) { $RawDefinition.name } else { $FallbackName }
        displayName           = $RawDefinition.displayName
        effect                = if ([string]::IsNullOrEmpty($Effect)) { $null } else { $Effect }
        resourceTypesAffected = [string[]]@($typesSeen)
        namingRules           = @($namingRules)
        resourceGroupRules    = @($resourceGroupRules)
        locationRules         = @($locationRules)
        networkRules          = @($networkRules)
        tagRules              = @($tagRules)
    }
}

# Distinct policy definition names referenced by the shortlist, each resolved once via
# 'az policy definition show': scope derived from the compliance record's definitionId first,
# then bare name, then subscription, then a user-supplied --management-group as fallbacks.
$DefinitionsToResolve = [System.Collections.Generic.List[object]]::new()
$seenDefNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($entry in $RelevantDenyOrModifyWithDetail) {
    $dn = [string]$entry.definitionName
    if ($dn -and $seenDefNames.Add($dn)) {
        $DefinitionsToResolve.Add([ordered]@{
            definitionName = $dn
            definitionId   = $entry.definitionId
            subscriptionId = $entry.subscriptionId
            effect         = $entry.effect
        })
    }
}

$PolicyDefinitionsDetail = [System.Collections.Generic.List[object]]::new()
$PolicyDefinitionsSimplified = [System.Collections.Generic.List[object]]::new()
foreach ($def in $DefinitionsToResolve) {
    $name = [string]$def.definitionName
    $scopeArgs = Get-PolicyDefinitionScopeArgs -DefinitionId ([string]$def.definitionId)

    $definitionRaw = $null
    if ($scopeArgs.Count -gt 0) {
        $definitionRaw = Invoke-AzJson -Description "policy definition show for '$name' (derived scope)" `
            -Arguments (@('policy', 'definition', 'show', '--name', $name) + $scopeArgs + @('-o', 'json'))
    }
    if (-not $definitionRaw) {
        $definitionRaw = Invoke-AzJson -Description "policy definition show for '$name' (bare name)" `
            -Arguments @('policy', 'definition', 'show', '--name', $name, '-o', 'json')
    }
    if (-not $definitionRaw -and $def.subscriptionId) {
        $definitionRaw = Invoke-AzJson -Description "policy definition show for '$name' (subscription fallback)" `
            -Arguments @('policy', 'definition', 'show', '--name', $name, '--subscription', [string]$def.subscriptionId, '-o', 'json')
    }
    if (-not $definitionRaw -and $ManagementGroup) {
        $definitionRaw = Invoke-AzJson -Description "policy definition show for '$name' (management-group fallback)" `
            -Arguments @('policy', 'definition', 'show', '--name', $name, '--management-group', $ManagementGroup, '-o', 'json')
    }

    if ($definitionRaw) {
        $PolicyDefinitionsDetail.Add((ConvertTo-PolicyDefinitionDetail -RawDefinition $definitionRaw -FallbackName $name))
        $PolicyDefinitionsSimplified.Add((ConvertTo-PolicyDefinitionSummary -RawDefinition $definitionRaw -FallbackName $name -Effect ([string]$def.effect)))
    }
    else {
        Write-Warn "Unable to resolve policy definition '$name'; reporting as unresolved."
        $PolicyDefinitionsDetail.Add([ordered]@{ name = $name; error = 'unresolved' })
    }
}

$Policy = [ordered]@{
    assignmentsVisible            = @($AssignmentsVisible)
    effectiveFromComplianceState  = @($EffectiveCompliance)
    relevantDenyOrModify          = $RelevantDenyOrModify
    managementGroupAssignments    = @($ManagementGroupAssignments)
    definitionsDetail             = @($PolicyDefinitionsDetail)
    definitionsSimplified         = @($PolicyDefinitionsSimplified)
}

# ---------------------------------------------------------------------------
# 4. Platform readiness discovery (RBAC, providers, private endpoints, private DNS, quotas)
# ---------------------------------------------------------------------------
# Each of these is independent and best-effort: a failure or access denial in one SHALL NOT
# prevent any other section (new or pre-existing) from being gathered and reported.

# --- 4a. RBAC: role assignments + custom role definitions ---

$RbacAssignments = [System.Collections.Generic.List[object]]::new()
$RbacCustomRoles = [System.Collections.Generic.List[object]]::new()
$seenCustomRoleIds = [System.Collections.Generic.HashSet[string]]::new()

foreach ($sub in $Subscription) {
    $assignRaw = Invoke-AzJson -Description "role assignment listing for subscription $sub" `
        -Arguments @('role', 'assignment', 'list', '--all', '--subscription', $sub, '-o', 'json')
    foreach ($a in (ConvertTo-ArrayOrEmpty $assignRaw)) {
        $RbacAssignments.Add([ordered]@{
            principalId         = $a.principalId
            principalType       = $a.principalType
            roleDefinitionName  = $a.roleDefinitionName
            scope               = $a.scope
            subscriptionId      = $sub
        })
    }

    $customRaw = Invoke-AzJson -Description "custom role definition listing for subscription $sub" `
        -Arguments @('role', 'definition', 'list', '--custom-role-only', 'true', '--subscription', $sub, '-o', 'json')
    foreach ($r in (ConvertTo-ArrayOrEmpty $customRaw)) {
        $roleId = if ($r.id) { [string]$r.id } else { $null }
        if ($roleId -and $seenCustomRoleIds.Add($roleId)) {
            $roleName = if ($r.roleName) { $r.roleName } else { $r.name }
            $RbacCustomRoles.Add([ordered]@{
                name             = $roleName
                id               = $r.id
                assignableScopes = if ($r.assignableScopes) { @($r.assignableScopes) } else { @() }
                subscriptionId   = $sub
            })
        }
    }
}

# NOTE: Group-Object -Property, like Measure-Object -Property, silently fails to group by an
# ordered-Hashtable property (it treats the whole pipeline as one group with a blank key).
# Extract the property values first, then group the resulting scalar strings instead.
$RbacOwnershipSummary = [ordered]@{}
foreach ($grp in ($RbacAssignments | ForEach-Object { [string]$_.roleDefinitionName } | Group-Object)) {
    $key = if ($grp.Name) { $grp.Name } else { 'unknown' }
    $RbacOwnershipSummary[$key] = $grp.Count
}

$Rbac = [ordered]@{
    assignments      = @($RbacAssignments)
    customRoles      = @($RbacCustomRoles)
    ownershipSummary = $RbacOwnershipSummary
}

# --- 4b. Resource provider registration (fixed priority list) ---

$PriorityProviders = @(
    'Microsoft.CognitiveServices', 'Microsoft.ApiManagement', 'Microsoft.Search',
    'Microsoft.ContainerService', 'Microsoft.KeyVault', 'Microsoft.Web',
    'Microsoft.Network', 'Microsoft.OperationalInsights'
)

$Providers = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $Subscription) {
    $providersRaw = Invoke-AzJson -Description "provider listing for subscription $sub" `
        -Arguments @('provider', 'list', '--subscription', $sub, '-o', 'json')
    $providersByNamespace = @{}
    foreach ($p in (ConvertTo-ArrayOrEmpty $providersRaw)) {
        if ($p.namespace) {
            $providersByNamespace[[string]$p.namespace] = if ($p.registrationState) { $p.registrationState } else { 'Unknown' }
        }
    }
    foreach ($ns in $PriorityProviders) {
        $state = if ($providersByNamespace.ContainsKey($ns)) { $providersByNamespace[$ns] } else { 'NotFound' }
        $Providers.Add([ordered]@{
            namespace          = $ns
            registrationState  = $state
            subscriptionId     = $sub
        })
    }
}

# --- 4c. Private Endpoint discovery ---

$PrivateEndpoints = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $Subscription) {
    $peRaw = Invoke-AzJson -Description "private endpoint listing for subscription $sub" `
        -Arguments @('network', 'private-endpoint', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($pe in (ConvertTo-ArrayOrEmpty $peRaw)) {
        $connections = [System.Collections.Generic.List[object]]::new()
        $allConnections = @() + @($pe.privateLinkServiceConnections) + @($pe.manualPrivateLinkServiceConnections)
        foreach ($conn in $allConnections) {
            if ($null -eq $conn) { continue }
            $connections.Add([ordered]@{
                targetResourceId = $conn.privateLinkServiceId
                status           = $conn.privateLinkServiceConnectionState.status
            })
        }
        $PrivateEndpoints.Add([ordered]@{
            name           = $pe.name
            resourceGroup  = $pe.resourceGroup
            subnet         = $pe.subnet.id
            subscriptionId = $sub
            connections    = @($connections)
        })
    }
}

# --- 4d. Private DNS discovery (zones + VNet links) ---

$PrivateDns = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $Subscription) {
    $zonesRaw = Invoke-AzJson -Description "private DNS zone listing for subscription $sub" `
        -Arguments @('network', 'private-dns', 'zone', 'list', '--subscription', $sub, '-o', 'json')
    foreach ($zone in (ConvertTo-ArrayOrEmpty $zonesRaw)) {
        $zName = $zone.name
        $zRg = $zone.resourceGroup
        $linksRaw = Invoke-AzJson -Description "private DNS VNet link listing for zone $zName (subscription $sub)" `
            -Arguments @('network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', $zRg, '--zone-name', $zName, '--subscription', $sub, '-o', 'json')
        $linkedVnets = [System.Collections.Generic.List[string]]::new()
        foreach ($link in (ConvertTo-ArrayOrEmpty $linksRaw)) {
            $vnetId = [string]$link.virtualNetwork.id
            if ($vnetId -and ($vnetId -match '/virtualNetworks/(?<n>[^/]+)$')) {
                $linkedVnets.Add($Matches['n'])
            }
        }
        $PrivateDns.Add([ordered]@{
            name           = $zName
            resourceGroup  = $zRg
            subscriptionId = $sub
            linkedVnets    = @($linkedVnets)
        })
    }
}

# --- 4e. Quota/usage discovery ---
# Regions are derived from already-discovered resource group locations (deduplicated), avoiding
# any new region-discovery API call. Falls back to a fixed default region when the subscription
# has no discovered resource groups (e.g. a brand-new, empty subscription).

$QuotaRegions = @($ResourceGroups | ForEach-Object { $_.location } | Where-Object { $_ } | Sort-Object -Unique)
if ($QuotaRegions.Count -eq 0) {
    $QuotaRegions = @('eastus')
    Write-Info "No resource group locations discovered; defaulting quota region to eastus."
}

$Quotas = [System.Collections.Generic.List[object]]::new()
foreach ($sub in $Subscription) {
    foreach ($region in $QuotaRegions) {
        $vmUsageRaw = Invoke-AzJson -Description "VM usage listing for region $region (subscription $sub)" `
            -Arguments @('vm', 'list-usage', '--location', $region, '--subscription', $sub, '-o', 'json')
        foreach ($u in (ConvertTo-ArrayOrEmpty $vmUsageRaw)) {
            $name = if ($u.localName) { $u.localName } elseif ($u.name.value) { $u.name.value } elseif ($u.name) { $u.name } else { $null }
            $Quotas.Add([ordered]@{
                region         = $region
                category       = 'compute'
                name           = $name
                currentValue   = $u.currentValue
                limit          = $u.limit
                subscriptionId = $sub
            })
        }

        $netUsageRaw = Invoke-AzJson -Description "network usage listing for region $region (subscription $sub)" `
            -Arguments @('network', 'list-usages', '--location', $region, '--subscription', $sub, '-o', 'json')
        foreach ($u in (ConvertTo-ArrayOrEmpty $netUsageRaw)) {
            $name = if ($u.localName) { $u.localName } elseif ($u.name.value) { $u.name.value } elseif ($u.name) { $u.name } else { $null }
            $Quotas.Add([ordered]@{
                region         = $region
                category       = 'network'
                name           = $name
                currentValue   = $u.currentValue
                limit          = $u.limit
                subscriptionId = $sub
            })
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Observed naming conventions (best-effort, not authoritative)
# ---------------------------------------------------------------------------

function Get-NamingSummary {
    param([string[]] $Names)
    $prefixes = $Names | ForEach-Object { ($_ -split '-')[0] }
    $counts = $prefixes | Group-Object | Sort-Object -Property Count -Descending
    $commonPrefixes = @($counts | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    return [ordered]@{
        commonPrefixes = $commonPrefixes
        sampleSize     = $Names.Count
    }
}

$RgNames = @($ResourceGroups | ForEach-Object { $_.name })
$VnetNames = @($Vnets | ForEach-Object { $_.name })
$SubnetNames = @($Vnets | ForEach-Object { $_.subnets } | ForEach-Object { $_.name })

$NamingObserved = [ordered]@{
    resourceGroups = (Get-NamingSummary -Names $RgNames)
    byResourceType = [ordered]@{
        'Microsoft.Network/virtualNetworks'         = @($VnetNames | Sort-Object -Unique)
        'Microsoft.Network/virtualNetworks/subnets' = @($SubnetNames | Sort-Object -Unique)
    }
}

# ---------------------------------------------------------------------------
# 6. Architecture constraint synthesis (best-effort, cross-section)
# ---------------------------------------------------------------------------
# Runs last: reads from networking, policy, and naming sections already assembled above rather
# than issuing any new az calls itself.

# Hub VNet identification: the VNet with the strictly highest number of peerings. On a tie
# (including zero peerings for every VNet) the hub is left unidentified (null), per design.md.
$VnetPeeringCounts = @($Vnets | ForEach-Object {
    [ordered]@{
        name          = $_.name
        resourceGroup = $_.resourceGroup
        addressSpace  = $_.addressSpace
        peeringCount  = @($_.peerings).Count
    }
})

$HubVnet = $null
if ($VnetPeeringCounts.Count -gt 0) {
    $maxPeeringCount = ($VnetPeeringCounts | ForEach-Object { $_.peeringCount } | Measure-Object -Maximum).Maximum
    if ($maxPeeringCount -gt 0) {
        $topVnets = @($VnetPeeringCounts | Where-Object { $_.peeringCount -eq $maxPeeringCount })
        if ($topVnets.Count -eq 1) {
            $HubVnet = $topVnets[0]
        }
    }
}

$HubPeering = if ($HubVnet) { $HubVnet.name } else { $null }
$NetworkResourceGroup = if ($HubVnet) { $HubVnet.resourceGroup } else { $null }
$VnetAddressSpace = if ($HubVnet) { $HubVnet.addressSpace } else { $null }

# resourceGroupNaming: direct pass-through of namingObserved.resourceGroups (no re-derivation).
$ResourceGroupNaming = $NamingObserved.resourceGroups

# requiredTags: distinct tag keys referenced by any resolved definition's tagRules bucket
# (produced by expand-policy-definitions), extracted from field values like tags['Environment']
# or tags["Environment"] (bracket notation) or tags.Environment (dot notation).
function Get-TagKeyFromField {
    param([string] $Field)
    if (-not $Field) { return $null }
    if ($Field -match 'tags\[[''"](?<k>[^''"]+)[''"]\]') {
        return $Matches['k']
    }
    if ($Field -match '^tags\.(?<k>.+)$') {
        return $Matches['k']
    }
    return $null
}

$RequiredTagsSeen = [System.Collections.Generic.HashSet[string]]::new()
$RequiredTagsList = [System.Collections.Generic.List[string]]::new()
foreach ($def in $PolicyDefinitionsSimplified) {
    foreach ($rule in @($def.tagRules)) {
        $tagKey = Get-TagKeyFromField -Field ([string]$rule.field)
        if ($tagKey -and $RequiredTagsSeen.Add($tagKey)) {
            $RequiredTagsList.Add($tagKey)
        }
    }
}
$RequiredTags = [string[]]@($RequiredTagsList)

$ArchitectureConstraints = [ordered]@{
    networkResourceGroup = $NetworkResourceGroup
    resourceGroupNaming  = $ResourceGroupNaming
    requiredTags         = $RequiredTags
    vnetAddressSpace     = $VnetAddressSpace
    hubPeering           = $HubPeering
}

# ---------------------------------------------------------------------------
# 7. Assemble output
# ---------------------------------------------------------------------------

$FinalObject = [ordered]@{
    meta = [ordered]@{
        generatedAt   = $GeneratedAt
        tenantId      = $TenantId
        subscriptions = @($Subscription)
        runAs         = $RunAs
    }
    resourceGroups = @($ResourceGroups)
    networking     = [ordered]@{
        vnets = @($Vnets)
    }
    policy            = $Policy
    rbac              = $Rbac
    providers         = @($Providers)
    privateEndpoints  = @($PrivateEndpoints)
    privateDns        = @($PrivateDns)
    namingObserved    = $NamingObserved
    quotas            = @($Quotas)
    architectureConstraints = $ArchitectureConstraints
}

try {
    $FinalJson = $FinalObject | ConvertTo-Json -Depth 100
}
catch {
    Write-ErrorAndExit "Assembled output failed JSON serialization; aborting before write: $($_.Exception.Message)"
}

# Round-trip validation before writing/printing, mirroring the bash script's `jq empty` check.
try {
    $null = $FinalJson | ConvertFrom-Json -Depth 100
}
catch {
    Write-ErrorAndExit "Assembled output failed JSON validation; aborting before write: $($_.Exception.Message)"
}

if ($Output) {
    $outputDir = Split-Path -Path $Output -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir -PathType Container)) {
        try {
            $null = New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop
        }
        catch {
            Write-ErrorAndExit "Failed to create output directory '$outputDir': $($_.Exception.Message)"
        }
    }
    try {
        Set-Content -Path $Output -Value $FinalJson -NoNewline -ErrorAction Stop
        Write-Info "Discovery output written to $Output"
    }
    catch {
        Write-ErrorAndExit "Failed to write output to '$Output': $($_.Exception.Message)"
    }
}
else {
    Write-Output $FinalJson
}
