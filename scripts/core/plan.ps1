<#
.SYNOPSIS
  Provider-neutral v0.4 Credential Broker core: gate + execution-plan constructor.
.DESCRIPTION
  Get-AgentCredentialBrokerGate maps already-produced v0.2 diagnosis summary and v0.3
  resolver context outcome (plus optional v0.2 resolution-policy decision) into exactly
  one deterministic Broker state: ready | blocked | needs_decision. It never runs
  discovery/diagnosis, never calls providers, never reads network/keyring/files/env
  credential values, never resolves raw credentials, never executes commands, and never
  mutates auth/global state. New-AgentCredentialExecutionPlan builds a public v0.4 plan
  object that conforms to schema/credential-plan.schema.json. Import-safe: dot-sourcing
  only defines functions.
#>

function Get-AgentCredentialPlanField {
    <#
    .SYNOPSIS
      Reads a single field from an object without throwing (PSCustomObject or IDictionary).
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

function ConvertTo-AgentCredentialPlanReference {
    <#
    .SYNOPSIS
      Projects any object to the contract-approved logical reference identity fields only.
    .DESCRIPTION
      Returns provider/sourceType/reference/account/profile/host. All other properties
      (including arbitrary metadata) are never echoed. Values are kept only as strings when
      present; null/unknown become $null.
    #>
    param(
        [object]$Reference
    )
    if ($null -eq $Reference) { return $null }
    $provider = [string](Get-AgentCredentialPlanField $Reference 'provider')
    $sourceType = [string](Get-AgentCredentialPlanField $Reference 'sourceType')
    $ref = [string](Get-AgentCredentialPlanField $Reference 'reference')
    if ([string]::IsNullOrEmpty($provider) -or [string]::IsNullOrEmpty($sourceType) -or [string]::IsNullOrEmpty($ref)) {
        return $null
    }
    $acct = Get-AgentCredentialPlanField $Reference 'account'
    $prof = Get-AgentCredentialPlanField $Reference 'profile'
    $hostValue = Get-AgentCredentialPlanField $Reference 'host'
    return [PSCustomObject]@{
        provider   = $provider
        sourceType = $sourceType
        reference  = $ref
        account    = $(if ($null -eq $acct) { $null } else { [string]$acct })
        profile    = $(if ($null -eq $prof) { $null } else { [string]$prof })
        host       = $(if ($null -eq $hostValue) { $null } else { [string]$hostValue })
    }
}

function Get-AgentCredentialBrokerGate {
    <#
    .SYNOPSIS
      Deterministic Broker gate for a v0.2 diagnosis summary + v0.3 context outcome.
    .DESCRIPTION
      Returns exactly one of ready | blocked | needs_decision. Precedence is explicit and
      fails closed: hard non-decision blocks (context unavailable/conflict, diagnosis
      unavailable) first, then decision-required states (ambiguous context, inconclusive
      diagnosis, or an intervention-style v0.2 decision), then ready (healthy + selected +
      exactly one safe reference), else blocked. INTERACTIVE_AUTH / reauthRequired never
      trigger authentication; they only map to needs_decision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Diagnosis,
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [object]$Resolution = $null
    )

    $diagnosisStatus = [string](Get-AgentCredentialPlanField $Diagnosis 'status')
    $outcome = [string](Get-AgentCredentialPlanField $Context 'outcome')
    $contextSelected = Get-AgentCredentialPlanField $Context 'selectedReference'
    $strategy = [string](Get-AgentCredentialPlanField $Resolution 'strategy')
    $reauthRequired = Get-AgentCredentialPlanField $Resolution 'reauthRequired'

    $interventionCodes = @(
        'INTERACTIVE_AUTH',
        'MANUAL_REVIEW',
        'SELECT_ACCOUNT',
        'SELECT_PROFILE',
        'CORRECT_HOST',
        'REQUEST_ADDITIONAL_SCOPE'
    )
    $intervention = ($interventionCodes -contains $strategy) -or ($reauthRequired -eq $true)

    # 1) Hard non-decision block (fail closed): context unavailable/conflict or diagnosis unavailable.
    if ($outcome -in @('unavailable', 'conflict') -or $diagnosisStatus -eq 'unavailable') {
        return 'blocked'
    }
    # 2) Decision-required states.
    if ($outcome -eq 'ambiguous' -or $diagnosisStatus -eq 'inconclusive' -or $intervention) {
        return 'needs_decision'
    }
    # 3) Ready: healthy + selected + exactly one safe selected reference, no intervention.
    if ($diagnosisStatus -eq 'healthy' -and $outcome -eq 'selected' -and $null -ne $contextSelected) {
        return 'ready'
    }
    # 4) Any other non-ready deterministic state.
    return 'blocked'
}

function New-AgentCredentialExecutionPlan {
    <#
    .SYNOPSIS
      Constructs a public v0.4 Credential Execution Plan conforming to credential-plan.schema.json.
    .DESCRIPTION
      Combines a v0.2 diagnosis summary, a v0.3 context outcome, and optional v0.2 resolution
      decision into a plan with logical references only. selectedCredentialReference is set only
      when the context resolved a reference; non-selected contexts yield null. Arbitrary input
      metadata never leaks; summaries are fixed and safe. No raw credential ever appears.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Provider,
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        [Parameter(Mandatory = $true)]
        [object]$Diagnosis,
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [object]$Resolution = $null,
        [object]$ExecutionMetadata = $null
    )

    $diagnosisStatus = [string](Get-AgentCredentialPlanField $Diagnosis 'status')
    $diagnosisCode = Get-AgentCredentialPlanField $Diagnosis 'code'
    $outcome = [string](Get-AgentCredentialPlanField $Context 'outcome')
    $contextSelectedRaw = Get-AgentCredentialPlanField $Context 'selectedReference'
    $strategy = [string](Get-AgentCredentialPlanField $Resolution 'strategy')

    $gate = Get-AgentCredentialBrokerGate -Diagnosis $Diagnosis -Context $Context -Resolution $Resolution

    # decisionCode: ready => null; needs_decision => supplied strategy (if any) else MANUAL_REVIEW;
    # blocked => supplied strategy (if any) else null. Only existing v0.2 codes are used.
    $decisionCode = $null
    if ($gate -eq 'needs_decision') {
        $decisionCode = if (-not [string]::IsNullOrEmpty($strategy)) { $strategy } else { 'MANUAL_REVIEW' }
    }
    elseif ($gate -eq 'blocked') {
        if (-not [string]::IsNullOrEmpty($strategy)) { $decisionCode = $strategy }
    }

    $selectedRef = $null
    if ($outcome -eq 'selected' -and $null -ne $contextSelectedRaw) {
        $selectedRef = ConvertTo-AgentCredentialPlanReference $contextSelectedRaw
    }

    # Safe, fixed summaries (never echo arbitrary input).
    $diagnosisSummary = [PSCustomObject]@{
        status  = $diagnosisStatus
        code    = $(if ($null -eq $diagnosisCode) { $null } else { [string]$diagnosisCode })
        summary = ('diagnosis status: ' + $diagnosisStatus)
    }
    $contextSummary = [PSCustomObject]@{
        outcome           = $outcome
        selectedReference = $selectedRef
    }

    # executionMetadata: whitelist runtime/host/note only; default to unknown/host null.
    $runtime = [string](Get-AgentCredentialPlanField $ExecutionMetadata 'runtime')
    $hostMeta = Get-AgentCredentialPlanField $ExecutionMetadata 'host'
    $note = Get-AgentCredentialPlanField $ExecutionMetadata 'note'
    if ([string]::IsNullOrEmpty($runtime)) { $runtime = 'unknown' }
    $execMeta = [PSCustomObject]@{
        runtime = $runtime
        host    = $(if ($null -eq $hostMeta) { $null } else { [string]$hostMeta })
        note    = $(if ($null -eq $note) { $null } else { [string]$note })
    }

    return [PSCustomObject]@{
        contractVersion            = '0.4.0'
        provider                   = $Provider
        operation                  = $Operation
        diagnosis                  = $diagnosisSummary
        context                    = $contextSummary
        gate                       = $gate
        decisionCode               = $decisionCode
        selectedCredentialReference = $selectedRef
        executionMetadata          = $execMeta
    }
}
