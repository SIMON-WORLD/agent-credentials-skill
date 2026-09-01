<#
.SYNOPSIS
  v0.4 Broker execution gate bridge - enforce an ExecutionPlan gate, then delegate to v0.3.
.DESCRIPTION
  Invoke-AgentCredentialExecutionPlan consumes an already-produced v0.4 public ExecutionPlan
  plus caller-supplied execution inputs, enforces the frozen Broker gate invariants, and only
  then delegates actual child-process execution to the existing v0.3 process-scoped boundary
  (Invoke-AgentCredentialScopedCommand). It never reimplements ProcessStartInfo, environment
  injection, argument quoting, timeout/termination, raw-secret resolution, or stdout/stderr
  safety logic. It never authenticates, reauthenticates, selects an account/profile, repairs
  context, reruns diagnosis, or alters the plan. Fail-closed: any gate violation aborts before
  the resolver callback, any raw credential access, or child-process launch. Provider-neutral:
  GitHub/npm/example-provider plans follow the identical path.
.NOTES
  validate-plan.ps1 is a CLI/exit-code validator (it calls exit), unsuitable for in-process
  use on every execution. This module therefore implements only the minimal equivalent
  pre-execution invariant checks and documents that boundary here; it does not shell out.
#>

function Get-AgentCredentialBrokerExecutionField {
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

function New-AgentCredentialExecutionNonResult {
    <#
    .SYNOPSIS
      Builds a sanitized non-execution result (no resolver, no child launch).
    #>
    param(
        [string]$Provider,
        [string]$Operation,
        [string]$Outcome,
        [string]$Summary
    )
    return [PSCustomObject]@{
        provider  = $Provider
        operation = $Operation
        outcome   = $Outcome
        executed  = $false
        exitCode  = $null
        summary   = $Summary
    }
}

function Invoke-AgentCredentialExecutionPlan {
    <#
    .SYNOPSIS
      Executes a v0.4 ExecutionPlan if and only if its Broker gate invariants all hold.
    .DESCRIPTION
      Enforces contractVersion=0.4.0, gate=ready, diagnosis.status=healthy,
      context.outcome=selected, non-null selectedCredentialReference, a match between
      selectedCredentialReference and context.selectedReference, and no intervention
      decisionCode. Any violation fails closed before the resolver, raw access, or child
      launch. On success it delegates to Invoke-AgentCredentialScopedCommand and returns a
      sanitized result carrying the logical reference only; the raw value exists transiently
      only inside the existing scoped execution path and never enters this result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExecutionPlan,
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentVariable,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Resolver,
        [string]$WorkingDirectory = '',
        [int]$TimeoutSeconds = 0,
        [switch]$IncludeStdoutStderr,
        [object[]]$ResolverDescriptors = @(),
        [string]$ResolverRequestedId = $null
    )

    $provider = [string](Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'provider')
    $operation = [string](Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'operation')

    # --- gate invariants (fail closed before any resolver raw access / child launch) ---
    $contractVersion = [string](Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'contractVersion')
    $gate = [string](Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'gate')
    $diagnosis = Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'diagnosis'
    $context = Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'context'
    $selRef = Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'selectedCredentialReference'
    $decisionCode = Get-AgentCredentialBrokerExecutionField $ExecutionPlan 'decisionCode'

    if ($contractVersion -ne '0.4.0') {
        return New-AgentCredentialExecutionNonResult -Provider $provider -Operation $operation -Outcome 'error' -Summary 'unsupported plan contractVersion'
    }
    if ($gate -notin @('ready', 'blocked', 'needs_decision')) {
        return New-AgentCredentialExecutionNonResult -Provider $provider -Operation $operation -Outcome 'error' -Summary 'unknown gate'
    }
    if ($gate -eq 'blocked') {
        return New-AgentCredentialExecutionNonResult -Provider $provider -Operation $operation -Outcome 'blocked' -Summary 'plan gate is blocked'
    }
    if ($gate -eq 'needs_decision') {
        return New-AgentCredentialExecutionNonResult -Provider $provider -Operation $operation -Outcome 'needs_decision' -Summary 'plan requires a decision'
    }

    # gate == ready: verify all ready invariants.
    $diagStatus = [string](Get-AgentCredentialBrokerExecutionField $diagnosis 'status')
    $outcome = [string](Get-AgentCredentialBrokerExecutionField $context 'outcome')
    $ctxRef = Get-AgentCredentialBrokerExecutionField $context 'selectedReference'
    $dc = if ($null -eq $decisionCode) { '' } else { [string]$decisionCode }

    $invariantOk = $true
    if ($diagStatus -ne 'healthy') { $invariantOk = $false }
    if ($outcome -ne 'selected') { $invariantOk = $false }
    if ($null -eq $selRef) { $invariantOk = $false }
    if ($null -eq $ctxRef) { $invariantOk = $false }
    if ($null -ne $selRef -and $null -ne $ctxRef) {
        if ((Get-AgentCredentialBrokerExecutionField $selRef 'reference') -ne (Get-AgentCredentialBrokerExecutionField $ctxRef 'reference')) { $invariantOk = $false }
        if ((Get-AgentCredentialBrokerExecutionField $selRef 'provider') -ne (Get-AgentCredentialBrokerExecutionField $ctxRef 'provider')) { $invariantOk = $false }
    }
    if (-not [string]::IsNullOrEmpty($dc)) { $invariantOk = $false }

    if (-not $invariantOk) {
        return New-AgentCredentialExecutionNonResult -Provider $provider -Operation $operation -Outcome 'error' -Summary 'ready plan violates pre-execution invariants'
    }

    # --- v0.5 descriptor-aware execution: full reference + typed-failure semantics ---
    if ($ResolverDescriptors.Count -gt 0) {
        $verdict = Select-AgentCredentialResolver -Reference $selRef -Descriptors $ResolverDescriptors -RequestedId $ResolverRequestedId
        if ($verdict.status -ne 'matched') {
            return New-AgentCredentialExecutionNonResult -Provider $provider -Operation $operation -Outcome 'failed' -Summary 'resolver selection did not produce a single compatible resolver'
        }
        $internal = Invoke-AgentCredentialResolverMaterial -Reference $selRef -Resolver $Resolver -EnvironmentVariable $EnvironmentVariable
        if ($internal.outcome -ne 'resolved') {
            # Fail closed: never launch the child, never coerce the typed failure object into a value.
            return [PSCustomObject]@{
                provider   = $provider
                operation  = $operation
                outcome    = 'failed'
                executed   = $false
                exitCode   = $null
                summary    = ('resolver ' + $internal.reasonCode + ' :: ' + $internal.summary)
                reasonCode = $internal.reasonCode
            }
        }
        # Success: inject the runtime-private material only into the child env via the existing
        # scoped boundary. -PreResolved means the resolver is not invoked a second time.
        $ref = Invoke-AgentCredentialScopedCommand -CredentialReference $selRef -Executable $Executable -ArgumentList $ArgumentList -EnvironmentVariable $EnvironmentVariable -Resolver $Resolver -PreResolved $internal.material -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -IncludeStdoutStderr:$IncludeStdoutStderr
        $exitCode = $null
        $summary = 'execution completed'
        if ($null -ne $ref.exitCode) { $exitCode = $ref.exitCode }
        if ($ref.outcome -eq 'timeout') { $summary = 'execution timed out' }
        elseif ($null -eq $exitCode) { $summary = 'execution could not start (resolver or launch failure)' }
        elseif ($exitCode -ne 0) { $summary = 'execution failed' }
        return [PSCustomObject]@{
            provider  = $provider
            operation = $operation
            outcome   = 'executed'
            executed  = $true
            exitCode  = $exitCode
            summary   = $summary
        }
    }

    # --- legacy path (no descriptors): unchanged v0.4 caller-supplied resolver behavior ---
    $ref = Invoke-AgentCredentialScopedCommand -CredentialReference $selRef -Executable $Executable -ArgumentList $ArgumentList -EnvironmentVariable $EnvironmentVariable -Resolver $Resolver -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -IncludeStdoutStderr:$IncludeStdoutStderr

    $exitCode = $null
    $summary = 'execution completed'
    if ($null -ne $ref.exitCode) { $exitCode = $ref.exitCode }
    if ($ref.outcome -eq 'timeout') { $summary = 'execution timed out' }
    elseif ($null -eq $exitCode) { $summary = 'execution could not start (resolver or launch failure)' }
    elseif ($exitCode -ne 0) { $summary = 'execution failed' }

    # Sanitized: only provider/operation/outcome/executed/exitCode/summary; no raw value,
    # no resolver exception text, no arbitrary plan metadata, no stdout/stderr.
    return [PSCustomObject]@{
        provider  = $provider
        operation = $operation
        outcome   = 'executed'
        executed  = $true
        exitCode  = $exitCode
        summary   = $summary
    }
}
