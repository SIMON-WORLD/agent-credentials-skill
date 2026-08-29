<#
.SYNOPSIS
  Provider-neutral Credential Context resolver (Agent Credential Layer v0.3).
.DESCRIPTION
  Resolves a validated CredentialContext-compatible object into a small internal
  selection result using only logical references and metadata. It never reads
  credentials, never reads environment/keyring/files, never executes commands,
  never switches provider account state, and never emits a Diagnosis Result.
  Selection is deterministic and fails closed on ambiguity; explicit requested
  profile/account/host constraints are never silently relaxed.
  Import-safe: dot-sourcing only defines functions.
#>

function Get-AgentCredentialContextField {
    <#
    .SYNOPSIS
      Reads a single field from a PSCustomObject or IDictionary without throwing.
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

function ConvertTo-AgentCredentialContextReferenceSummary {
    <#
    .SYNOPSIS
      Projects a credential reference to its safe summary fields only.
    .DESCRIPTION
      Returns provider/sourceType/reference/account/profile/host. Metadata and any
      other fields are never echoed, so secret or error sentinels cannot leak.
    #>
    param(
        [object]$Reference
    )
    if ($null -eq $Reference) { return $null }
    return [PSCustomObject]@{
        provider   = Get-AgentCredentialContextField $Reference 'provider'
        sourceType = Get-AgentCredentialContextField $Reference 'sourceType'
        reference  = Get-AgentCredentialContextField $Reference 'reference'
        account    = Get-AgentCredentialContextField $Reference 'account'
        profile    = Get-AgentCredentialContextField $Reference 'profile'
        host       = Get-AgentCredentialContextField $Reference 'host'
    }
}

function Resolve-AgentCredentialContext {
    <#
    .SYNOPSIS
      Resolves a validated CredentialContext-compatible object into an internal
      selection result.
    .DESCRIPTION
      Filters available references deterministically by provider, requestedProfile,
      expectedAccount, and expectedHost (when present), then selects the single
      compatible reference, fails closed as ambiguous when several are compatible,
      returns unavailable when none is compatible, and validates any preselected
      reference against the same constraints.
    .PARAMETER InputObject
      A validated CredentialContext-compatible object carrying references only
      (never raw credential values).
    .OUTPUTS
      PSCustomObject with provider, operation, outcome, selectedProfile,
      selectedReference, candidateReferences, summary. Internal, small, non-public.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $provider = Get-AgentCredentialContextField $InputObject 'provider'
    $operation = Get-AgentCredentialContextField $InputObject 'operation'

    if ([string]::IsNullOrEmpty($provider)) {
        return [PSCustomObject]@{
            provider            = ''
            operation           = $operation
            outcome             = 'conflict'
            selectedProfile     = $null
            selectedReference   = $null
            candidateReferences = @()
            summary             = 'invalid input: provider is missing'
        }
    }

    $requestedProfile = Get-AgentCredentialContextField $InputObject 'requestedProfile'
    $expectedAccount = Get-AgentCredentialContextField $InputObject 'expectedAccount'
    $expectedHost = Get-AgentCredentialContextField $InputObject 'expectedHost'
    $preselect = Get-AgentCredentialContextField $InputObject 'selectedReference'

    $rawRefs = @(Get-AgentCredentialContextField $InputObject 'availableReferences')
    $refs = @($rawRefs | Where-Object { $null -ne $_ })

    # provider filter first; a reference from another provider is never considered
    $providerRefs = @($refs | Where-Object { (Get-AgentCredentialContextField $_ 'provider') -eq $provider })

    # deterministic filter by explicit constraints. A reference without the required
    # metadata never matches an explicit expectation (no silent relaxation).
    $compatible = @($providerRefs | Where-Object {
        ([string]::IsNullOrEmpty($requestedProfile) -or ((Get-AgentCredentialContextField $_ 'profile') -eq $requestedProfile)) -and
        ([string]::IsNullOrEmpty($expectedAccount) -or ((Get-AgentCredentialContextField $_ 'account') -eq $expectedAccount)) -and
        ([string]::IsNullOrEmpty($expectedHost) -or ((Get-AgentCredentialContextField $_ 'host') -eq $expectedHost))
    })

    # Neutral stable ordering used only for reporting, never as a selection tiebreaker.
    $candidateList = @(
        $compatible |
            ForEach-Object { ConvertTo-AgentCredentialContextReferenceSummary $_ } |
            Sort-Object -Property @{ Expression = { $_.provider } }, @{ Expression = { $_.reference } }
    )

    $outcome = 'unavailable'
    $summary = 'no compatible reference'
    $selectedProfile = $null
    $selectedRef = $null

    if ($null -ne $preselect) {
        $preselectOk =
            ((Get-AgentCredentialContextField $preselect 'provider') -eq $provider) -and
            ([string]::IsNullOrEmpty($requestedProfile) -or ((Get-AgentCredentialContextField $preselect 'profile') -eq $requestedProfile)) -and
            ([string]::IsNullOrEmpty($expectedAccount) -or ((Get-AgentCredentialContextField $preselect 'account') -eq $expectedAccount)) -and
            ([string]::IsNullOrEmpty($expectedHost) -or ((Get-AgentCredentialContextField $preselect 'host') -eq $expectedHost))
        $preselectId = Get-AgentCredentialContextField $preselect 'reference'
        $preselectMatches = @($refs | Where-Object { (Get-AgentCredentialContextField $_ 'reference') -eq $preselectId })
        if ($preselectOk -and ($preselectMatches.Count -eq 1)) {
            $outcome = 'selected'
            $summary = 'preselected reference preserved'
            $selectedRef = ConvertTo-AgentCredentialContextReferenceSummary $preselect
            $preselectProfile = Get-AgentCredentialContextField $preselect 'profile'
            $selectedProfile = if ([string]::IsNullOrEmpty($preselectProfile)) { $requestedProfile } else { $preselectProfile }
        }
        else {
            $outcome = 'conflict'
            $summary = 'preselected reference conflicts with constraints'
        }
    }
    elseif ($compatible.Count -eq 1) {
        $outcome = 'selected'
        $summary = 'selected the single compatible reference'
        $selectedRef = ConvertTo-AgentCredentialContextReferenceSummary $compatible[0]
        $candidateProfile = Get-AgentCredentialContextField $compatible[0] 'profile'
        $selectedProfile = if ([string]::IsNullOrEmpty($candidateProfile)) { $requestedProfile } else { $candidateProfile }
    }
    elseif ($compatible.Count -gt 1) {
        $outcome = 'ambiguous'
        $summary = 'multiple compatible references; fail closed'
    }

    return [PSCustomObject]@{
        provider            = $provider
        operation           = $operation
        outcome             = $outcome
        selectedProfile     = $selectedProfile
        selectedReference   = $selectedRef
        candidateReferences = $candidateList
        summary             = $summary
    }
}
