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
<#
.SYNOPSIS
  GitHub provider reference adapter — AUTH STATUS PROBING ONLY (Agent Credential Layer v0.2).
.DESCRIPTION
  Runs a read-only, machine-readable authentication-state probe (gh auth status --json hosts)
  and returns normalized, sanitized observations. gh auth status is evidence, not verdict:
  per-entry state is recorded as an observation, and no final Diagnosis Result, status,
  diagnosis, resolution strategy, or reauth decision is produced here.
.PARAMETER Runtime
  Execution-context kind: host, sandbox, container, remote, ci, unknown.
.PARAMETER RuntimeIdentifier
  Optional safe runtime identifier supplied by the caller.
.PARAMETER Platform
  Optional generic platform identifier supplied by the caller.
.PARAMETER Isolation
  Optional isolation information supplied by the caller.
.PARAMETER Hostname
  Optional safe target hostname. When supplied, it is passed as a normal --hostname argument.
  It is never derived from credential values and GH_HOST is never mutated. When omitted,
  all hosts known to gh auth status are probed.
.EXAMPLE
  Get-AgentCredentialGitHubAuthProbe -Runtime sandbox -Hostname example.invalid
#>
function ConvertTo-AgentCredentialTokenSource {
    [CmdletBinding()]
    param([string]$TokenSourceRaw)

    $knownEnv = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')
    foreach ($n in $knownEnv) {
        if ($TokenSourceRaw -eq $n) { return [pscustomobject]@{ category = 'environment'; reference = ('env/' + $n) } }
    }
    if ($TokenSourceRaw -match '[\\/]' -or $TokenSourceRaw -match '^[A-Za-z]:') {
        return [pscustomobject]@{ category = 'file'; reference = 'file' }
    }
    if ($TokenSourceRaw -match 'keyring|wincred|keychain|secret') {
        return [pscustomobject]@{ category = 'keyring'; reference = 'keyring' }
    }
    if ($TokenSourceRaw -match 'browser') {
        return [pscustomobject]@{ category = 'browser'; reference = 'browser' }
    }
    if ($TokenSourceRaw -eq '') {
        return [pscustomobject]@{ category = 'unknown'; reference = 'unknown' }
    }
    return [pscustomobject]@{ category = 'other'; reference = 'other' }
}

function Get-AgentCredentialGitHubAuthProbe {
    [CmdletBinding()]
    param(
        [ValidateSet('host', 'sandbox', 'container', 'remote', 'ci', 'unknown')]
        [string]$Runtime = 'unknown',
        [string]$RuntimeIdentifier = $null,
        [string]$Platform = $null,
        [string]$Isolation = $null,
        [string]$Hostname = $null
    )

    $observations = New-Object System.Collections.Generic.List[object]

    # Reuse the same read-only availability check as discovery. Never attempt
    # auth probing when the tool is missing; never install it.
    if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
        $observations.Add([pscustomobject]@{
            probeType = 'command'
            check = 'github-auth-status'
            outcome = 'unavailable'
            code = 'TOOL_NOT_INSTALLED'
            reference = 'tool/gh'
            source = $null
            metadata = $null
        })
        return [pscustomobject]@{
            provider = 'github'
            operation = 'auth-probe'
            executionContext = [pscustomobject]@{
                runtime = $Runtime
                runtimeIdentifier = $RuntimeIdentifier
                platform = $Platform
                isolation = $Isolation
            }
            observations = $observations
        }
    }

    $ghArgs = @('auth', 'status', '--json', 'hosts')
    if ($Hostname) {
        $ghArgs += '--hostname'
        $ghArgs += $Hostname
    }

    # Transport exit code is NOT a credential verdict. Machine-readable --json mode may
    # return exit 0 even when an entry reports an error; per-entry state drives observations.
    $stdout = & gh @ghArgs 2>$null
    $parsed = $null
    try { $parsed = ($stdout | Out-String | ConvertFrom-Json) } catch { $parsed = $null }

    if ($null -eq $parsed -or $null -eq $parsed.hosts) {
        $observations.Add([pscustomobject]@{
            probeType = 'command'
            check = 'github-auth-status'
            outcome = 'failure'
            code = $null
            reference = ('cli/' + $(if ($Hostname) { $Hostname } else { 'all' }))
            source = $null
            metadata = [pscustomobject]@{ note = 'auth-status probe produced no parseable result; outcome inconclusive' }
        })
        return [pscustomobject]@{
            provider = 'github'
            operation = 'auth-probe'
            executionContext = [pscustomobject]@{
                runtime = $Runtime
                runtimeIdentifier = $RuntimeIdentifier
                platform = $Platform
                isolation = $Isolation
            }
            observations = $observations
        }
    }

    $hosts = $parsed.hosts
    $props = @($hosts.PSObject.Properties)
    if ($props.Count -eq 0) {
        $observations.Add([pscustomobject]@{
            probeType = 'auth'
            check = 'github-auth-status'
            outcome = 'unavailable'
            code = $null
            reference = 'cli/all'
            source = $null
            metadata = $null
        })
        return [pscustomobject]@{
            provider = 'github'
            operation = 'auth-probe'
            executionContext = [pscustomobject]@{
                runtime = $Runtime
                runtimeIdentifier = $RuntimeIdentifier
                platform = $Platform
                isolation = $Isolation
            }
            observations = $observations
        }
    }

    foreach ($p in $props) {
        $hostName = [string]$p.Name
        $entry = $p.Value

        # Whitelist-only extraction. Unknown fields (including any token or
        # credential-bearing property) are never forwarded; error text is dropped.
        $state = [string]$entry.state
        $active = [bool]$entry.active
        $login = [string]$entry.login
        $tokenSourceRaw = [string]$entry.tokenSource
        $scopes = @()
        if ($null -ne $entry.scopes) { $scopes = @($entry.scopes) }
        $gitProtocol = [string]$entry.gitProtocol

        $outcome = 'unknown'
        $code = $null
        switch ($state) {
            'success' { $outcome = 'success' }
            'timeout' { $outcome = 'timeout'; $code = 'AUTH_CHECK_TIMEOUT' }
            'error'   { $outcome = 'failure' }
            default   { $outcome = 'unknown' }
        }

        $src = ConvertTo-AgentCredentialTokenSource -TokenSourceRaw $tokenSourceRaw
        $observations.Add([pscustomobject]@{
            probeType = 'auth'
            check = 'github-auth-status'
            outcome = $outcome
            code = $code
            reference = ('cli/' + $hostName)
            source = $null
            metadata = [pscustomobject]@{
                host = $hostName
                active = $active
                login = $login
                tokenSourceCategory = $src.category
                tokenSourceReference = $src.reference
                scopes = $scopes
                gitProtocol = $gitProtocol
            }
        })
    }

    [pscustomobject]@{
        provider = 'github'
        operation = 'auth-probe'
        executionContext = [pscustomobject]@{
            runtime = $Runtime
            runtimeIdentifier = $RuntimeIdentifier
            platform = $Platform
            isolation = $Isolation
        }
        observations = $observations
    }
}