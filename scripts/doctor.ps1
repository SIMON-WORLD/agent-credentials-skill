<#
.SYNOPSIS
  Agent Credential Layer doctor — Diagnosis Result v0.2 CLI (reference).
.DESCRIPTION
  Orchestrates provider adapters (discovery, and for GitHub auth-status and transport
  probes), the provider-neutral Diagnosis Core, Resolution Policy, and the result
  assembler into a Diagnosis Result v0.2. It never authenticates, never mutates
  credentials, and never executes recovery. Import-safe: dot-sourcing only defines
  functions; running the file directly executes the doctor for the chosen provider.
#>
[CmdletBinding()]
param(
    [ValidateSet('github', 'npm')]
    [string]$Provider = 'github',
    [string]$Operation = 'push',
    [ValidateSet('host', 'sandbox', 'container', 'remote', 'ci', 'unknown')]
    [string]$Runtime = 'host',
    [string]$RuntimeIdentifier = $null,
    [string]$Platform = $null,
    [string]$Isolation = $null,
    [string]$Hostname = '',
    [int]$TimeoutSeconds = 8,
    [switch]$ConnectorAvailable,
    [string]$ConnectorReference = 'connector/default',
    [switch]$Json
)
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'scripts\core\diagnosis.ps1')
. (Join-Path $repoRoot 'scripts\core\resolution.ps1')
. (Join-Path $repoRoot 'scripts\core\result.ps1')
. (Join-Path $repoRoot 'scripts\providers\github.ps1')
. (Join-Path $repoRoot 'scripts\providers\npm.ps1')

function Invoke-AgentCredentialDoctor {
    [CmdletBinding()]
    param(
        [ValidateSet('github', 'npm')]
        [string]$Provider = 'github',
        [string]$Operation = 'push',
        [ValidateSet('host', 'sandbox', 'container', 'remote', 'ci', 'unknown')]
        [string]$Runtime = 'host',
        [string]$RuntimeIdentifier = $null,
        [string]$Platform = $null,
        [string]$Isolation = $null,
        [string]$Hostname = '',
        [int]$TimeoutSeconds = 8,
        [switch]$ConnectorAvailable,
        [string]$ConnectorReference = 'connector/default',
        [switch]$Json
    )

    $ctx = [pscustomobject]@{
        runtime = $Runtime
        runtimeIdentifier = $RuntimeIdentifier
        platform = $Platform
        isolation = $Isolation
    }
    $observations = New-Object System.Collections.Generic.List[object]
    $sources = @()
    $caps = @()
    $network = $null
    $selected = $null

    if ($Provider -eq 'github') {
        $disc = Get-AgentCredentialGitHubDiscovery -Runtime $Runtime -RuntimeIdentifier $RuntimeIdentifier -Platform $Platform -Isolation $Isolation -ConnectorAvailable:$ConnectorAvailable -ConnectorReference $ConnectorReference
        foreach ($o in $disc.observations) { $observations.Add($o) }
        foreach ($o in $disc.observations) { if ($o.source -and $o.source.available) { $sources += $o.source } }
        if ($ConnectorAvailable) { $caps = @('CONNECTOR_AVAILABLE') }

        $authArgs = @{ Runtime = $Runtime; RuntimeIdentifier = $RuntimeIdentifier; Platform = $Platform; Isolation = $Isolation }
        if ($Hostname) { $authArgs.Hostname = $Hostname }
        $auth = Get-AgentCredentialGitHubAuthProbe @authArgs
        foreach ($o in $auth.observations) { $observations.Add($o) }

        $transportHost = $(if ($Hostname) { $Hostname } else { 'github.com' })
        $tr = Get-AgentCredentialGitHubTransportProbe -Runtime $Runtime -RuntimeIdentifier $RuntimeIdentifier -Platform $Platform -Isolation $Isolation -Hostname $transportHost -TimeoutSeconds $TimeoutSeconds
        foreach ($o in $tr.observations) { $observations.Add($o) }
        $netObs = $tr.observations | Where-Object { $_.check -eq 'github-https-transport' } | Select-Object -First 1
        if ($netObs) {
            $network = [pscustomobject]@{
                reachable = $netObs.outcome -eq 'success'
                dns = $null
                proxy = $null
                timeout = $netObs.outcome -eq 'timeout'
                tls = $null
            }
        }
    } elseif ($Provider -eq 'npm') {
        $disc = Get-AgentCredentialNpmDiscovery -Runtime $Runtime -RuntimeIdentifier $RuntimeIdentifier -Platform $Platform -Isolation $Isolation
        foreach ($o in $disc.observations) { $observations.Add($o) }
        foreach ($o in $disc.observations) { if ($o.source -and $o.source.available) { $sources += $o.source } }
    }

    if ($sources.Count -gt 0) { $selected = $sources[0] }

    $diag = Get-AgentCredentialDiagnosis -Provider $Provider -Operation $Operation -Context $ctx -Observations $observations.ToArray()
    $pol = Get-AgentCredentialResolutionPolicy -Diagnosis $diag -CredentialSources $sources -Capabilities $caps -Context $ctx
    $result = New-AgentCredentialDiagnosisResult -Provider $Provider -Operation $Operation -Context $ctx -Capabilities $caps -AvailableCredentialSources $sources -SelectedCredentialSource $selected -Identity $null -Network $network -Evidence $observations.ToArray() -Diagnosis $diag -Policy $pol

    if ($Json) { return ($result | ConvertTo-Json -Depth 12) }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $out = Invoke-AgentCredentialDoctor @PSBoundParameters
    if ($Json) {
        Write-Output $out
    } else {
        Write-Output ("provider=" + $out.provider + " status=" + $out.status + " diagnosis=" + $(if ($out.diagnosis.code) { $out.diagnosis.code } else { 'none' }) + " strategy=" + $out.recommendedResolution.strategy + " reauthRequired=" + $out.reauthRequired)
    }
}