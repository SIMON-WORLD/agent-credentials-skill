<#
.SYNOPSIS
  npm credential-context adapter (Agent Credential Layer v0.3, second-provider proof).
.DESCRIPTION
  Converts already-sanitized npm provider observations/config references into safe v0.3
  CredentialReference-shaped objects and constructs explicit npm profiles. This module
  never executes npm, never reads .npmrc, never reads environment credential values,
  never performs network/auth operations, and never mutates npm config or auth state.
  Profiles are explicit logical configuration; personal/work are never inferred.
  Import-safe: dot-sourcing only defines functions.
#>

function Get-AgentCredentialNpmContextField {
    <#
    .SYNOPSIS
      Reads a single field from an observation object without throwing.
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

function New-AgentCredentialNpmReference {
    <#
    .SYNOPSIS
      Internal constructor of a safe npm CredentialReference-shaped object.
    .DESCRIPTION
      Whitelist fields only: provider/sourceType/reference/account/profile/host.
      Raw values, .npmrc contents, and filesystem paths are never echoed.
    #>
    param(
        [string]$SourceType,
        [string]$Reference,
        [string]$Account = $null,
        [string]$Profile = $null,
        [string]$HostName = $null
    )
    return [PSCustomObject]@{
        provider   = 'npm'
        sourceType = $SourceType
        reference  = $Reference
        account    = $Account
        profile    = $Profile
        host       = $HostName
    }
}

function Get-AgentCredentialNpmReferences {
    <#
    .SYNOPSIS
      Converts sanitized npm observations/config references into safe credential references.
    .DESCRIPTION
      Maps success observations into CredentialReference-shaped objects: env references
      become env/NPM_TOKEN, config references become logical config/<registry>/<account>
      (never a filesystem path), and connector/broker hints become connector//broker/
      logical references. Identical logical references collapse deterministically;
      conflicting metadata fails closed with a sanitized conflict result. Array order
      never affects the output.
    .PARAMETER Observations
      Sanitized observation objects (probeType/check/outcome/reference/source/metadata).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Observations
    )

    $refs = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($obs in @($Observations)) {
        if ($null -eq $obs) { continue }
        $probeType = [string](Get-AgentCredentialNpmContextField $obs 'probeType')
        $check = [string](Get-AgentCredentialNpmContextField $obs 'check')
        $outcome = [string](Get-AgentCredentialNpmContextField $obs 'outcome')
        if ($outcome -ne 'success') { continue }
        $obsRef = [string](Get-AgentCredentialNpmContextField $obs 'reference')
        $meta = Get-AgentCredentialNpmContextField $obs 'metadata'

        $newRef = $null

        if ($probeType -eq 'source' -and $check -eq 'env-credential-reference' -and $obsRef -like 'env/*') {
            $newRef = New-AgentCredentialNpmReference -SourceType 'env' -Reference $obsRef -HostName ([string](Get-AgentCredentialNpmContextField $meta 'target'))
        }
        elseif ($probeType -eq 'source' -and $check -eq 'config-credential-reference') {
            $registry = [string](Get-AgentCredentialNpmContextField $meta 'registry')
            $account = [string](Get-AgentCredentialNpmContextField $meta 'account')
            if ([string]::IsNullOrEmpty($registry)) { $registry = [string](Get-AgentCredentialNpmContextField $meta 'target') }
            if ([string]::IsNullOrEmpty($registry)) { continue }
            $refId = 'config/' + $registry + $(if ($account) { '/' + $account } else { '' })
            $newRef = New-AgentCredentialNpmReference -SourceType 'config' -Reference $refId -Account $account -HostName $registry
        }
        elseif ($probeType -eq 'source' -and $check -eq 'connector-hint' -and -not [string]::IsNullOrEmpty($obsRef)) {
            $newRef = New-AgentCredentialNpmReference -SourceType 'connector' -Reference $obsRef
        }
        elseif ($probeType -eq 'source' -and $check -eq 'broker-hint' -and -not [string]::IsNullOrEmpty($obsRef)) {
            $newRef = New-AgentCredentialNpmReference -SourceType 'broker' -Reference $obsRef
        }

        if ($null -eq $newRef) { continue }

        $key = $newRef.provider + '|' + $newRef.reference
        $acct = [string]$newRef.account
        $h = [string]$newRef.host
        if ($seen.ContainsKey($key)) {
            $prev = $seen[$key]
            if ($prev.account -ne $acct -or $prev.host -ne $h) {
                return [PSCustomObject]@{
                    provider   = 'npm'
                    references = @()
                    conflict   = $newRef.reference
                    summary    = 'conflicting metadata for logical reference'
                }
            }
        }
        else {
            $seen[$key] = [PSCustomObject]@{ account = $acct; host = $h }
            $refs.Add($newRef)
        }
    }

    $sorted = @($refs | Sort-Object -Property @{ Expression = { $_.reference } })
    return [PSCustomObject]@{
        provider   = 'npm'
        references = $sorted
        conflict   = $null
        summary    = 'references converted'
    }
}

function New-AgentCredentialNpmProfile {
    <#
    .SYNOPSIS
      Constructs an explicit npm credential profile (logical configuration only).
    .PARAMETER Name
      Stable logical profile name (for example personal or work; never inferred).
    .PARAMETER References
      Ordered reference ids this profile selects.
    .PARAMETER ExpectedAccount
      Optional account this profile expects.
    .PARAMETER ExpectedHost
      Optional registry/host this profile expects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string[]]$References = @(),
        [string]$ExpectedAccount = $null,
        [string]$ExpectedHost = $null
    )
    if ([string]::IsNullOrEmpty($Name)) {
        throw 'npm profile name is required'
    }
    return [PSCustomObject]@{
        name            = $Name
        provider        = 'npm'
        references      = @($References)
        expectedAccount = $ExpectedAccount
        expectedHost    = $ExpectedHost
    }
}
