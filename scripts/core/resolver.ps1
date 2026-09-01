<#
.SYNOPSIS
  Provider-neutral v0.5 Credential Resolver core: capability matching + sanitized outcome binding.
.DESCRIPTION
  Resolver selection is a pure function of (CredentialReference, ResolverDescriptor[]). It does NOT
  read credentials, keyrings, env values, files, or providers; it does NOT execute anything; it does
  NOT choose an account/profile/reference. It only reports which single resolver implementation is
  capable of resolving an already-selected logical reference, fail-closed (exactly one, otherwise
  no_match / ambiguous / requested_incompatible). The runtime-private PowerShell resolver binding is
  a reference implementation, not the protocol: a resolver callback receives the exact logical
  reference and returns raw material transiently; the public outcome is sanitized metadata only.
  Import-safe: dot-sourcing only defines functions and produces no output.
.NOTES
  .machine-tokens is a reference storage convention, never a protocol requirement. No contract
  function here depends on a filesystem path, a specific provider, or a PowerShell-only mechanism.
#>

$script:acsRepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$script:acsAllowedReasonCodes = $null

function Get-AgentCredentialResolverAllowedReasonCodes {
    <#
    .SYNOPSIS
      Returns the allowed resolver reason-code vocabulary for sanitization.
    .DESCRIPTION
      The v0.2 diagnostic failure codes plus the single resolver-specific RESOLVER_ERROR. Loaded
      once from schema/diagnostic-codes.json (and cached) so the binding never accepts arbitrary
      resolver-supplied reason codes. If the registry cannot be read, a fixed fallback list is used.
      This is a reference-binding concern, not the pure matcher; it performs no credential access.
    #>
    if ($null -ne $script:acsAllowedReasonCodes) { return $script:acsAllowedReasonCodes }
    $fallback = @(
        'CREDENTIAL_NOT_FOUND','CREDENTIAL_INVALID','CREDENTIAL_SOURCE_UNAVAILABLE',
        'SANDBOX_KEYRING_UNAVAILABLE','ENV_NOT_PROPAGATED','NETWORK_BLOCKED','DNS_FAILURE',
        'PROXY_MISCONFIGURED','TOOL_NOT_INSTALLED','TOOL_EXECUTION_UNAVAILABLE',
        'WRONG_ACCOUNT','WRONG_HOST','WRONG_PROFILE','TOKEN_SCOPE_INSUFFICIENT',
        'AUTH_CHECK_TIMEOUT','DIAGNOSIS_INCONCLUSIVE','RESOLVER_ERROR'
    )
    $reg = Join-Path $script:acsRepoRoot 'schema\diagnostic-codes.json'
    if (Test-Path -LiteralPath $reg) {
        try {
            $r = Get-Content -Raw -LiteralPath $reg | ConvertFrom-Json
            $script:acsAllowedReasonCodes = @($r.codes.failure.PSObject.Properties.Name) + @('RESOLVER_ERROR')
        } catch {
            $script:acsAllowedReasonCodes = $fallback
        }
    } else {
        $script:acsAllowedReasonCodes = $fallback
    }
    return $script:acsAllowedReasonCodes
}

function Get-AgentCredentialResolverField {
    <#
    .SYNOPSIS
      Reads a single field without throwing (PSCustomObject or IDictionary).
    #>
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-AgentCredentialResolverEligible {
    <#
    .SYNOPSIS
      Returns true when a ResolverDescriptor is capable of resolving a CredentialReference.
    .DESCRIPTION
      Pure predicate. provider match is explicit when supportedProviders is non-empty (empty =
      provider-agnostic, i.e. no constraint); supportedSourceTypes must contain the reference
      sourceType (a resolver must declare at least one concrete source type); host/profile are
      constraint-only (empty = any). Never reads values, never depends on array order.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )
    if ($null -eq $Descriptor) { return $false }
    $resolverId = [string](Get-AgentCredentialResolverField $Descriptor 'resolverId')
    if ([string]::IsNullOrEmpty($resolverId)) { return $false }
    # Contract gate: a descriptor must be a v0.5 descriptor and declare the resolve capability.
    if ([string](Get-AgentCredentialResolverField $Descriptor 'contractVersion') -ne '0.5.0') { return $false }
    $capabilities = @(Get-AgentCredentialResolverField $Descriptor 'capabilities')
    if ($capabilities -notcontains 'resolve') { return $false }

    $refSourceType = [string](Get-AgentCredentialResolverField $Reference 'sourceType')
    if ([string]::IsNullOrEmpty($refSourceType)) { return $false }

    # sourceType: must be explicitly declared.
    $sourceTypes = @(Get-AgentCredentialResolverField $Descriptor 'supportedSourceTypes')
    if ($sourceTypes.Count -eq 0) { return $false }
    $validSourceTypes = @('env','file','keyring','connector','cli','broker','profile','config','other')
    foreach ($st in $sourceTypes) { if ($validSourceTypes -notcontains [string]$st) { return $false } }
    if ($sourceTypes -notcontains $refSourceType) { return $false }

    # provider: empty supportedProviders = provider-agnostic (no constraint); otherwise must contain.
    $providers = @(Get-AgentCredentialResolverField $Descriptor 'supportedProviders')
    $refProvider = [string](Get-AgentCredentialResolverField $Reference 'provider')
    if ($providers.Count -gt 0) {
        if ([string]::IsNullOrEmpty($refProvider)) { return $false }
        if ($providers -notcontains $refProvider) { return $false }
    }

    # host constraint: empty = any host.
    $hosts = @(Get-AgentCredentialResolverField $Descriptor 'supportedHosts')
    $refHost = Get-AgentCredentialResolverField $Reference 'host'
    if ($hosts.Count -gt 0) {
        if ($null -eq $refHost) { return $false }
        if ($hosts -notcontains [string]$refHost) { return $false }
    }

    # profile constraint: empty = any profile.
    $profiles = @(Get-AgentCredentialResolverField $Descriptor 'supportedProfiles')
    $refProfile = Get-AgentCredentialResolverField $Reference 'profile'
    if ($profiles.Count -gt 0) {
        if ($null -eq $refProfile) { return $false }
        if ($profiles -notcontains [string]$refProfile) { return $false }
    }

    return $true
}

function Select-AgentCredentialResolver {
    <#
    .SYNOPSIS
      Deterministic fail-closed resolver selection for an already-selected CredentialReference.
    .DESCRIPTION
      Pure matching of a single selected CredentialReference against a ResolverDescriptor[].
      Returns a verdict object with status one of: matched (exactly one, or an explicitly requested
      compatible resolver), no_match (zero compatible), ambiguous (two or more equally compatible
      with no explicit request), requested_incompatible (an explicit -RequestedId was absent or not
      compatible), or invalid_reference (the reference lacks required identity fields). It never
      uses array order as authority and never reads any credential.
    .PARAMETER Reference
      The CredentialReference to resolve (used as-is; never modified or re-selected).
    .PARAMETER Descriptors
      ResolverDescriptor[] capability metadata. An object or an array of objects is accepted.
    .PARAMETER RequestedId
      Optional explicit resolverId the caller requires. When supplied and compatible it wins;
      when absent or incompatible the matcher fails closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][object[]]$Descriptors,
        [string]$RequestedId = $null
    )

    $refProvider = [string](Get-AgentCredentialResolverField $Reference 'provider')
    $refSourceType = [string](Get-AgentCredentialResolverField $Reference 'sourceType')
    $refReference = [string](Get-AgentCredentialResolverField $Reference 'reference')
    if ([string]::IsNullOrEmpty($refProvider) -or [string]::IsNullOrEmpty($refSourceType) -or [string]::IsNullOrEmpty($refReference)) {
        return [PSCustomObject]@{
            status     = 'invalid_reference'
            resolver   = $null
            reasonCode = $null
            summary    = 'credential reference is missing required identity fields'
        }
    }

    $descriptors = @($Descriptors | Where-Object { $null -ne $_ })

    # --- duplicate resolverId fails closed (array order must never decide) ---
    $idCount = @{}
    foreach ($d in $descriptors) {
        $id = [string](Get-AgentCredentialResolverField $d 'resolverId')
        if ([string]::IsNullOrEmpty($id)) { $id = '' }
        if ($idCount.ContainsKey($id)) { $idCount[$id] = $idCount[$id] + 1 } else { $idCount[$id] = 1 }
    }
    foreach ($key in $idCount.Keys) {
        if ($idCount[$key] -gt 1) {
            return [PSCustomObject]@{
                status     = 'ambiguous'
                resolver   = $null
                reasonCode = 'RESOLVER_ERROR'
                summary    = 'duplicate resolverId; resolver selection is ambiguous'
            }
        }
    }

    # --- track the actual eligible descriptor objects (no id -> reverse lookup) ---
    $eligible = @()
    foreach ($d in $descriptors) {
        if (Test-AgentCredentialResolverEligible -Reference $Reference -Descriptor $d) {
            $eligible += $d
        }
    }

    # --- explicit requested resolver: exactly one descriptor of that id, and it must be eligible ---
    if (-not [string]::IsNullOrEmpty($RequestedId)) {
        $requestedCandidates = @($descriptors | Where-Object { ([string](Get-AgentCredentialResolverField $_ 'resolverId')) -eq $RequestedId })
        if ($requestedCandidates.Count -ne 1) {
            return [PSCustomObject]@{
                status     = 'requested_incompatible'
                resolver   = $null
                reasonCode = 'RESOLVER_ERROR'
                summary    = 'explicit resolver is incompatible or unavailable'
            }
        }
        if (-not (Test-AgentCredentialResolverEligible -Reference $Reference -Descriptor $requestedCandidates[0])) {
            return [PSCustomObject]@{
                status     = 'requested_incompatible'
                resolver   = $null
                reasonCode = 'RESOLVER_ERROR'
                summary    = 'explicit resolver is incompatible or unavailable'
            }
        }
        return [PSCustomObject]@{
            status     = 'matched'
            resolver   = $requestedCandidates[0]
            reasonCode = $null
            summary    = ('selected resolver ' + $RequestedId)
        }
    }

    # --- non-requested path: exactly one eligible, else fail closed ---
    if ($eligible.Count -eq 0) {
        $allSourceTypes = @()
        foreach ($d in $descriptors) {
            $allSourceTypes += @(Get-AgentCredentialResolverField $d 'supportedSourceTypes')
        }
        $unsupportedSourceType = ($allSourceTypes.Count -eq 0) -or ($allSourceTypes -notcontains $refSourceType)
        return [PSCustomObject]@{
            status     = 'no_match'
            resolver   = $null
            reasonCode = $(if ($unsupportedSourceType) { 'CREDENTIAL_SOURCE_UNAVAILABLE' } else { 'RESOLVER_ERROR' })
            summary    = $(if ($unsupportedSourceType) { 'no resolver supports the credential source type' } else { 'no compatible resolver' })
        }
    }

    if ($eligible.Count -gt 1) {
        return [PSCustomObject]@{
            status     = 'ambiguous'
            resolver   = $null
            reasonCode = 'RESOLVER_ERROR'
            summary    = 'multiple compatible resolvers; resolver selection is ambiguous'
        }
    }

    $selected = $eligible[0]
    $selectedId = [string](Get-AgentCredentialResolverField $selected 'resolverId')
    return [PSCustomObject]@{
        status     = 'matched'
        resolver   = $selected
        reasonCode = $null
        summary    = ('selected resolver ' + $selectedId)
    }
}

function ConvertTo-AgentCredentialResolverFailClosedOutcome {
    <#
    .SYNOPSIS
      Maps a fail-closed matcher verdict to a sanitized public ResolverOutcome.
    .DESCRIPTION
      Used when the matcher cannot select exactly one resolver. It produces metadata only; it never
      carries raw material, exception text, paths, or the reference value. The reasonCode is a v0.2
      failure code or the resolver-specific RESOLVER_ERROR.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Verdict,
        [string]$ResolverId = 'unselected',
        [string]$Provider = $null,
        [string]$Summary = $null
    )
    if ($null -eq $Verdict) {
        $status = 'failed'
        $reasonCode = 'RESOLVER_ERROR'
    } else {
        $status = 'failed'
        $reasonCode = [string](Get-AgentCredentialResolverField $Verdict 'reasonCode')
        if ([string]::IsNullOrEmpty($reasonCode)) { $reasonCode = 'RESOLVER_ERROR' }
        if ($null -eq $Summary) { $Summary = [string](Get-AgentCredentialResolverField $Verdict 'summary') }
    }
    if ([string]::IsNullOrEmpty($Summary)) { $Summary = 'resolver selection did not produce a single compatible resolver' }
    return [PSCustomObject]@{
        contractVersion = '0.5.0'
        resolverId      = $ResolverId
        provider        = $Provider
        outcome         = $status
        reasonCode      = $reasonCode
        materialKind    = 'value'
        target          = $null
        lifetimeSeconds = $null
        summary         = $Summary
    }
}

function Resolve-AgentCredentialReference {
    <#
    .SYNOPSIS
      Reference implementation of the runtime-private PowerShell resolver binding (not the protocol).
    .DESCRIPTION
      Calls a PowerShell resolver callback with the exact logical reference and normalizes the result
      into a SANITIZED public ResolverOutcome (metadata only). The raw CredentialMaterial exists only
      transiently inside this call and is never returned, serialized, logged, or persisted. A resolver
      may return a raw value (resolved), a typed outcome object (outcome + optional reasonCode), $null
      (failed), or throw (failed + RESOLVER_ERROR). Resolver exception text is never surfaced.
    .PARAMETER Reference
      The exact logical CredentialReference to resolve; passed verbatim to the resolver, never modified.
    .PARAMETER Resolver
      PowerShell [scriptblock] or function reference implementation of the resolve step.
    .PARAMETER ResolverId
      Identifier used for the public outcome.
    .PARAMETER Provider
      Provider name for the public outcome, when known.
    .PARAMETER EnvironmentVariable
      Optional intended injection target reported in the outcome when produced (never the value).
    .PARAMETER LifetimeSeconds
      Default bounded lifetime reported in seconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Reference,
        [Parameter(Mandatory = $true)][scriptblock]$Resolver,
        [string]$ResolverId = 'reference-impl',
        [string]$Provider = $null,
        [string]$EnvironmentVariable = $null,
        [int]$LifetimeSeconds = 300
    )

    $refId = [string](Get-AgentCredentialResolverField $Reference 'reference')
    if ([string]::IsNullOrEmpty($refId)) { $refId = [string]$Reference }

    $raw = $null
    $throwCode = $null
    try {
        $raw = & $Resolver $Reference
    }
    catch {
        $throwCode = 'RESOLVER_ERROR'
    }

    if ($null -ne $throwCode) {
        return [PSCustomObject]@{
            contractVersion = '0.5.0'
            resolverId      = $ResolverId
            provider        = $Provider
            outcome         = 'failed'
            reasonCode      = $throwCode
            materialKind    = 'value'
            target          = $null
            lifetimeSeconds = $null
            summary         = 'resolver threw an exception'
        }
    }

    # Typed resolver outcome object: only `outcome` and `reasonCode` are read, for validation.
    # summary/target/materialKind/lifetimeSeconds from the callback are never trusted or propagated.
    $typed = $raw.PSObject.Properties['outcome']
    if ($null -ne $typed -and $null -ne $raw) {
        $typedOutcome = [string]$raw.outcome
        $typedReason = [string](Get-AgentCredentialResolverField $raw 'reasonCode')
        $allowedReasonCodes = Get-AgentCredentialResolverAllowedReasonCodes
        $reasonCode = $null
        if (-not [string]::IsNullOrEmpty($typedReason)) {
            if ($allowedReasonCodes -contains $typedReason) { $reasonCode = $typedReason }
            else { $reasonCode = 'RESOLVER_ERROR' }
        }
        if ($typedOutcome -notin @('resolved','unavailable','failed')) {
            return [PSCustomObject]@{
                contractVersion = '0.5.0'
                resolverId      = $ResolverId
                provider        = $Provider
                outcome         = 'failed'
                reasonCode      = 'RESOLVER_ERROR'
                materialKind    = 'value'
                target          = $null
                lifetimeSeconds = $null
                summary         = 'resolver returned an invalid typed outcome'
            }
        }
        if ($typedOutcome -eq 'resolved') {
            return [PSCustomObject]@{
                contractVersion = '0.5.0'
                resolverId      = $ResolverId
                provider        = $Provider
                outcome         = 'resolved'
                reasonCode      = $null
                materialKind    = 'value'
                target          = $(if ($null -eq $EnvironmentVariable) { $null } else { [string]$EnvironmentVariable })
                lifetimeSeconds = $LifetimeSeconds
                summary         = 'resolver produced material'
            }
        }
        return [PSCustomObject]@{
            contractVersion = '0.5.0'
            resolverId      = $ResolverId
            provider        = $Provider
            outcome         = $typedOutcome
            reasonCode      = $(if ($null -eq $reasonCode) { 'RESOLVER_ERROR' } else { $reasonCode })
            materialKind    = 'value'
            target          = $null
            lifetimeSeconds = $null
            summary         = 'resolver did not produce material'
        }
    }

    if ($null -eq $raw -or [string]::IsNullOrEmpty([string]$raw)) {
        return [PSCustomObject]@{
            contractVersion = '0.5.0'
            resolverId      = $ResolverId
            provider        = $Provider
            outcome         = 'failed'
            reasonCode      = 'RESOLVER_ERROR'
            materialKind    = 'value'
            target          = $null
            lifetimeSeconds = $null
            summary         = 'resolver returned no material'
        }
    }

    # Resolved: metadata only. The raw value never enters this object.
    return [PSCustomObject]@{
        contractVersion = '0.5.0'
        resolverId      = $ResolverId
        provider        = $Provider
        outcome         = 'resolved'
        reasonCode      = $null
        materialKind    = 'value'
        target          = $(if ($null -eq $EnvironmentVariable) { $null } else { [string]$EnvironmentVariable })
        lifetimeSeconds = $LifetimeSeconds
        summary         = 'resolver produced material'
    }
}
