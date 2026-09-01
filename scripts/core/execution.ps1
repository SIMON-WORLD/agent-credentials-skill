<#
.SYNOPSIS
  Generic process-scoped credential execution boundary (Agent Credential Layer v0.3).
.DESCRIPTION
  Executes one child process with a credential resolved at execution time and injected
  only into the CHILD process environment. The parent/global authentication state is
  never mutated, the raw credential is never returned, logged, or persisted, and this
  module never becomes a secret store. Provider-neutral: no GitHub/npm/provider
  mappings, no login/refresh/switch, no keyring backend, no Diagnosis Result.
  Import-safe: dot-sourcing only defines functions and produces no output.
#>

function ConvertTo-AgentCredentialArgumentString {
    <#
    .SYNOPSIS
      Quotes an argument list for a direct child-process invocation without shell
      string concatenation or evaluation.
    #>
    param(
        [string[]]$Arguments = @()
    )
    $quoted = @()
    foreach ($a in $Arguments) {
        if ($a -match '[\s"]') {
            $escaped = $a -replace '"', '\"'
            $quoted += ('"' + $escaped + '"')
        }
        else {
            $quoted += $a
        }
    }
    return ($quoted -join ' ')
}

function Test-AgentCredentialScopedSecretPattern {
    <#
    .SYNOPSIS
      Deterministic secret-pattern scan used to keep captured output non-secret.
    #>
    param(
        [AllowNull()]
        [string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $patterns = @(
        'gho_[A-Za-z0-9]{20,}',
        'ghp_[A-Za-z0-9]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'pypi-Ag[A-Za-z0-9]{10,}',
        'glpat-[A-Za-z0-9_-]{20,}',
        'AKIA[0-9A-Z]{16}',
        'xox[baprs]-[A-Za-z0-9-]{10,}'
    )
    foreach ($p in $patterns) {
        if ($Text -match $p) { return $true }
    }
    return $false
}

function Invoke-AgentCredentialScopedCommand {
    <#
    .SYNOPSIS
      Runs one child process with a credential injected only into the child environment.
    .DESCRIPTION
      The resolver scriptblock receives the logical reference and returns the raw value
      at execution time. The raw value is placed into the child process environment only;
      the parent environment is never modified, including on failure and timeout paths.
      The returned object carries the reference only, never the raw value.
    .PARAMETER CredentialReference
      Safe logical credential reference: a string or an object exposing a reference field.
    .PARAMETER Executable
      Executable path or name to launch.
    .PARAMETER ArgumentList
      Argument array passed directly to the child process (no shell string concatenation).
    .PARAMETER EnvironmentVariable
      Child environment-variable name that receives the resolved credential.
    .PARAMETER Resolver
      Scriptblock that receives the logical reference and returns the raw credential value.
    .PARAMETER WorkingDirectory
      Optional working directory for the child process.
    .PARAMETER TimeoutSeconds
      Optional timeout; when exceeded the child is terminated and outcome=timeout.
    .PARAMETER IncludeStdoutStderr
      When set, captured stdout/stderr are returned only if they pass the secret-pattern scan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$CredentialReference,
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
        [object]$PreResolved = $null
    )

    # --- extract the logical reference string (never a value) ---
    $refId = $null
    if ($CredentialReference -is [string]) {
        $refId = $CredentialReference
    }
    elseif ($null -ne $CredentialReference) {
        $refProp = $CredentialReference.PSObject.Properties['reference']
        if ($null -ne $refProp) { $refId = [string]$refProp.Value }
    }
    if ([string]::IsNullOrEmpty($refId)) {
        return [PSCustomObject]@{
            outcome  = 'failure'
            exitCode = $null
            reference = ''
            command  = $Executable
            stdout   = $null
            stderr   = $null
            summary  = 'invalid credential reference'
        }
    }
    if ($EnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        return [PSCustomObject]@{
            outcome  = 'failure'
            exitCode = $null
            reference = $refId
            command  = $Executable
            stdout   = $null
            stderr   = $null
            summary  = 'invalid environment variable name'
        }
    }
    if ([string]::IsNullOrEmpty($Executable)) {
        return [PSCustomObject]@{
            outcome  = 'failure'
            exitCode = $null
            reference = $refId
            command  = $Executable
            stdout   = $null
            stderr   = $null
            summary  = 'invalid executable'
        }
    }
    if (-not [string]::IsNullOrEmpty($WorkingDirectory) -and -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        return [PSCustomObject]@{
            outcome  = 'failure'
            exitCode = $null
            reference = $refId
            command  = $Executable
            stdout   = $null
            stderr   = $null
            summary  = 'working directory not found'
        }
    }

    # --- resolve the raw value at execution time; never leak resolver errors ---
    # -PreResolved carries an already-resolved runtime-private value (v0.5 descriptor-aware path);
    # when absent the legacy resolver callback is invoked with the logical reference (string).
    $rawValue = $null
    if ($null -ne $PreResolved) {
        $rawValue = $PreResolved
    }
    else {
        try {
            $rawValue = & $Resolver $refId
        }
        catch {
            $rawValue = $null
            return [PSCustomObject]@{
                outcome  = 'failure'
                exitCode = $null
                reference = $refId
                command  = $Executable
                stdout   = $null
                stderr   = $null
                summary  = 'credential resolver failed'
            }
        }
    }

    # --- build the child process with the credential in the child environment only ---
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Executable
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = ConvertTo-AgentCredentialArgumentString $ArgumentList
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }

    if ($null -ne $psi.PSObject.Properties['Environment']) {
        $psi.Environment[$EnvironmentVariable] = [string]$rawValue
    }
    else {
        $psi.EnvironmentVariables[$EnvironmentVariable] = [string]$rawValue
    }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        $rawValue = $null
        return [PSCustomObject]@{
            outcome  = 'failure'
            exitCode = $null
            reference = $refId
            command  = $Executable
            stdout   = $null
            stderr   = $null
            summary  = 'executable could not be started'
        }
    }

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        if (-not $proc.WaitForExit(($TimeoutSeconds * 1000))) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit() } catch { }
        }
    }
    else {
        try { $proc.WaitForExit() } catch { }
    }

    $exitCode = $null
    if (-not $timedOut) {
        try { $exitCode = $proc.ExitCode } catch { }
    }
    $stdoutText = ''
    $stderrText = ''
    try { $stdoutText = [string]$stdoutTask.Result } catch { }
    try { $stderrText = [string]$stderrTask.Result } catch { }
    try { $proc.Dispose() } catch { }

    # --- sanitize; raw value is discarded and never enters the result ---
    $rawString = [string]$rawValue
    $rawValue = $null
    $safeOut = $null
    $safeErr = $null
    if ($IncludeStdoutStderr) {
        # Captured output is returned only when it is provably non-secret: it must not
        # contain the resolved raw value and must not match known secret patterns.
        $outClean = [string]::IsNullOrEmpty($rawString) -or (-not $stdoutText.Contains($rawString))
        $errClean = [string]::IsNullOrEmpty($rawString) -or (-not $stderrText.Contains($rawString))
        if ($outClean -and (-not (Test-AgentCredentialScopedSecretPattern $stdoutText))) { $safeOut = $stdoutText }
        if ($errClean -and (-not (Test-AgentCredentialScopedSecretPattern $stderrText))) { $safeErr = $stderrText }
    }

    $summary = 'command completed successfully'
    $outcome = 'success'
    if ($timedOut) {
        $outcome = 'timeout'
        $summary = 'command timed out'
    }
    elseif ($null -ne $exitCode -and $exitCode -ne 0) {
        $outcome = 'failure'
        $summary = 'command failed'
    }

    return [PSCustomObject]@{
        outcome   = $outcome
        exitCode  = $exitCode
        reference = $refId
        command   = $Executable
        stdout    = $safeOut
        stderr    = $safeErr
        summary   = $summary
    }
}
