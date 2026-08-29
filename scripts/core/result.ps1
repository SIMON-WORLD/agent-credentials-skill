<#
.SYNOPSIS
  Provider-neutral Diagnosis Result Assembler (Agent Credential Layer v0.2).
.DESCRIPTION
  Combines provider/context metadata, sanitized evidence, the Diagnosis Core result,
  and the Resolution Policy result into exactly one public result: Diagnosis Result
  v0.2 (schema/diagnosis-result.schema.json). It introduces no new protocol concepts.
  Import-safe: dot-sourcing only defines functions.
#>
function Get-AgentCredentialResolutionSteps {
    [CmdletBinding()]
    param([string]$Strategy)

    switch ($Strategy) {
        'NO_ACTION' { return @() }
        'USE_CONNECTOR' { return @('Route the operation through the selected connector.') }
        'USE_EXISTING_CLI_AUTH' { return @('Use the accessible authenticated CLI/keyring path.') }
        'USE_PROCESS_SCOPED_ENV' { return @('Inject the credential reference into the child process.') }
        'USE_PROTECTED_FILE' { return @('Use the explicitly configured protected file source.') }
        'USE_EXTERNAL_BROKER' { return @('Resolve the credential from the external broker.') }
        'INSTALL_TOOL' { return @('Install the required tool or use a REST fallback.') }
        'FIX_DNS' { return @('Repair DNS resolution, then re-diagnose.') }
        'FIX_PROXY' { return @('Repair proxy configuration, then re-diagnose.') }
        'FIX_NETWORK' { return @('Repair network reachability, then re-diagnose.') }
        'RETRY_AUTH_CHECK' { return @('Retry the validation probe with a bounded time budget.') }
        'SELECT_ACCOUNT' { return @('Select the correct account credential.') }
        'SELECT_PROFILE' { return @('Select the correct profile.') }
        'CORRECT_HOST' { return @('Use the credential for the correct host.') }
        'REQUEST_ADDITIONAL_SCOPE' { return @('Obtain a credential with the required scopes.') }
        'REFRESH_CREDENTIAL' { return @('Re-register the credential from a configured source.') }
        'MANUAL_REVIEW' { return @('Escalate to a human with the sanitized evidence.') }
        'INTERACTIVE_AUTH' { return @('Interactive authentication as final fallback, with user consent.') }
        default { return @() }
    }
}


<#
.SYNOPSIS
  Internal-to-public evidence normalization for Diagnosis Result v0.2.
.DESCRIPTION
  Maps internal probeType vocabulary onto the public evidence enum and forwards only
  whitelisted public fields. Unknown fields (including internal source/identity/network
  sub-objects) are dropped; nothing raw is ever passed through.
#>
function ConvertTo-AgentCredentialPublicEvidence {
    [CmdletBinding()]
    param([object[]]$Observations)

    $probeTypeMap = @{
        'auth' = 'provider-api'
        'source' = 'credential-source'
        'tool' = 'command'
        'host' = 'context'
        'config' = 'context'
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($obs in @($Observations)) {
        $pt = [string]$obs.probeType
        if ($probeTypeMap.ContainsKey($pt)) { $pt = $probeTypeMap[$pt] }
        $item = [ordered]@{
            probeType = $pt
            check = [string]$obs.check
            outcome = [string]$obs.outcome
            code = $obs.code
        }
        if ($null -ne $obs.summary) { $item.summary = [string]$obs.summary }
        if ($null -ne $obs.reference) { $item.reference = [string]$obs.reference }
        if ($null -ne $obs.timestamp) { $item.timestamp = [string]$obs.timestamp }
        if ($null -ne $obs.durationMs) { $item.durationMs = [int]$obs.durationMs }
        if ($null -ne $obs.metadata) { $item.metadata = $obs.metadata }
        $out.Add([pscustomobject]$item)
    }
    return $out
}


<#
.SYNOPSIS
  Builds the public diagnosis object, omitting optional category when it is null.
#>
function Get-AgentCredentialDiagnosisPublicObject {
    [CmdletBinding()]
    param($Code, $Related, $Category, [bool]$Conclusive, [string]$Summary)

    $props = [ordered]@{
        code = $Code
        relatedCodes = @($Related)
        conclusive = $Conclusive
        summary = $Summary
    }
    if ($null -ne $Category) { $props.category = $Category }
    return [pscustomobject]$props
}

function New-AgentCredentialDiagnosisResult {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [string]$Operation,
        [object]$Context = $null,
        [string[]]$Capabilities = @(),
        [object[]]$AvailableCredentialSources = @(),
        [object]$SelectedCredentialSource = $null,
        [object]$Identity = $null,
        [object]$Network = $null,
        [object[]]$Evidence = @(),
        [object]$Diagnosis = $null,
        [object]$Policy = $null
    )

    $diagCode = $null
    $diagRelated = @()
    $diagCategory = $null
    $diagConclusive = $true
    $diagSummary = ''
    if ($null -ne $Diagnosis) {
        $diagCode = $Diagnosis.code
        $diagRelated = @($Diagnosis.relatedCodes)
        $diagCategory = $Diagnosis.category
        $diagConclusive = [bool]$Diagnosis.conclusive
        $diagSummary = [string]$Diagnosis.summary
    }

    $strategy = 'NO_ACTION'
    $reauthRequired = $false
    $actionRequired = $false
    if ($null -ne $Policy) {
        $strategy = [string]$Policy.strategy
        $reauthRequired = [bool]$Policy.reauthRequired
        $actionRequired = [bool]$Policy.actionRequired
    }

    $status = 'unavailable'
    if ($null -eq $diagCode) { $status = 'healthy' }
    elseif ($diagCode -in @('AUTH_CHECK_TIMEOUT', 'DIAGNOSIS_INCONCLUSIVE')) { $status = 'inconclusive' }
    elseif ($strategy -in @('USE_CONNECTOR', 'USE_EXISTING_CLI_AUTH', 'USE_PROCESS_SCOPED_ENV', 'USE_PROTECTED_FILE')) { $status = 'degraded' }
    else { $status = 'unavailable' }

    $ctx = [pscustomobject]@{
        runtime = $(if ($ExecutionContext -and $ExecutionContext.runtime) { [string]$ExecutionContext.runtime } else { 'unknown' })
        runtimeIdentifier = $(if ($ExecutionContext) { $ExecutionContext.runtimeIdentifier } else { $null })
        platform = $(if ($ExecutionContext) { $ExecutionContext.platform } else { $null })
        isolation = $(if ($ExecutionContext) { $ExecutionContext.isolation } else { $null })
    }

    [pscustomobject]@{
        schemaVersion = '0.2.0'
        provider = $Provider
        operation = $Operation
        executionContext = $ctx
        status = $status
        capabilities = @($Capabilities)
        availableCredentialSources = @($AvailableCredentialSources)
        selectedCredentialSource = $SelectedCredentialSource
        identity = $Identity
        network = $Network
        diagnosis = $(Get-AgentCredentialDiagnosisPublicObject -Code $diagCode -Related $diagRelated -Category $diagCategory -Conclusive $diagConclusive -Summary $diagSummary)
        recommendedResolution = [pscustomobject]@{
            strategy = $strategy
            steps = @(Get-AgentCredentialResolutionSteps -Strategy $strategy)
            actionRequired = $actionRequired
        }
        reauthRequired = $reauthRequired
        evidence = @(ConvertTo-AgentCredentialPublicEvidence -Observations $Evidence)
    }
}