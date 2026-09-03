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
    if ($null -eq $vnetsRaw) { continue }

    foreach ($vnet in (ConvertTo-ArrayOrEmpty $vnetsRaw)) {
        $vName = $vnet.name
        $vRg = $vnet.resourceGroup
        $vId = $vnet.id
        $addressSpace = if ($vnet.addressSpace.addressPrefixes) { @($vnet.addressSpace.addressPrefixes) } else { @() }

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
        $scope = if ($state.policyAssignmentScope) { $state.policyAssignmentScope } else { $state.PolicyAssignmentScope }
        $effect = if ($state.policyDefinitionAction) { $state.policyDefinitionAction } else { $state.PolicyDefinitionAction }
        $ComplianceTuplesAll.Add([ordered]@{
            assignmentName = $assignmentName
            definitionName = $definitionName
            scope          = $scope
            effect         = $effect
            subscriptionId = $sub
        })
    }
}

# Dedupe distinct (assignmentName, definitionName, scope, effect, subscriptionId) tuples.
# (Sort-Object -Unique is unreliable for ordered-hashtable equality, so dedupe explicitly via a
# composite string key instead.)
$seenTuples = [System.Collections.Generic.HashSet[string]]::new()
$EffectiveCompliance = [System.Collections.Generic.List[object]]::new()
foreach ($tuple in $ComplianceTuplesAll) {
    $key = "$($tuple.assignmentName)|$($tuple.definitionName)|$($tuple.scope)|$($tuple.effect)|$($tuple.subscriptionId)"
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

$Policy = [ordered]@{
    assignmentsVisible            = @($AssignmentsVisible)
    effectiveFromComplianceState  = @($EffectiveCompliance)
    relevantDenyOrModify          = $RelevantDenyOrModify
    managementGroupAssignments    = @($ManagementGroupAssignments)
}

# ---------------------------------------------------------------------------
# 4. Observed naming conventions (best-effort, not authoritative)
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
# 5. Assemble output
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
    policy         = $Policy
    namingObserved = $NamingObserved
    quotas         = [ordered]@{}
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
    Set-Content -Path $Output -Value $FinalJson -NoNewline
    Write-Warn "Discovery output written to $Output"
}
else {
    Write-Output $FinalJson
}
