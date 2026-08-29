<#
.SYNOPSIS
  GitHub multi-account/profile credential-context adapter (Agent Credential Layer v0.3).
.DESCRIPTION
  Converts already-sanitized GitHub discovery/auth observations into safe v0.3
  CredentialReference-shaped objects and constructs explicit GitHub profiles.
  This module never executes gh, never reads credentials, never touches the network,
  keyring, environment values, or filesystem paths, never switches the active account,
  and never mutates credential state. Selection is never performed here; it belongs to
  Resolve-AgentCredentialContext. Import-safe: dot-sourcing only defines functions.
#>

function Get-AgentCredentialGitHubContextField {
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

function New-AgentCredentialGitHubReference {
    <#
    .SYNOPSIS
      Internal constructor of a safe GitHub CredentialReference-shaped object.
    .DESCRIPTION
      Whitelist fields only: provider/sourceType/reference/account/profile/host.
      Raw values, filesystem paths, and arbitrary observation metadata are never echoed.
    #>
    param(
        [string]$SourceType,
        [string]$Reference,
        [string]$Account = $null,
        [string]$HostName = $null,
        [string]$Profile = $null
    )
    return [PSCustomObject]@{
        provider   = 'github'
        sourceType = $SourceType
        reference  = $Reference
        account    = $Account
        profile    = $Profile
        host       = $HostName
    }
}

function Get-AgentCredentialGitHubReferences {
    <#
    .SYNOPSIS
      Converts sanitized GitHub discovery/auth observations into safe credential references.
    .DESCRIPTION
      Consumes observation objects produced by the v0.2 GitHub provider adapters
      (Get-AgentCredentialGitHubDiscovery / Get-AgentCredentialGitHubAuthProbe) and maps
      only success observations into CredentialReference-shaped objects: env observations
      become env/ references, connector hints become connector/ references, and CLI/keyring/
      file-backed auth entries become stable logical references. Distinct accounts on the
      same host stay distinct; identical logical references collapse deterministically;
      conflicting metadata for the same logical reference fails closed with a sanitized
      conflict result. active/scope/etc. are never carried: selection is not performed here.
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
        $probeType = [string](Get-AgentCredentialGitHubContextField $obs 'probeType')
        $check = [string](Get-AgentCredentialGitHubContextField $obs 'check')
        $outcome = [string](Get-AgentCredentialGitHubContextField $obs 'outcome')
        if ($outcome -ne 'success') { continue }
        $obsRef = [string](Get-AgentCredentialGitHubContextField $obs 'reference')
        $meta = Get-AgentCredentialGitHubContextField $obs 'metadata'

        $newRef = $null

        if ($probeType -eq 'source' -and $check -eq 'env-credential-reference' -and $obsRef -like 'env/*') {
            $newRef = New-AgentCredentialGitHubReference -SourceType 'env' -Reference $obsRef -HostName ([string](Get-AgentCredentialGitHubContextField $meta 'target'))
        }
        elseif ($probeType -eq 'source' -and $check -eq 'connector-hint' -and -not [string]::IsNullOrEmpty($obsRef)) {
            $newRef = New-AgentCredentialGitHubReference -SourceType 'connector' -Reference $obsRef
        }
        elseif ($probeType -eq 'auth' -and $check -eq 'github-auth-status') {
            $hostName = [string](Get-AgentCredentialGitHubContextField $meta 'host')
            $login = [string](Get-AgentCredentialGitHubContextField $meta 'login')
            $srcCat = [string](Get-AgentCredentialGitHubContextField $meta 'tokenSourceCategory')
            $srcRef = [string](Get-AgentCredentialGitHubContextField $meta 'tokenSourceReference')
            if ($srcCat -eq 'environment' -and $srcRef -like 'env/*') {
                $newRef = New-AgentCredentialGitHubReference -SourceType 'env' -Reference $srcRef -Account $login -HostName $hostName
            }
            elseif ($srcCat -eq 'keyring') {
                $refId = 'keyring/' + $hostName + $(if ($login) { '/' + $login } else { '' })
                $newRef = New-AgentCredentialGitHubReference -SourceType 'keyring' -Reference $refId -Account $login -HostName $hostName
            }
            elseif ($srcCat -eq 'file') {
                # Logical file reference only; the filesystem path is never carried.
                $refId = 'file/' + $hostName + $(if ($login) { '/' + $login } else { '' })
                $newRef = New-AgentCredentialGitHubReference -SourceType 'file' -Reference $refId -Account $login -HostName $hostName
            }
            else {
                $refId = 'cli/' + $hostName + $(if ($login) { '/' + $login } else { '' })
                $newRef = New-AgentCredentialGitHubReference -SourceType 'cli' -Reference $refId -Account $login -HostName $hostName
            }
        }

        if ($null -eq $newRef) { continue }

        $key = $newRef.provider + '|' + $newRef.reference
        $acct = [string]$newRef.account
        $h = [string]$newRef.host
        if ($seen.ContainsKey($key)) {
            $prev = $seen[$key]
            if ($prev.account -ne $acct -or $prev.host -ne $h) {
                return [PSCustomObject]@{
                    provider   = 'github'
                    references = @()
                    conflict   = $newRef.reference
                    summary    = 'conflicting metadata for logical reference'
                }
            }
            # identical logical reference with identical metadata: collapse deterministically
        }
        else {
            $seen[$key] = [PSCustomObject]@{ account = $acct; host = $h }
            $refs.Add($newRef)
        }
    }

    # Neutral stable ordering for reporting only; never a selection tiebreaker.
    $sorted = @($refs | Sort-Object -Property @{ Expression = { $_.reference } })
    return [PSCustomObject]@{
        provider   = 'github'
        references = $sorted
        conflict   = $null
        summary    = 'references converted'
    }
}

function New-AgentCredentialGitHubProfile {
    <#
    .SYNOPSIS
      Constructs an explicit GitHub credential profile (logical configuration only).
    .DESCRIPTION
      Profiles are explicit logical configuration; personal/work are never inferred from
      account names. A profile selects references by reference and carries no secrets.
    .PARAMETER Name
      Stable logical profile name (for example personal or work).
    .PARAMETER References
      Ordered reference ids this profile selects.
    .PARAMETER ExpectedAccount
      Optional account this profile expects.
    .PARAMETER ExpectedHost
      Optional host this profile expects.
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
        throw 'GitHub profile name is required'
    }
    return [PSCustomObject]@{
        name            = $Name
        provider        = 'github'
        references      = @($References)
        expectedAccount = $ExpectedAccount
        expectedHost    = $ExpectedHost
    }
}
