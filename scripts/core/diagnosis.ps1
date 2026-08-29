<#
.SYNOPSIS
  Provider-neutral Diagnosis Core (Agent Credential Layer v0.2).
.DESCRIPTION
  Consumes normalized observations produced by provider adapters and classifies the
  safest supported diagnosis. It never performs provider probing, never reads
  credentials, never executes recovery, and never emits a final Diagnosis Result,
  resolution strategy, reauthentication flag, or operational status. It prefers
  DIAGNOSIS_INCONCLUSIVE over an unsupported specific diagnosis and never assigns
  causal precedence to observed failure codes.
  This file is import-safe: dot-sourcing only defines functions.
#>
function Get-AgentCredentialFailureRegistry {
    [CmdletBinding()]
    param()

    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $registryFile = Join-Path $repoRoot 'schema\diagnostic-codes.json'
    if (-not (Test-Path -LiteralPath $registryFile)) { throw "code registry not found: $registryFile" }
    $reg = Get-Content -Raw -LiteralPath $registryFile | ConvertFrom-Json
    $map = @{}
    foreach ($p in $reg.codes.failure.PSObject.Properties) {
        $map[$p.Name] = [pscustomobject]@{
            category = [string]$p.Value.category
            description = [string]$p.Value.description
        }
    }
    return $map
}

<#
.SYNOPSIS
  Provider-neutral diagnosis classification.
.DESCRIPTION
  Inputs are normalized observations only. Returns an INTERNAL classification object
  (provider, operation, code, relatedCodes, category, conclusive, summary). It does
  NOT emit confidence (the accepted contract leaves it optional with no semantic
  vocabulary), recommendedResolution, reauthRequired, interactive auth, remediation
  steps, or final public status. Classification rules are conservative: lack of
  evidence is not credential invalidity, a provider error is not its root cause, and
  ordering observed codes is not the same as knowing which is the root cause.
#>
function Get-AgentCredentialDiagnosis {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [string]$Operation,
        [object]$Context = $null,
        [object[]]$Observations = @()
    )

    $failureMap = Get-AgentCredentialFailureRegistry

    $precise = New-Object System.Collections.Generic.HashSet[string]
    $unclassified = New-Object System.Collections.Generic.List[object]
    foreach ($obs in @($Observations)) {
        $code = $obs.code
        $outcome = [string]$obs.outcome
        if ($null -ne $code -and $failureMap.ContainsKey([string]$code)) {
            # Only failure-registry codes become diagnosis candidates.
            $null = $precise.Add([string]$code)
        } elseif ($outcome -in @('failure', 'timeout')) {
            # A negative outcome without a registry code is unclassified evidence.
            $unclassified.Add($obs)
        }
        # success / unavailable with null-or-non-failure code is neutral and ignored.
    }

    $primary = $null
    $related = @()
    $conclusive = $true

    if ($precise.Count -gt 1) {
        # More than one distinct precise failure: no causal precedence is supported.
        # Primary is DIAGNOSIS_INCONCLUSIVE; related codes are sorted deterministically
        # (lexical/ordinal) purely for serialization stability, never as causal ranking.
        $primary = 'DIAGNOSIS_INCONCLUSIVE'
        $related = @($precise | Sort-Object)
        $conclusive = $false
    } elseif ($precise.Count -eq 1) {
        $primary = @($precise)[0]
        $related = @()
        if ($primary -eq 'AUTH_CHECK_TIMEOUT') { $conclusive = $false }
    } elseif ($unclassified.Count -gt 0) {
        $primary = 'DIAGNOSIS_INCONCLUSIVE'
        $related = @()
        $conclusive = $false
    } else {
        $primary = $null
        $related = @()
        $conclusive = $true
    }

    $category = $null
    $summary = ''
    if ($null -eq $primary) {
        $category = $null
        $summary = 'No negative evidence; no diagnosis is supported.'
    } elseif ($precise.Count -gt 1) {
        $category = $failureMap[$primary].category
        $summary = 'Multiple distinct failure codes observed; no causal precedence is supported.'
    } elseif ($primary -eq 'DIAGNOSIS_INCONCLUSIVE') {
        $category = $failureMap[$primary].category
        $summary = 'Evidence is insufficient to support a specific diagnosis.'
    } else {
        $category = $failureMap[$primary].category
        $summary = $failureMap[$primary].description
    }

    [pscustomobject]@{
        provider = $Provider
        operation = $Operation
        code = $primary
        relatedCodes = @($related)
        category = $category
        conclusive = $conclusive
        summary = $summary
    }
}