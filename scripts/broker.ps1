<#
.SYNOPSIS
  v0.4 Broker orchestration CLI - compose v0.2 diagnosis + v0.3 context into an ExecutionPlan.
.DESCRIPTION
  Orchestrates existing real layers only (it does not reimplement them): safe diagnosis
  input, optional project binding, provider adapter/reference input, Resolve-AgentCredentialContext,
  New-AgentCredentialExecutionPlan, then sanitized human/JSON output. Plan-only: it never
  executes scoped commands, never resolves raw credential values, never reads credential
  values from env/keyring/files, never mutates parent/global auth state, and never caches
  secrets. The Core gate is never bypassed. Provider-specific branching is limited to choosing
  the GitHub vs npm adapter; scripts/core/plan.ps1 and generic Core stay provider-neutral.
.EXAMPLE
  .\scripts\broker.ps1 -Provider github -Operation push -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[...]'
  .\scripts\broker.ps1 -Provider npm -Operation publish -DiagnosisJson '{"status":"healthy"}' -ReferencesJson '[...]' -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Provider,
    [Parameter(Mandatory = $true)] [string]$Operation,
    [object]$Diagnosis = $null,
    [string]$DiagnosisJson = $null,
    [object]$Resolution = $null,
    [string]$ResolutionJson = $null,
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
    [object[]]$ResolverDescriptors = @(),
    [string]$ResolverDescriptorsJson = $null,
    [string]$ResolverRequestedId = $null,
    [switch]$Execute,
    [string]$Executable = $null,
    [string[]]$ArgumentList = @(),
    [scriptblock]$CredentialResolver = $null,
    [string]$EnvironmentVariable = $null,
    [int]$TimeoutSeconds = 0,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Path $scriptRoot -Parent

. (Join-Path $repoRoot 'scripts\core\context.ps1')
. (Join-Path $repoRoot 'scripts\core\binding.ps1')
. (Join-Path $repoRoot 'scripts\core\plan.ps1')
. (Join-Path $repoRoot 'scripts\core\execution.ps1')
. (Join-Path $repoRoot 'scripts\core\broker-execution.ps1')
. (Join-Path $repoRoot 'scripts\core\resolver.ps1')
. (Join-Path $repoRoot 'scripts\providers\github-context.ps1')
. (Join-Path $repoRoot 'scripts\providers\npm-context.ps1')

function Write-BrokerError([string]$message) { Write-Output ('ERROR: ' + $message); exit 2 }

if ($Provider -notin @('github', 'npm')) { Write-BrokerError ('unsupported provider: ' + $Provider) }
if ([string]::IsNullOrEmpty($Operation)) { Write-BrokerError 'operation is required' }

if ($DiagnosisJson) { $Diagnosis = $DiagnosisJson | ConvertFrom-Json }
if ($ResolutionJson) { $Resolution = $ResolutionJson | ConvertFrom-Json }
$diagnosisStatus = [string]$Diagnosis.status
if ([string]::IsNullOrEmpty($diagnosisStatus)) { Write-BrokerError 'safe diagnosis status is required' }
$diagnosisCode = $null
if ($null -ne $Diagnosis) { $diagCode = $Diagnosis.PSObject.Properties['code']; if ($null -ne $diagCode) { $diagnosisCode = $diagCode.Value } }

if ($ReferencesJson) { $References = @($ReferencesJson | ConvertFrom-Json) }
if ($ObservationsJson) { $Observations = @($ObservationsJson | ConvertFrom-Json) }
if ($ResolverDescriptorsJson) { $ResolverDescriptors = @($ResolverDescriptorsJson | ConvertFrom-Json) }

# --- provider adapter / reference input (observations -> references; never resolves raw) ---
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

$diagnosisSummary = [pscustomobject]@{ status = $diagnosisStatus; code = $diagnosisCode; summary = $null }

# --- optional project binding -> requestedProfile / expectedHost; fail closed on conflict ---
$reqProfile = $Profile
$reqHost = $HostName
$contextOverride = $null
if ($BindingsJson) { $Bindings = @($BindingsJson | ConvertFrom-Json) }
if ($Project -and $Bindings.Count -gt 0) {
    $bound = Resolve-AgentCredentialProjectProfile -Project $Project -Provider $Provider -Bindings $Bindings -ExpectedHost $HostName
    if ($bound.outcome -eq 'bound') {
        if ($Profile -and $bound.profile -and ($Profile -ne $bound.profile)) { $contextOverride = 'conflict' }
        elseif ($HostName -and $bound.host -and ($HostName -ne $bound.host)) { $contextOverride = 'conflict' }
        else {
            if ($bound.profile) { $reqProfile = $bound.profile }
            if ($bound.host) { $reqHost = $bound.host }
        }
    }
    elseif ($bound.outcome -eq 'ambiguous') { $contextOverride = 'ambiguous' }
}

if ($adapterConflict) { $contextOverride = 'conflict' }

$contextObj = $null
if ($contextOverride -eq 'conflict') {
    $contextObj = [pscustomobject]@{ outcome = 'conflict'; selectedReference = $null }
}
elseif ($contextOverride -eq 'ambiguous') {
    $contextObj = [pscustomobject]@{ outcome = 'ambiguous'; selectedReference = $null }
}
else {
    $ctxCandidate = [pscustomobject]@{
        contractVersion     = '0.3.0'
        provider            = $Provider
        operation           = $Operation
        requestedProfile    = $reqProfile
        expectedAccount     = $Account
        expectedHost        = $reqHost
        availableReferences = $available
        selectedReference   = $null
    }
    $resolved = Resolve-AgentCredentialContext -InputObject $ctxCandidate
    $contextObj = [pscustomobject]@{ outcome = [string]$resolved.outcome; selectedReference = $resolved.selectedReference }
}

$plan = New-AgentCredentialExecutionPlan -Provider $Provider -Operation $Operation -Diagnosis $diagnosisSummary -Context $contextObj -Resolution $Resolution -ExecutionMetadata ([pscustomobject]@{ runtime = 'host'; host = $reqHost; note = $null })

if ($Execute) {
    if ([string]::IsNullOrEmpty($Executable)) { Write-BrokerError 'executable is required for -Execute' }
    if ($null -eq $CredentialResolver) { Write-BrokerError 'a credential resolver is required for -Execute' }
    if ($EnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Write-BrokerError 'invalid credential environment-variable name for -Execute' }
    # v0.5 resolver-capability gate: when resolver descriptors are supplied, fail closed before any
    # raw credential resolution if the matcher cannot select exactly one compatible resolver.
    if ($plan.gate -eq 'ready' -and $null -ne $plan.selectedCredentialReference -and $ResolverDescriptors.Count -gt 0) {
        $verdict = Select-AgentCredentialResolver -Reference $plan.selectedCredentialReference -Descriptors $ResolverDescriptors -RequestedId $ResolverRequestedId
        if ($verdict.status -ne 'matched') {
            $failOutcome = ConvertTo-AgentCredentialResolverFailClosedOutcome -Verdict $verdict -ResolverId $ResolverRequestedId -Provider $Provider
            Write-BrokerError ('resolver selection failed closed: ' + $failOutcome.reasonCode + ' :: ' + $failOutcome.summary)
        }
    }
    $execResult = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable $Executable -ArgumentList $ArgumentList -EnvironmentVariable $EnvironmentVariable -Resolver $CredentialResolver -TimeoutSeconds $TimeoutSeconds
    if ($Json) {
        $execResult | ConvertTo-Json -Depth 8
        exit 0
    }
    Write-Output ('provider: ' + $execResult.provider)
    Write-Output ('operation: ' + $execResult.operation)
    Write-Output ('outcome: ' + $execResult.outcome)
    Write-Output ('executed: ' + $(if ($execResult.executed) { 'true' } else { 'false' }))
    if ($null -ne $execResult.exitCode) { Write-Output ('exitCode: ' + $execResult.exitCode) }
    Write-Output ('summary: ' + $execResult.summary)
    exit 0
}

if ($Json) {
    $plan | ConvertTo-Json -Depth 8
    exit 0
}

Write-Output ('provider: ' + $plan.provider)
Write-Output ('operation: ' + $plan.operation)
Write-Output ('diagnosis: ' + $plan.diagnosis.status)
Write-Output ('context: ' + $plan.context.outcome)
Write-Output ('gate: ' + $plan.gate)
if ($plan.decisionCode) { Write-Output ('decisionCode: ' + $plan.decisionCode) }
if ($null -ne $plan.selectedCredentialReference) { Write-Output ('selectedReference: ' + $plan.selectedCredentialReference.reference) }
Write-Output ('summary: ' + $(if ($plan.gate -eq 'ready') { 'execution plan is ready' } elseif ($plan.gate -eq 'needs_decision') { 'execution requires a decision' } else { 'execution is blocked' }))
exit 0
