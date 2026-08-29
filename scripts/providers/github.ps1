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
<#
.SYNOPSIS
  Internal DNS resolution probe for the GitHub transport adapter.
.DESCRIPTION
  Read-only hostname resolution. Returns only a success boolean; resolved addresses
  are never returned or exposed. Tests may override this function in the harness
  scope for deterministic scenarios.
#>
function Invoke-AgentCredentialDnsProbe {
    [CmdletBinding()]
    param([string]$Hostname)

    try {
        $null = [System.Net.Dns]::GetHostAddresses($Hostname)
        return [pscustomobject]@{ succeeded = $true }
    } catch {
        return [pscustomobject]@{ succeeded = $false }
    }
}

<#
.SYNOPSIS
  Internal HTTPS transport probe for the GitHub transport adapter.
.DESCRIPTION
  Read-only, unauthenticated HTTPS GET to the provider endpoint with a short timeout.
  Returns only a normalized transport result (reachable / timeout / tls / proxy / failure)
  plus an optional HTTP status code. Response bodies, headers, exception text, and
  credentials are never returned. TLS verification is never disabled.
#>
function Invoke-AgentCredentialHttpProbe {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [int]$TimeoutSeconds = 8
    )

    $proxyEnvPresent = (Test-Path 'Env:HTTPS_PROXY') -or (Test-Path 'Env:HTTP_PROXY')
    try {
        $cmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
        $useSkipHttpError = $null -ne $cmd -and $cmd.Parameters.ContainsKey('SkipHttpErrorCheck')
        $params = @{
            Uri = $Uri
            Method = 'Get'
            TimeoutSec = $TimeoutSeconds
            UseBasicParsing = $true
        }
        if ($useSkipHttpError) { $params.SkipHttpErrorCheck = $true }
        $resp = Invoke-WebRequest @params
        return [pscustomobject]@{
            transport = 'reachable'
            statusCode = [int]$resp.StatusCode
            proxyEvidence = $proxyEnvPresent
        }
    } catch {
        $ex = $_.Exception
        # Any HTTP response, including 4xx, proves transport reachability.
        if ($ex -is [System.Net.WebException]) {
            if ($null -ne $ex.Response) {
                return [pscustomobject]@{
                    transport = 'reachable'
                    statusCode = [int]$ex.Response.StatusCode
                    proxyEvidence = $proxyEnvPresent
                }
            }
        }
        $isTimeout = $false
        $isTls = $false
        if ($ex -is [System.Net.WebException] -and $ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) { $isTimeout = $true }
        if ($null -ne $ex.InnerException -and $ex.InnerException -is [System.Security.Authentication.AuthenticationException]) { $isTls = $true }
        $msg = [string]$ex.Message
        if ($msg -match 'timed out|timeout') { $isTimeout = $true }
        if ($isTimeout) { return [pscustomobject]@{ transport = 'timeout'; statusCode = $null; proxyEvidence = $proxyEnvPresent } }
        if ($isTls) { return [pscustomobject]@{ transport = 'tls'; statusCode = $null; proxyEvidence = $proxyEnvPresent } }
        $proxyHint = $proxyEnvPresent -and ($msg -match 'proxy|407')
        if ($proxyHint) { return [pscustomobject]@{ transport = 'proxy'; statusCode = $null; proxyEvidence = $proxyEnvPresent } }
        return [pscustomobject]@{ transport = 'failure'; statusCode = $null; proxyEvidence = $proxyEnvPresent }
    }
}

<#
.SYNOPSIS
  GitHub provider reference adapter — NETWORK / TRANSPORT PROBING ONLY (v0.2).
.DESCRIPTION
  Read-only, unauthenticated transport probe: DNS resolution plus a small HTTPS request
  to the provider API endpoint. Answers whether this execution context can resolve and
  reach the endpoint over the expected transport. It never determines credential
  validity, never reads credential values, never adds credential headers, and never
  produces a final Diagnosis Result. gh auth status remains evidence, not verdict.
.PARAMETER Runtime
  Execution-context kind: host, sandbox, container, remote, ci, unknown.
.PARAMETER RuntimeIdentifier
  Optional safe runtime identifier supplied by the caller.
.PARAMETER Platform
  Optional generic platform identifier supplied by the caller.
.PARAMETER Isolation
  Optional isolation information supplied by the caller.
.PARAMETER Hostname
  Optional safe hostname. Defaults to github.com (probes https://api.github.com).
  Enterprise hostnames probe https://<hostname>/api/v3. Only safe hostnames are
  accepted; arbitrary URL schemes are rejected and never executed.
.PARAMETER TimeoutSeconds
  Short diagnostic timeout for the HTTPS probe (default 8).
.EXAMPLE
  Get-AgentCredentialGitHubTransportProbe -Runtime sandbox
#>
function Get-AgentCredentialGitHubTransportProbe {
    [CmdletBinding()]
    param(
        [ValidateSet('host', 'sandbox', 'container', 'remote', 'ci', 'unknown')]
        [string]$Runtime = 'unknown',
        [string]$RuntimeIdentifier = $null,
        [string]$Platform = $null,
        [string]$Isolation = $null,
        [string]$Hostname = 'github.com',
        [int]$TimeoutSeconds = 8
    )

    $observations = New-Object System.Collections.Generic.List[object]

    if ($Hostname -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$') {
        $observations.Add([pscustomobject]@{
            probeType = 'network'
            check = 'github-transport'
            outcome = 'failure'
            code = $null
            reference = 'host/invalid'
            source = $null
            metadata = [pscustomobject]@{ note = 'unsafe hostname rejected; no probe attempted' }
        })
        return [pscustomobject]@{
            provider = 'github'
            operation = 'transport-probe'
            executionContext = [pscustomobject]@{ runtime = $Runtime; runtimeIdentifier = $RuntimeIdentifier; platform = $Platform; isolation = $Isolation }
            observations = $observations
        }
    }

    $endpoint = if ($Hostname -ieq 'github.com') { 'https://api.github.com' } else { 'https://' + $Hostname + '/api/v3' }

    # --- DNS resolution (read-only; resolved addresses are never exposed) ---
    $dns = Invoke-AgentCredentialDnsProbe -Hostname $Hostname
    if (-not $dns.succeeded) {
        $observations.Add([pscustomobject]@{
            probeType = 'network'
            check = 'github-dns-resolution'
            outcome = 'failure'
            code = 'DNS_FAILURE'
            reference = ('host/' + $Hostname)
            source = $null
            metadata = [pscustomobject]@{ note = 'dns resolution failed; https probe not attempted' }
        })
        return [pscustomobject]@{
            provider = 'github'
            operation = 'transport-probe'
            executionContext = [pscustomobject]@{ runtime = $Runtime; runtimeIdentifier = $RuntimeIdentifier; platform = $Platform; isolation = $Isolation }
            observations = $observations
        }
    }
    $observations.Add([pscustomobject]@{
        probeType = 'network'
        check = 'github-dns-resolution'
        outcome = 'success'
        code = $null
        reference = ('host/' + $Hostname)
        source = $null
        metadata = $null
    })

    # --- HTTPS transport (unauthenticated; any HTTP response proves reachability) ---
    $http = Invoke-AgentCredentialHttpProbe -Uri $endpoint -TimeoutSeconds $TimeoutSeconds
    switch ($http.transport) {
        'reachable' {
            $observations.Add([pscustomobject]@{
                probeType = 'network'
                check = 'github-https-transport'
                outcome = 'success'
                code = $null
                reference = ('endpoint/' + $Hostname)
                source = $null
                metadata = [pscustomobject]@{ statusCode = $http.statusCode }
            })
        }
        'timeout' {
            $observations.Add([pscustomobject]@{
                probeType = 'network'
                check = 'github-https-transport'
                outcome = 'timeout'
                code = $null
                reference = ('endpoint/' + $Hostname)
                source = $null
                metadata = [pscustomobject]@{ note = 'generic transport timeout currently has no dedicated diagnosis code in v0.2' }
            })
        }
        'tls' {
            $observations.Add([pscustomobject]@{
                probeType = 'network'
                check = 'github-https-transport'
                outcome = 'failure'
                code = $null
                reference = ('endpoint/' + $Hostname)
                source = $null
                metadata = [pscustomobject]@{ note = 'tls transport failure; no matching taxonomy code' }
            })
        }
        'proxy' {
            $observations.Add([pscustomobject]@{
                probeType = 'network'
                check = 'github-https-transport'
                outcome = 'failure'
                code = 'PROXY_MISCONFIGURED'
                reference = ('endpoint/' + $Hostname)
                source = $null
                metadata = [pscustomobject]@{ note = 'proxy-related transport failure' }
            })
        }
        default {
            $observations.Add([pscustomobject]@{
                probeType = 'network'
                check = 'github-https-transport'
                outcome = 'failure'
                code = $null
                reference = ('endpoint/' + $Hostname)
                source = $null
                metadata = [pscustomobject]@{ note = 'generic transport failure; no matching taxonomy code' }
            })
        }
    }

    [pscustomobject]@{
        provider = 'github'
        operation = 'transport-probe'
        executionContext = [pscustomobject]@{ runtime = $Runtime; runtimeIdentifier = $RuntimeIdentifier; platform = $Platform; isolation = $Isolation }
        observations = $observations
    }
}