<#
.SYNOPSIS
  GitHub provider reference adapter — DISCOVERY ONLY (Agent Credential Layer v0.2).
.DESCRIPTION
  Import-safe reference adapter. Dot-sourcing this file only defines
  Get-AgentCredentialGitHubDiscovery; nothing runs automatically, no command is
  executed, no network is used, no credential value is read, and no state is mutated.
  Discovery reports which GitHub-related tools and credential-source REFERENCES appear
  available in the current execution context. It never concludes validity, never emits
  a final Diagnosis Result, and never makes a diagnosis/policy decision.
.PARAMETER Runtime
  Execution-context kind: host, sandbox, container, remote, ci, unknown.
.PARAMETER RuntimeIdentifier
  Optional safe runtime identifier supplied by the caller.
.PARAMETER Platform
  Optional generic platform identifier supplied by the caller.
.PARAMETER Isolation
  Optional isolation information supplied by the caller.
.PARAMETER ConnectorAvailable
  Whether the hosting runtime advertises an authenticated GitHub platform connector.
  This adapter never guesses connectors; the caller supplies this capability.
.PARAMETER ConnectorReference
  Safe connector reference supplied by the caller (for example connector/default).
.EXAMPLE
  Get-AgentCredentialGitHubDiscovery -Runtime sandbox -ConnectorAvailable -ConnectorReference 'connector/default'
#>
function Get-AgentCredentialGitHubDiscovery {
    [CmdletBinding()]
    param(
        [ValidateSet('host', 'sandbox', 'container', 'remote', 'ci', 'unknown')]
        [string]$Runtime = 'unknown',
        [string]$RuntimeIdentifier = $null,
        [string]$Platform = $null,
        [string]$Isolation = $null,
        [switch]$ConnectorAvailable,
        [string]$ConnectorReference = $null
    )

    $observations = New-Object System.Collections.Generic.List[object]

    # --- Discovery 1: GitHub CLI availability (read-only command lookup) ---
    if (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue) {
        $observations.Add([pscustomobject]@{
            probeType = 'command'
            check = 'github-cli-availability'
            outcome = 'success'
            code = $null
            reference = 'tool/gh'
            source = $null
            metadata = $null
        })
    } else {
        $observations.Add([pscustomobject]@{
            probeType = 'command'
            check = 'github-cli-availability'
            outcome = 'unavailable'
            code = 'TOOL_NOT_INSTALLED'
            reference = 'tool/gh'
            source = $null
            metadata = $null
        })
    }
    # Installing gh does not imply any authentication exists.

    # --- Discovery 2: environment credential REFERENCES (presence only) ---
    # Presence is checked via the Env: provider path (Test-Path). Values are never
    # read, returned, compared, validated, trimmed, decoded, measured, or emitted.
    $envRefs = @(
        @{ Name = 'GH_TOKEN'; Precedence = 1; Target = 'github.com' },
        @{ Name = 'GITHUB_TOKEN'; Precedence = 2; Target = 'github.com' },
        @{ Name = 'GH_ENTERPRISE_TOKEN'; Precedence = 1; Target = 'github-enterprise-server' },
        @{ Name = 'GITHUB_ENTERPRISE_TOKEN'; Precedence = 2; Target = 'github-enterprise-server' }
    )
    foreach ($ref in $envRefs) {
        $present = Test-Path ('Env:' + $ref.Name)
        $observations.Add([pscustomobject]@{
            probeType = 'source'
            check = 'env-credential-reference'
            outcome = $(if ($present) { 'success' } else { 'unavailable' })
            code = $null
            reference = ('env/' + $ref.Name)
            source = [pscustomobject]@{
                type = 'environment'
                reference = ('env/' + $ref.Name)
                available = $present
            }
            metadata = [pscustomobject]@{
                precedence = $ref.Precedence
                target = $ref.Target
            }
        })
    }

    # --- Discovery 3: GH_HOST host-routing configuration reference (not a credential source) ---
    $hostPresent = Test-Path 'Env:GH_HOST'
    $observations.Add([pscustomobject]@{
        probeType = 'config'
        check = 'github-host-routing'
        outcome = $(if ($hostPresent) { 'success' } else { 'unavailable' })
        code = $null
        reference = 'env/GH_HOST'
        source = $null
        metadata = [pscustomobject]@{ kind = 'host-routing' }
    })

    # --- Discovery 4: connector hint supplied by the caller/runtime (never guessed) ---
    if ($ConnectorAvailable -and $ConnectorReference) {
        $observations.Add([pscustomobject]@{
            probeType = 'source'
            check = 'connector-hint'
            outcome = 'success'
            code = $null
            reference = $ConnectorReference
            source = [pscustomobject]@{
                type = 'platformConnector'
                reference = $ConnectorReference
                available = $true
            }
            metadata = [pscustomobject]@{ suppliedBy = 'runtime' }
        })
    }

    # Internal discovery shape only; not a final Diagnosis Result v0.2.
    [pscustomobject]@{
        provider = 'github'
        operation = 'discover'
        executionContext = [pscustomobject]@{
            runtime = $Runtime
            runtimeIdentifier = $RuntimeIdentifier
            platform = $Platform
            isolation = $Isolation
        }
        observations = $observations
    }
}