<#
.SYNOPSIS
  Provider-neutral Resolution Policy (Agent Credential Layer v0.2).
.DESCRIPTION
  Answers: what non-destructive action should be RECOMMENDED, given the diagnosis
  classification and available credential-source evidence. It never executes recovery,
  never authenticates, and never emits a final Diagnosis Result. Interactive
  authentication is a last resort and requires explicit policy evidence that usable
  existing/non-interactive paths are exhausted and authentication is genuinely required.
  Import-safe: dot-sourcing only defines functions.
#>
function Get-AgentCredentialResolutionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Diagnosis,
        [object[]]$CredentialSources = @(),
        [string[]]$Capabilities = @(),
        [object]$Context = $null,
        [switch]$CredentialSearchComplete,
        [switch]$InteractiveAuthJustified
    )

    $code = $Diagnosis.code
    $strategy = 'MANUAL_REVIEW'
    $reauthRequired = $false
    $actionRequired = $true
    $rationale = 'No applicable non-interactive strategy was found.'

    # Prefer an already available non-interactive path for source/context failures.
    $hasConnector = ($Capabilities -contains 'CONNECTOR_AVAILABLE') -or
        (($CredentialSources | Where-Object { $_.type -eq 'platformConnector' -and $_.available }) | Select-Object -First 1) -ne $null
    $hasCliKeyring = (($CredentialSources | Where-Object { $_.type -eq 'cliKeyring' -and $_.available }) | Select-Object -First 1) -ne $null
    $hasEnv = (($CredentialSources | Where-Object { $_.type -eq 'environment' -and $_.available }) | Select-Object -First 1) -ne $null
    $hasFile = (($CredentialSources | Where-Object { $_.type -eq 'protectedFile' -and $_.available }) | Select-Object -First 1) -ne $null
    $hasBroker = (($CredentialSources | Where-Object { $_.type -eq 'externalBroker' -and $_.available }) | Select-Object -First 1) -ne $null
    $hasNonInteractive = $hasConnector -or $hasCliKeyring -or $hasEnv -or $hasFile -or $hasBroker

    $nonInteractive = 'MANUAL_REVIEW'
    if ($hasConnector) { $nonInteractive = 'USE_CONNECTOR' }
    elseif ($hasCliKeyring) { $nonInteractive = 'USE_EXISTING_CLI_AUTH' }
    elseif ($hasEnv) { $nonInteractive = 'USE_PROCESS_SCOPED_ENV' }
    elseif ($hasFile) { $nonInteractive = 'USE_PROTECTED_FILE' }
    elseif ($hasBroker) { $nonInteractive = 'USE_EXTERNAL_BROKER' }

    switch ($code) {
        $null {
            $strategy = 'NO_ACTION'
            $actionRequired = $false
            $rationale = 'No diagnosis; no action is recommended.'
        }
        'TOOL_NOT_INSTALLED' {
            $strategy = 'INSTALL_TOOL'
            $rationale = 'The required provider tool is not installed.'
        }
        'DNS_FAILURE' {
            $strategy = 'FIX_DNS'
            $rationale = 'Provider hostname resolution failed.'
        }
        'PROXY_MISCONFIGURED' {
            $strategy = 'FIX_PROXY'
            $rationale = 'Proxy-related transport failure detected.'
        }
        'NETWORK_BLOCKED' {
            $strategy = 'FIX_NETWORK'
            $rationale = 'Provider endpoint network reachability failed.'
        }
        'AUTH_CHECK_TIMEOUT' {
            $strategy = 'RETRY_AUTH_CHECK'
            $actionRequired = $false
            $rationale = 'Authentication-state check timed out; retry the check.'
        }
        'WRONG_ACCOUNT' {
            $strategy = 'SELECT_ACCOUNT'
            $rationale = 'The active credential belongs to the wrong account.'
        }
        'WRONG_PROFILE' {
            $strategy = 'SELECT_PROFILE'
            $rationale = 'The active credential uses the wrong profile selection.'
        }
        'WRONG_HOST' {
            $strategy = 'CORRECT_HOST'
            $rationale = 'The active credential targets the wrong host.'
        }
        'TOKEN_SCOPE_INSUFFICIENT' {
            $strategy = 'REQUEST_ADDITIONAL_SCOPE'
            $rationale = 'The credential lacks the required scope.'
        }
        'DIAGNOSIS_INCONCLUSIVE' {
            $strategy = 'MANUAL_REVIEW'
            $rationale = 'Evidence is insufficient for a specific diagnosis; review required.'
        }
        'SANDBOX_KEYRING_UNAVAILABLE' {
            $strategy = $nonInteractive
            $actionRequired = -not ($strategy -in @('USE_CONNECTOR', 'USE_EXISTING_CLI_AUTH', 'USE_PROCESS_SCOPED_ENV', 'USE_PROTECTED_FILE'))
            $rationale = 'Preferred keyring path unavailable; prefer an available non-interactive path.'
        }
        'CREDENTIAL_SOURCE_UNAVAILABLE' {
            $strategy = $nonInteractive
            $actionRequired = -not ($strategy -in @('USE_CONNECTOR', 'USE_EXISTING_CLI_AUTH', 'USE_PROCESS_SCOPED_ENV', 'USE_PROTECTED_FILE'))
            $rationale = 'A configured credential source is unavailable; prefer an available path.'
        }
        'ENV_NOT_PROPAGATED' {
            $strategy = $nonInteractive
            $actionRequired = -not ($strategy -in @('USE_CONNECTOR', 'USE_EXISTING_CLI_AUTH', 'USE_PROCESS_SCOPED_ENV', 'USE_PROTECTED_FILE'))
            $rationale = 'Expected environment reference absent; prefer an available path.'
        }
        'CREDENTIAL_NOT_FOUND' {
            if ($CredentialSearchComplete -and $InteractiveAuthJustified -and -not $hasNonInteractive) {
                $strategy = 'INTERACTIVE_AUTH'
                $reauthRequired = $true
                $rationale = 'No usable existing credential path remains and non-interactive recovery is exhausted; interactive authentication is the final fallback.'
            } else {
                $strategy = 'MANUAL_REVIEW'
                $rationale = 'No credential path was established; configure a source or review.'
            }
        }
        'CREDENTIAL_INVALID' {
            if ($CredentialSearchComplete -and $InteractiveAuthJustified -and -not $hasNonInteractive) {
                $strategy = 'INTERACTIVE_AUTH'
                $reauthRequired = $true
                $rationale = 'Credential is rejected, no usable non-interactive path remains, and authentication is genuinely required.'
            } else {
                $strategy = 'REFRESH_CREDENTIAL'
                $actionRequired = $false
                $rationale = 'Credential rejected; refresh from a configured source before considering interactive authentication.'
            }
        }
        default {
            $strategy = 'MANUAL_REVIEW'
            $rationale = 'No conservative non-interactive strategy applies; review required.'
        }
    }

    [pscustomobject]@{
        strategy = $strategy
        reauthRequired = $reauthRequired
        actionRequired = $actionRequired
        rationale = $rationale
    }
}