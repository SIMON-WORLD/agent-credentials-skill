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

    $refSourceType = [string](Get-AgentCredentialResolverField $Reference 'sourceType')
    if ([string]::IsNullOrEmpty($refSourceType)) { return $false }

    # sourceType: must be explicitly declared.
    $sourceTypes = @(Get-AgentCredentialResolverField $Descriptor 'supportedSourceTypes')
    if ($sourceTypes.Count -eq 0) { return $false }
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
    $eligibleIds = @()
    foreach ($d in $descriptors) {
        if (Test-AgentCredentialResolverEligible -Reference $Reference -Descriptor $d) {
            $eligibleIds += [string](Get-AgentCredentialResolverField $d 'resolverId')
        }
    }

    # Explicit requested resolver: honor it when eligible; fail closed otherwise. No substitution.
    if (-not [string]::IsNullOrEmpty($RequestedId)) {
        $requested = $descriptors | Where-Object { ([string](Get-AgentCredentialResolverField $_ 'resolverId')) -eq $RequestedId } | Select-Object -First 1
        if ($null -eq $requested -or -not (Test-AgentCredentialResolverEligible -Reference $Reference -Descriptor $requested)) {
            return [PSCustomObject]@{
                status     = 'requested_incompatible'
                resolver   = $null
                reasonCode = 'RESOLVER_ERROR'
                summary    = 'explicit resolver is incompatible or unavailable'
            }
        }
        return [PSCustomObject]@{
            status     = 'matched'
            resolver   = $requested
            reasonCode = $null
            summary    = ('selected resolver ' + $RequestedId)
        }
    }

    if ($eligibleIds.Count -eq 0) {
        # Distinguish unsupported source type (a source type no resolver declares) from generic
        # resolver mismatch. Both fail closed; the reasonCode is sanitized.
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

    if ($eligibleIds.Count -gt 1) {
        return [PSCustomObject]@{
            status     = 'ambiguous'
            resolver   = $null
            reasonCode = 'RESOLVER_ERROR'
            summary    = 'multiple compatible resolvers; resolver selection is ambiguous'
        }
    }

    $selected = $descriptors | Where-Object { ([string](Get-AgentCredentialResolverField $_ 'resolverId')) -eq $eligibleIds[0] } | Select-Object -First 1
    return [PSCustomObject]@{
        status     = 'matched'
        resolver   = $selected
        reasonCode = $null
        summary    = ('selected resolver ' + $eligibleIds[0])
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

    # Typed resolver outcome object (e.g. set by an adapter to signal a specific failure).
    $typed = $raw.PSObject.Properties['outcome']
    if ($null -ne $typed -and $null -ne $raw) {
        $typedOutcome = [string]($raw.outcome)
        $typedReason = [string](Get-AgentCredentialResolverField $raw 'reasonCode')
        $typedKind = [string](Get-AgentCredentialResolverField $raw 'materialKind')
        $typedTarget = Get-AgentCredentialResolverField $raw 'target'
        $typedLife = Get-AgentCredentialResolverField $raw 'lifetimeSeconds'
        $typedSummary = [string](Get-AgentCredentialResolverField $raw 'summary')
        if ([string]::IsNullOrEmpty($typedOutcome)) { $typedOutcome = 'failed' }
        if ([string]::IsNullOrEmpty($typedKind)) { $typedKind = 'value' }
        if ($typedOutcome -eq 'resolved' -and [string]::IsNullOrEmpty($typedTarget)) { $typedTarget = $EnvironmentVariable }
        if ($null -eq $typedLife) { $typedLife = $(if ($typedOutcome -eq 'resolved') { $LifetimeSeconds } else { $null }) }
        return [PSCustomObject]@{
            contractVersion = '0.5.0'
            resolverId      = $ResolverId
            provider        = $Provider
            outcome         = $typedOutcome
            reasonCode      = $(if ([string]::IsNullOrEmpty($typedReason)) { $null } else { $typedReason })
            materialKind    = $typedKind
            target          = $(if ($null -eq $typedTarget) { $null } else { [string]$typedTarget })
            lifetimeSeconds = $typedLife
            summary         = $(if ([string]::IsNullOrEmpty($typedSummary)) { 'resolver produced outcome' } else { $typedSummary })
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
