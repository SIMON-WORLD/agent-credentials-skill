<#
.SYNOPSIS
  v0.3 Credential Context CLI - resolve provider/profile/account/host context.
.DESCRIPTION
  Exposes the v0.3 Credential Context stack through one small orchestration command.
  It uses the real modules (core context resolver, project binding, GitHub/npm context
  adapters) and never reimplements conversion or resolver logic. Selection only: it
  never executes child commands, never switches auth state, never reads credential
  values, and never mutates provider config. Raw credentials never appear in output.
.EXAMPLE
  .\scripts\context.ps1 -Provider github -ReferencesJson '[...]'
  .\scripts\context.ps1 -Provider github -Profile personal -ReferencesJson '[...]' -Json
  .\scripts\context.ps1 -Provider npm -Project pkg/npm-lib -BindingsJson '[...]' -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Provider,
    [string]$Profile = $null,
    [string]$Account = $null,
    [string]$HostName = $null,
    [string]$Project = $null,
    [object[]]$Bindings = @(),
    [string]$BindingsJson = $null,
    [object[]]$References = @(),
    [string]$ReferencesJson = $null,
    [object[]]$Observations = @(),
    [string]$ObservationsJson = $null,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Path $scriptRoot -Parent

. (Join-Path $repoRoot 'scripts\core\context.ps1')
. (Join-Path $repoRoot 'scripts\core\binding.ps1')
. (Join-Path $repoRoot 'scripts\providers\github-context.ps1')
. (Join-Path $repoRoot 'scripts\providers\npm-context.ps1')

if ($Provider -notin @('github', 'npm')) {
    Write-Output ('ERROR: unsupported provider: ' + $Provider)
    exit 2
}

if ($ReferencesJson) { $References = @($ReferencesJson | ConvertFrom-Json) }
if ($ObservationsJson) { $Observations = @($ObservationsJson | ConvertFrom-Json) }
if ($BindingsJson) { $Bindings = @($BindingsJson | ConvertFrom-Json) }

# --- provider adapter conversion (sanitized observations only) ---
$available = @($References | Where-Object { $null -ne $_ })
$adapterConflict = $null
if ($available.Count -eq 0 -and $Observations.Count -gt 0) {
    if ($Provider -eq 'github') {
        $conv = Get-AgentCredentialGitHubReferences -Observations $Observations
        $adapterConflict = $conv.conflict
        $available = @($conv.references)
    }
    elseif ($Provider -eq 'npm') {
        $conv = Get-AgentCredentialNpmReferences -Observations $Observations
        $adapterConflict = $conv.conflict
        $available = @($conv.references)
    }
}

function Write-ContextOutput {
    param(
        [string]$ProviderName,
        [string]$Outcome,
        [string]$SelectedProfile,
        [string]$SelectedReference,
        [int]$CandidateCount,
        [string]$Summary,
        [switch]$AsJson
    )
    if ($AsJson) {
        [pscustomobject]@{
            provider          = $ProviderName
            outcome           = $Outcome
            selectedProfile   = $SelectedProfile
            selectedReference = $SelectedReference
            candidateCount    = $CandidateCount
            summary           = $Summary
        } | ConvertTo-Json -Depth 6
        return
    }
    Write-Output ('provider: ' + $ProviderName)
    Write-Output ('outcome: ' + $Outcome)
    Write-Output ('selectedProfile: ' + $(if ($SelectedProfile) { $SelectedProfile } else { '(none)' }))
    Write-Output ('selectedReference: ' + $(if ($SelectedReference) { $SelectedReference } else { '(none)' }))
    Write-Output ('candidateCount: ' + $CandidateCount)
    Write-Output ('summary: ' + $Summary)
}

if ($adapterConflict) {
    Write-ContextOutput -ProviderName $Provider -Outcome 'conflict' -SelectedProfile $null -SelectedReference $null -CandidateCount 0 -Summary 'conflicting metadata for logical reference' -AsJson:$Json
    exit 0
}

# --- binding flow: -Project + bindings -> requestedProfile / expectedHost ---
$reqProfile = $Profile
$reqHost = $HostName
if ($Project -and $Bindings.Count -gt 0) {
    $bound = Resolve-AgentCredentialProjectProfile -Project $Project -Provider $Provider -Bindings $Bindings -ExpectedHost $HostName
    if ($bound.outcome -eq 'bound') {
        if ($Profile -and $bound.profile -and ($Profile -ne $bound.profile)) {
            Write-ContextOutput -ProviderName $Provider -Outcome 'conflict' -SelectedProfile $null -SelectedReference $null -CandidateCount 0 -Summary 'explicit profile contradicts project binding' -AsJson:$Json
            exit 0
        }
        if ($HostName -and $bound.host -and ($HostName -ne $bound.host)) {
            Write-ContextOutput -ProviderName $Provider -Outcome 'conflict' -SelectedProfile $null -SelectedReference $null -CandidateCount 0 -Summary 'explicit host contradicts project binding' -AsJson:$Json
            exit 0
        }
        if ($bound.profile) { $reqProfile = $bound.profile }
        if ($bound.host) { $reqHost = $bound.host }
    }
    elseif ($bound.outcome -eq 'ambiguous') {
        Write-ContextOutput -ProviderName $Provider -Outcome 'conflict' -SelectedProfile $null -SelectedReference $null -CandidateCount 0 -Summary 'conflicting project bindings' -AsJson:$Json
        exit 0
    }
}

# --- generic resolver (selection only; never executes anything) ---
$ctx = [pscustomobject]@{
    contractVersion     = '0.3.0'
    provider            = $Provider
    operation           = 'context'
    requestedProfile    = $reqProfile
    expectedAccount     = $Account
    expectedHost        = $reqHost
    availableReferences = $available
    selectedReference   = $null
}
$res = Resolve-AgentCredentialContext -InputObject $ctx

$selRef = $null
if ($null -ne $res.selectedReference) { $selRef = [string]$res.selectedReference.reference }

Write-ContextOutput -ProviderName $Provider -Outcome $res.outcome -SelectedProfile $res.selectedProfile -SelectedReference $selRef -CandidateCount @($res.candidateReferences).Count -Summary $res.summary -AsJson:$Json
exit 0
