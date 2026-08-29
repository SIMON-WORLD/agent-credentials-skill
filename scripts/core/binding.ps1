<#
.SYNOPSIS
  Optional project/repository -> credential-profile binding (Agent Credential Layer v0.3).
.DESCRIPTION
  Small logical configuration layer: a project/repository may be bound to a provider
  profile with an optional host. Bindings store only logical metadata (project,
  provider, profile, host) and never tokens, passwords, secrets, API keys, credential
  values, authorization headers, or raw credential references beyond the accepted
  logical identifiers. Selection is exact normalized matching, deterministic, and
  fails closed on conflicting matches; it never selects a CredentialReference.
  Import-safe: dot-sourcing only defines functions and performs no filesystem access.
#>

function ConvertTo-AgentCredentialNormalizedProjectId {
    <#
    .SYNOPSIS
      Deterministic normalization of a project/repository identifier.
    .DESCRIPTION
      Trims whitespace and converts backslashes to forward slashes so path-like and
      repository-style identifiers compare deterministically. No fuzzy matching is
      introduced; this is exact normalization only.
    #>
    param([AllowNull()][string]$Project)
    if ([string]::IsNullOrEmpty($Project)) { return '' }
    return (($Project.Trim()) -replace '\\', '/')
}

function Get-AgentCredentialProjectBinding {
    <#
    .SYNOPSIS
      Constructs a logical project binding from explicit caller-supplied fields.
    .DESCRIPTION
      Whitelist construction only: project, provider, profile, optional host.
      No secret-bearing field is ever accepted or stored.
    .PARAMETER Project
      Safe project/repository identifier.
    .PARAMETER Provider
      Provider namespace (for example github, example-provider).
    .PARAMETER Profile
      Logical profile name (for example personal, work). Explicit only; never inferred.
    .PARAMETER HostName
      Optional host that narrows this binding's applicability.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$Provider,
        [Parameter(Mandatory = $true)]
        [string]$Profile,
        [string]$HostName = $null
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Provider) -or [string]::IsNullOrEmpty($Profile)) {
        throw 'binding requires project, provider, and profile'
    }
    return [PSCustomObject]@{
        project  = ConvertTo-AgentCredentialNormalizedProjectId $Project
        provider = $Provider
        profile  = $Profile
        host     = $HostName
    }
}

function Resolve-AgentCredentialProjectProfile {
    <#
    .SYNOPSIS
      Resolves a project/repository to a bound profile (internal sanitized result).
    .DESCRIPTION
      Given a normalized project identifier, a provider, and caller-supplied bindings,
      returns bound (exactly one matching profile), unbound (zero matches), or
      ambiguous (conflicting profiles). A binding with an explicit host matches only
      when the expected host is supplied and equal; a host-less binding matches
      regardless of expected host. Selection never depends on array order and never
      selects a CredentialReference; that is the resolver's responsibility.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$Provider,
        [object[]]$Bindings = @(),
        [string]$ExpectedHost = $null
    )

    $norm = ConvertTo-AgentCredentialNormalizedProjectId $Project
    if ([string]::IsNullOrEmpty($norm) -or [string]::IsNullOrEmpty($Provider)) {
        return [PSCustomObject]@{
            provider = $Provider
            project  = $norm
            outcome  = 'conflict'
            profile  = $null
            host     = $null
            summary  = 'invalid project/provider'
        }
    }

    $matches = @()
    foreach ($b in @($Bindings)) {
        if ($null -eq $b) { continue }
        $bProject = ConvertTo-AgentCredentialNormalizedProjectId $b.project
        $bProvider = [string]$b.provider
        $bProfile = [string]$b.profile
        $bHost = [string]$b.host
        if ($bProject -ne $norm -or $bProvider -ne $Provider) { continue }
        if (-not [string]::IsNullOrEmpty($bHost)) {
            if ([string]::IsNullOrEmpty($ExpectedHost) -or $bHost -ne $ExpectedHost) { continue }
        }
        $matches += [PSCustomObject]@{ profile = $bProfile; host = $bHost }
    }

    if ($matches.Count -eq 0) {
        return [PSCustomObject]@{
            provider = $Provider
            project  = $norm
            outcome  = 'unbound'
            profile  = $null
            host     = $null
            summary  = 'no matching binding'
        }
    }

    $distinctProfiles = @($matches | ForEach-Object { $_.profile } | Select-Object -Unique)
    if ($distinctProfiles.Count -eq 1) {
        # Duplicate identical bindings collapse deterministically; selection never uses order.
        $winner = $matches[0]
        return [PSCustomObject]@{
            provider = $Provider
            project  = $norm
            outcome  = 'bound'
            profile  = $winner.profile
            host     = $(if ([string]::IsNullOrEmpty($winner.host)) { $null } else { $winner.host })
            summary  = 'bound to profile'
        }
    }

    return [PSCustomObject]@{
        provider = $Provider
        project  = $norm
        outcome  = 'ambiguous'
        profile  = $null
        host     = $null
        summary  = 'conflicting bindings for project'
    }
}
