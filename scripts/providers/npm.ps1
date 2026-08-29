<#
.SYNOPSIS
  npm provider reference adapter — DISCOVERY ONLY (Agent Credential Layer v0.2).
.DESCRIPTION
  Reference/experimental adapter. Import-safe: dot-sourcing only defines functions.
  Discovery is read-only and presence-only: npm CLI availability and NPM_TOKEN
  environment reference presence. No credential value is ever read or returned.
#>
function Get-AgentCredentialNpmDiscovery {
    [CmdletBinding()]
    param(
        [ValidateSet('host', 'sandbox', 'container', 'remote', 'ci', 'unknown')]
        [string]$Runtime = 'unknown',
        [string]$RuntimeIdentifier = $null,
        [string]$Platform = $null,
        [string]$Isolation = $null
    )

    $observations = New-Object System.Collections.Generic.List[object]

    if (Get-Command npm -CommandType Application -ErrorAction SilentlyContinue) {
        $observations.Add([pscustomobject]@{
            probeType = 'command'; check = 'npm-cli-availability'; outcome = 'success'; code = $null; reference = 'tool/npm'; source = $null; metadata = $null
        })
    } else {
        $observations.Add([pscustomobject]@{
            probeType = 'command'; check = 'npm-cli-availability'; outcome = 'unavailable'; code = 'TOOL_NOT_INSTALLED'; reference = 'tool/npm'; source = $null; metadata = $null
        })
    }

    $present = Test-Path 'Env:NPM_TOKEN'
    $observations.Add([pscustomobject]@{
        probeType = 'source'; check = 'env-credential-reference'; outcome = $(if ($present) { 'success' } else { 'unavailable' }); code = $null; reference = 'env/NPM_TOKEN'
        source = [pscustomobject]@{ type = 'environment'; reference = 'env/NPM_TOKEN'; available = $present }
        metadata = [pscustomobject]@{ precedence = 1; target = 'npm-registry' }
    })

    [pscustomobject]@{
        provider = 'npm'
        operation = 'discover'
        executionContext = [pscustomobject]@{ runtime = $Runtime; runtimeIdentifier = $RuntimeIdentifier; platform = $Platform; isolation = $Isolation }
        observations = $observations
    }
}