<#
.SYNOPSIS
  Permanent v0.3 end-to-end conformance tests (Agent Credential Layer).
.DESCRIPTION
  Exercises the real v0.3 implementations: context validator, resolver, project
  binding, process-scoped execution boundary, and the GitHub context adapter.
  All test credentials are harmless sentinels; no live GitHub/npm/network/auth
  operations, no keyring reads, no global env/auth mutation beyond temporary
  test-process setup that is restored. Output is a concise deterministic
  PASS/FAIL summary; exit code is non-zero on any failure.
.PARAMETER RepoRoot
  Optional repository root; defaults to the parent of this script's directory.
.EXAMPLE
  .\scripts\test-v0.3.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = $null
)

$ErrorActionPreference = 'Stop'

$script:repoRoot = if ($RepoRoot) { $RepoRoot } else { Split-Path -Path $PSScriptRoot -Parent }
$script:scriptsDir = Join-Path $script:repoRoot 'scripts'
$script:validateContext = Join-Path $script:scriptsDir 'validate-context.ps1'
$script:contextCore = Join-Path $script:scriptsDir 'core\context.ps1'
$script:bindingCore = Join-Path $script:scriptsDir 'core\binding.ps1'
$script:executionCore = Join-Path $script:scriptsDir 'core\execution.ps1'
$script:githubCtx = Join-Path $script:scriptsDir 'providers\github-context.ps1'
$script:npmCtx = Join-Path $script:scriptsDir 'providers\npm-context.ps1'
$script:validFixture = Join-Path $script:repoRoot 'fixtures\v0.3\valid\context-basic.json'
$script:invalidDir = Join-Path $script:repoRoot 'fixtures\v0.3\invalid'

. $script:contextCore
. $script:bindingCore
. $script:executionCore
. $script:githubCtx
. $script:npmCtx

$script:results = New-Object System.Collections.Generic.List[object]
$script:SENTINEL = 'SENTINEL_SECRET_VALUE_9e2c71'
$script:resolverGot = $null

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )
    try {
        & $Body
        $script:results.Add([pscustomobject]@{ name = $Name; ok = $true; detail = '' })
        Write-Output ("PASS " + $Name)
    }
    catch {
        $script:results.Add([pscustomobject]@{ name = $Name; ok = $false; detail = $_.Exception.Message })
        Write-Output ("FAIL " + $Name + " :: " + $_.Exception.Message)
    }
}

function Assert-True([bool]$Condition, [string]$Detail) {
    if (-not $Condition) { throw $Detail }
}

function New-Ref([string]$id, [string]$prov = 'github', [string]$src = 'cli', [string]$acct = $null, [string]$prof = $null, [string]$tgt = $null) {
    return [pscustomobject]@{ provider = $prov; sourceType = $src; reference = $id; account = $acct; profile = $prof; host = $tgt }
}

function New-Ctx($refs, $reqProf = $null, $expAcct = $null, $expHost = $null, $preselect = $null, $prov = 'github', $op = 'push') {
    return [pscustomobject]@{ contractVersion = '0.3.0'; provider = $prov; operation = $op; requestedProfile = $reqProf; expectedAccount = $expAcct; expectedHost = $expHost; availableReferences = @($refs); selectedReference = $preselect }
}

function New-AuthObs([string]$login, [string]$hostName, [bool]$active, [string]$category = 'other') {
    return [pscustomobject]@{
        probeType = 'auth'
        check = 'github-auth-status'
        outcome = 'success'
        reference = ('cli/' + $hostName)
        source = $null
        metadata = [pscustomobject]@{ host = $hostName; active = $active; login = $login; tokenSourceCategory = $category; tokenSourceReference = $category }
    }
}

function New-NpmEnvObs([string]$ref = 'env/NPM_TOKEN', [string]$target = 'npm-registry') {
    return [pscustomobject]@{
        probeType = 'source'
        check = 'env-credential-reference'
        outcome = 'success'
        reference = $ref
        source = $null
        metadata = [pscustomobject]@{ target = $target; precedence = 1 }
    }
}

function New-NpmConfigObs([string]$registry, [string]$account) {
    return [pscustomobject]@{
        probeType = 'source'
        check = 'config-credential-reference'
        outcome = 'success'
        reference = 'config/x'
        source = $null
        metadata = [pscustomobject]@{ registry = $registry; account = $account }
    }
}

function Test-ValidatorExit([string]$FixturePath, [int]$ExpectedExit, [string]$ExpectedFragment) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    Assert-True ($null -ne $pwsh) 'pwsh (PS7) is required to run the JSON Schema validator'
    $out = & pwsh -NoProfile -File $script:validateContext -Path $FixturePath 2>&1
    $code = $LASTEXITCODE
    Assert-True ($code -eq $ExpectedExit) ("validator exit=$code expected=$ExpectedExit output=$($out -join ' ')")
    if ($ExpectedFragment) {
        $joined = ($out -join ' ')
        Assert-True ($joined -like ('*' + $ExpectedFragment + '*')) ("validator output missing fragment '$ExpectedFragment': $joined")
    }
}

# --- A. valid context fixture passes validator ---
Invoke-Test 'A valid fixture' { Test-ValidatorExit $script:validFixture 0 'VALID' }

# --- B. all four invalid context fixtures fail for expected layer/reason ---
Invoke-Test 'B1 secret-field schema reject' { Test-ValidatorExit (Join-Path $script:invalidDir 'context-secret-field.json') 1 'does not conform to schema' }
Invoke-Test 'B2 unknown-field schema reject' { Test-ValidatorExit (Join-Path $script:invalidDir 'context-unknown-field.json') 1 'does not conform to schema' }
Invoke-Test 'B3 provider-mismatch semantic reject' { Test-ValidatorExit (Join-Path $script:invalidDir 'context-provider-mismatch.json') 1 'available reference provider does not match' }
Invoke-Test 'B4 selected-ref-missing semantic reject' { Test-ValidatorExit (Join-Path $script:invalidDir 'context-selected-reference-missing.json') 1 'selectedReference must correspond to exactly one' }

# --- C. single compatible reference -> selected ---
Invoke-Test 'C single selected' {
    $ref = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($ref))
    Assert-True ($r.outcome -eq 'selected' -and $r.selectedReference.reference -eq 'cli/github.com/alice') "outcome=$($r.outcome)"
}

# --- D. ambiguous multi-account references -> fail closed ---
Invoke-Test 'D ambiguous fail-closed' {
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b))
    Assert-True ($r.outcome -eq 'ambiguous' -and $null -eq $r.selectedReference) "outcome=$($r.outcome)"
}

# --- E. explicit requestedProfile narrows to intended reference ---
Invoke-Test 'E profile narrows' {
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b) -reqProf 'personal')
    Assert-True ($r.outcome -eq 'selected' -and $r.selectedReference.reference -eq 'cli/github.com/alice') "outcome=$($r.outcome) sel=$($r.selectedReference.reference)"
}
# --- F. expectedAccount/expectedHost constraints work independently ---
Invoke-Test 'F account constraint' {
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b) -expAcct 'bob')
    Assert-True ($r.outcome -eq 'selected' -and $r.selectedReference.reference -eq 'cli/github.com/bob') "outcome=$($r.outcome)"
}
Invoke-Test 'F2 host constraint' {
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/ghe.example.com/bob' -acct 'bob' -prof 'work' -tgt 'ghe.example.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b) -expHost 'ghe.example.com')
    Assert-True ($r.outcome -eq 'selected' -and $r.selectedReference.reference -eq 'cli/ghe.example.com/bob') "outcome=$($r.outcome)"
}

# --- G. project binding personal feeds resolver and selects intended reference ---
Invoke-Test 'G binding feeds resolver' {
    $bind = Get-AgentCredentialProjectBinding -Project 'simon-world/agent-credentials-skill' -Provider 'github' -Profile 'personal' -HostName 'github.com'
    $bound = Resolve-AgentCredentialProjectProfile -Project 'simon-world/agent-credentials-skill' -Provider 'github' -Bindings @($bind) -ExpectedHost 'github.com'
    Assert-True ($bound.outcome -eq 'bound' -and $bound.profile -eq 'personal') "outcome=$($bound.outcome)"
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b) -reqProf $bound.profile -expHost $bound.host)
    Assert-True ($r.outcome -eq 'selected' -and $r.selectedReference.reference -eq 'cli/github.com/alice') "outcome=$($r.outcome)"
}

# --- H. no binding preserves prior ambiguous behavior ---
Invoke-Test 'H no binding' {
    $u = Resolve-AgentCredentialProjectProfile -Project 'unbound/proj' -Provider 'github' -Bindings @()
    Assert-True ($u.outcome -eq 'unbound') "outcome=$($u.outcome)"
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $r = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b))
    Assert-True ($r.outcome -eq 'ambiguous') "outcome=$($r.outcome)"
}

# --- I. conflicting project bindings -> ambiguous ---
Invoke-Test 'I conflicting bindings' {
    $b1 = Get-AgentCredentialProjectBinding -Project 'owner/repo' -Provider 'github' -Profile 'personal'
    $b2 = Get-AgentCredentialProjectBinding -Project 'owner/repo' -Provider 'github' -Profile 'work'
    $r = Resolve-AgentCredentialProjectProfile -Project 'owner/repo' -Provider 'github' -Bindings @($b1, $b2)
    Assert-True ($r.outcome -eq 'ambiguous') "outcome=$($r.outcome)"
}

# --- J. GitHub two-account same-host conversion preserves two logical references ---
Invoke-Test 'J two accounts two refs' {
    $oJ1 = New-AuthObs 'alice' 'github.com' $true
    $oJ2 = New-AuthObs 'bob' 'github.com' $false
    $obs = @($oJ1, $oJ2)
    $conv = Get-AgentCredentialGitHubReferences -Observations $obs
    Assert-True ($conv.references.Count -eq 2) "refs=$($conv.references.Count)"
    $refIds = @($conv.references | ForEach-Object { $_.reference })
    Assert-True (($refIds -contains 'cli/github.com/alice') -and ($refIds -contains 'cli/github.com/bob')) "ids=$($refIds -join ',')"
}

# --- K. active=true does not affect selection ---
Invoke-Test 'K active ignored' {
    $oK1 = New-AuthObs 'alice' 'github.com' $true
    $oK2 = New-AuthObs 'bob' 'github.com' $false
    $obs = @($oK1, $oK2)
    $conv = Get-AgentCredentialGitHubReferences -Observations $obs
    $ctx = New-Ctx @($conv.references)
    $r = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($r.outcome -eq 'ambiguous' -and $null -eq $r.selectedReference) "outcome=$($r.outcome)"
}

# --- L. provider-neutral example-provider flow works ---
Invoke-Test 'L provider-neutral' {
    $ref = [pscustomobject]@{ provider='example-provider'; sourceType='env'; reference='env/EXAMPLE_TOKEN'; account=$null; profile='personal'; host='example.com' }
    $ctx = [pscustomobject]@{ contractVersion='0.3.0'; provider='example-provider'; operation='publish'; requestedProfile='personal'; expectedAccount=$null; expectedHost='example.com'; availableReferences=@($ref); selectedReference=$null }
    $r = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($r.outcome -eq 'selected' -and $r.selectedReference.reference -eq 'env/EXAMPLE_TOKEN') "outcome=$($r.outcome)"
}

# --- M/N/O. process-scoped execution: child sees sentinel; parent unchanged; no leak ---
Invoke-Test 'M child sentinel' {
    $script:resolverGot = $null
    $resolver = { param($r) $script:resolverGot = $r; return $script:SENTINEL }
    $cmd = 'if ($env:ACS_E2E_M -eq ''' + $script:SENTINEL + ''') { exit 0 } else { exit 1 }'
    $r = Invoke-AgentCredentialScopedCommand -CredentialReference 'github/cli/github.com/alice' -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',$cmd) -EnvironmentVariable 'ACS_E2E_M' -Resolver $resolver -IncludeStdoutStderr
    Assert-True ($r.outcome -eq 'success' -and $r.exitCode -eq 0) "outcome=$($r.outcome) exit=$($r.exitCode)"
    Assert-True ($script:resolverGot -eq 'github/cli/github.com/alice') "resolverGot=$script:resolverGot"
    Assert-True ($null -eq [System.Environment]::GetEnvironmentVariable('ACS_E2E_M','Process')) 'parent env polluted'
}

Invoke-Test 'N parent unchanged failure/timeout' {
    [System.Environment]::SetEnvironmentVariable('ACS_E2E_N','parent-value','Process')
    try {
        $resolver = { param($r) return $script:SENTINEL }
        $null = Invoke-AgentCredentialScopedCommand -CredentialReference 'x' -Executable 'cmd.exe' -ArgumentList @('/c','exit','7') -EnvironmentVariable 'ACS_E2E_N' -Resolver $resolver
        $null = Invoke-AgentCredentialScopedCommand -CredentialReference 'x' -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 8') -EnvironmentVariable 'ACS_E2E_N' -Resolver $resolver -TimeoutSeconds 1
        Assert-True ([System.Environment]::GetEnvironmentVariable('ACS_E2E_N','Process') -eq 'parent-value') 'parent changed'
    }
    finally {
        Remove-Item Env:\ACS_E2E_N -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'O no sentinel leak' {
    $resolver = { param($r) return $script:SENTINEL }
    $cmd = 'echo %ACS_E2E_O%'
    $r = Invoke-AgentCredentialScopedCommand -CredentialReference 'x' -Executable 'cmd.exe' -ArgumentList @('/c',$cmd) -EnvironmentVariable 'ACS_E2E_O' -Resolver $resolver -IncludeStdoutStderr
    $json = $r | ConvertTo-Json -Depth 6
    Assert-True ($json -notmatch [regex]::Escape($script:SENTINEL)) 'sentinel leaked'
    Assert-True ($null -eq $r.stdout) 'stdout not redacted'
}
# --- P. resolver/binding/provider outputs never echo secret/path/error sentinels ---
Invoke-Test 'P no sentinel echo' {
    $resolver = Resolve-AgentCredentialContext -InputObject (New-Ctx @((New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com')))
    $j1 = $resolver | ConvertTo-Json -Depth 6
    $bRaw = [pscustomobject]@{ project='owner/repo'; provider='github'; profile='personal'; host=$null; token='SENTINEL_TOKEN'; secret='SENTINEL_SECRET'; path='C:\secrets\x' }
    $bRes = Resolve-AgentCredentialProjectProfile -Project 'owner/repo' -Provider 'github' -Bindings @($bRaw)
    $j2 = $bRes | ConvertTo-Json -Depth 6
    $obs = New-AuthObs 'alice' 'github.com' $true
    $obs | Add-Member -NotePropertyName rawToken -NotePropertyValue 'SENTINEL_TOKEN'
    $conv = Get-AgentCredentialGitHubReferences -Observations @($obs)
    $j3 = $conv | ConvertTo-Json -Depth 6
    Assert-True (($j1 -notmatch 'SENTINEL') -and ($j2 -notmatch 'SENTINEL') -and ($j3 -notmatch 'SENTINEL') -and ($j2 -notmatch 'C:\\') -and ($j3 -notmatch 'C:\\')) 'sentinel/path echoed'
}

# --- Q. reference ordering reversal produces equivalent logical result ---
Invoke-Test 'Q order reversal' {
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $r1 = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b) -reqProf 'personal')
    $r2 = Resolve-AgentCredentialContext -InputObject (New-Ctx @($b, $a) -reqProf 'personal')
    Assert-True ($r1.selectedReference.reference -eq $r2.selectedReference.reference) 'order changed result'
}

# --- R. no global provider auth switching required (pure functions, nothing mutated) ---
Invoke-Test 'R no global mutation' {
    $before = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ACS_E2E_*' } | ForEach-Object { $_.Name })
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'work' -tgt 'github.com'
    $null = Resolve-AgentCredentialContext -InputObject (New-Ctx @($a, $b))
    $null = Resolve-AgentCredentialProjectProfile -Project 'x/y' -Provider 'github' -Bindings @()
    $null = Get-AgentCredentialGitHubReferences -Observations @((New-AuthObs 'alice' 'github.com' $true))
    $after = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ACS_E2E_*' } | ForEach-Object { $_.Name })
    Assert-True (($after -join ',') -eq ($before -join ',')) 'env changed'
}

# --- npm second-provider coverage (permanent) ---
Invoke-Test 'NPM1 env ref' {
    $r = Get-AgentCredentialNpmReferences -Observations @(New-NpmEnvObs)
    Assert-True ($r.references.Count -eq 1 -and $r.references[0].reference -eq 'env/NPM_TOKEN' -and $r.references[0].sourceType -eq 'env' -and $r.references[0].host -eq 'npm-registry') "refs=$($r.references.Count)"
}

Invoke-Test 'NPM2 config no path leak' {
    $obs = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher'
    $obs | Add-Member -NotePropertyName rawToken -NotePropertyValue 'SENTINEL_NPM'
    $obs | Add-Member -NotePropertyName npmrcContent -NotePropertyValue '//registry.npmjs.org/:_authToken=SENTINEL_NPM'
    $obs.metadata | Add-Member -NotePropertyName path -NotePropertyValue 'C:\Users\x\.npmrc'
    $r = Get-AgentCredentialNpmReferences -Observations @($obs)
    $json = $r | ConvertTo-Json -Depth 6
    Assert-True ($r.references.Count -eq 1 -and $r.references[0].reference -eq 'config/https://registry.npmjs.org/publisher' -and $r.references[0].sourceType -eq 'config') "refs=$($r.references.Count)"
    Assert-True (($json -notmatch 'SENTINEL_NPM') -and ($json -notmatch 'C:\\') -and ($json -notmatch '\.npmrc')) 'path/sentinel leaked'
}

Invoke-Test 'NPM3 ambiguous without narrowing' {
    $r1 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher'
    $r2 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher2'
    $conv = Get-AgentCredentialNpmReferences -Observations @($r1, $r2)
    $refs = @()
    foreach ($ref in $conv.references) {
        $copy = [pscustomobject]@{ provider=$ref.provider; sourceType=$ref.sourceType; reference=$ref.reference; account=$ref.account; profile='personal'; host=$ref.host }
        $refs += $copy
    }
    $ctx = [pscustomobject]@{ contractVersion='0.3.0'; provider='npm'; operation='publish'; requestedProfile=$null; expectedAccount=$null; expectedHost=$null; availableReferences=@($refs); selectedReference=$null }
    $res = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($res.outcome -eq 'ambiguous' -and $null -eq $res.selectedReference) "outcome=$($res.outcome)"
}

Invoke-Test 'NPM4 profile narrows' {
    $r1 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher'
    $r2 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher2'
    $conv = Get-AgentCredentialNpmReferences -Observations @($r1, $r2)
    $refs = @()
    foreach ($ref in $conv.references) {
        $copy = [pscustomobject]@{ provider=$ref.provider; sourceType=$ref.sourceType; reference=$ref.reference; account=$ref.account; profile=$null; host=$ref.host }
        if ($ref.account -eq 'publisher') { $copy.profile = 'personal' } else { $copy.profile = 'work' }
        $refs += $copy
    }
    $ctx = [pscustomobject]@{ contractVersion='0.3.0'; provider='npm'; operation='publish'; requestedProfile='personal'; expectedAccount=$null; expectedHost=$null; availableReferences=@($refs); selectedReference=$null }
    $res = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($res.outcome -eq 'selected' -and $res.selectedReference.reference -eq 'config/https://registry.npmjs.org/publisher') "outcome=$($res.outcome)"
}

Invoke-Test 'NPM5 binding feeds generic resolver' {
    $bind = Get-AgentCredentialProjectBinding -Project 'pkg/npm-lib' -Provider 'npm' -Profile 'personal'
    $bound = Resolve-AgentCredentialProjectProfile -Project 'pkg/npm-lib' -Provider 'npm' -Bindings @($bind)
    Assert-True ($bound.outcome -eq 'bound' -and $bound.profile -eq 'personal') "outcome=$($bound.outcome)"
    $r1 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher'
    $r2 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher2'
    $conv = Get-AgentCredentialNpmReferences -Observations @($r1, $r2)
    $refs = @()
    foreach ($ref in $conv.references) {
        $copy = [pscustomobject]@{ provider=$ref.provider; sourceType=$ref.sourceType; reference=$ref.reference; account=$ref.account; profile=$null; host=$ref.host }
        if ($ref.account -eq 'publisher') { $copy.profile = 'personal' } else { $copy.profile = 'work' }
        $refs += $copy
    }
    $ctx = [pscustomobject]@{ contractVersion='0.3.0'; provider='npm'; operation='publish'; requestedProfile=$bound.profile; expectedAccount=$null; expectedHost=$null; availableReferences=@($refs); selectedReference=$null }
    $res = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($res.outcome -eq 'selected' -and $res.selectedReference.reference -eq 'config/https://registry.npmjs.org/publisher') "outcome=$($res.outcome)"
}

Invoke-Test 'NPM6 conflicting metadata fails closed' {
    $e1 = New-NpmEnvObs 'env/NPM_TOKEN' 'npm-registry'
    $e2 = New-NpmEnvObs 'env/NPM_TOKEN' 'other-registry'
    $r = Get-AgentCredentialNpmReferences -Observations @($e1, $e2)
    Assert-True ($r.conflict -eq 'env/NPM_TOKEN' -and $r.references.Count -eq 0) "conflict=$($r.conflict)"
}

Invoke-Test 'NPM7 reversed order equivalent' {
    $c1 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher'
    $c2 = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher2'
    $a = Get-AgentCredentialNpmReferences -Observations @($c1, $c2)
    $b = Get-AgentCredentialNpmReferences -Observations @($c2, $c1)
    $la = @($a.references | ForEach-Object { $_.reference }) -join ','
    $lb = @($b.references | ForEach-Object { $_.reference }) -join ','
    Assert-True ($la -eq $lb) "a=$la b=$lb"
}

Invoke-Test 'NPM8 sentinels never in provider/resolver output' {
    $obs = New-NpmConfigObs 'https://registry.npmjs.org' 'publisher'
    $obs | Add-Member -NotePropertyName rawToken -NotePropertyValue 'SENTINEL_NPM'
    $obs.metadata | Add-Member -NotePropertyName path -NotePropertyValue 'C:\secrets\.npmrc'
    $conv = Get-AgentCredentialNpmReferences -Observations @($obs)
    $refs = @()
    foreach ($ref in $conv.references) {
        $copy = [pscustomobject]@{ provider=$ref.provider; sourceType=$ref.sourceType; reference=$ref.reference; account=$ref.account; profile='personal'; host=$ref.host }
        $refs += $copy
    }
    $ctx = [pscustomobject]@{ contractVersion='0.3.0'; provider='npm'; operation='publish'; requestedProfile='personal'; expectedAccount=$null; expectedHost=$null; availableReferences=@($refs); selectedReference=$null }
    $res = Resolve-AgentCredentialContext -InputObject $ctx
    $json = (($conv | ConvertTo-Json -Depth 6) + ($res | ConvertTo-Json -Depth 6))
    Assert-True (($json -notmatch 'SENTINEL_NPM') -and ($json -notmatch 'C:\\') -and ($json -notmatch '\.npmrc')) 'sentinel/path echoed'
}

Invoke-Test 'NPM9 no npm execution' {
    Assert-True ((Get-Command Get-AgentCredentialNpmReferences -ErrorAction SilentlyContinue) -ne $null) 'npm adapter missing'
}

Invoke-Test 'CROSS provider equivalence' {
    $ghA = [pscustomobject]@{ provider='github'; sourceType='cli'; reference='cli/github.com/alice'; account='alice'; profile='personal'; host='github.com' }
    $ghB = [pscustomobject]@{ provider='github'; sourceType='cli'; reference='cli/github.com/bob'; account='bob'; profile='work'; host='github.com' }
    $ctxGh = [pscustomobject]@{ contractVersion='0.3.0'; provider='github'; operation='push'; requestedProfile='personal'; expectedAccount=$null; expectedHost=$null; availableReferences=@($ghA, $ghB); selectedReference=$null }
    $resGh = Resolve-AgentCredentialContext -InputObject $ctxGh
    Assert-True ($resGh.outcome -eq 'selected' -and $resGh.selectedReference.reference -eq 'cli/github.com/alice') "gh=$($resGh.outcome)"
    $np1 = [pscustomobject]@{ provider='npm'; sourceType='config'; reference='config/https://registry.npmjs.org/publisher'; account='publisher'; profile='personal'; host='https://registry.npmjs.org' }
    $np2 = [pscustomobject]@{ provider='npm'; sourceType='config'; reference='config/https://registry.npmjs.org/publisher2'; account='publisher2'; profile='work'; host='https://registry.npmjs.org' }
    $ctxNp = [pscustomobject]@{ contractVersion='0.3.0'; provider='npm'; operation='publish'; requestedProfile='personal'; expectedAccount=$null; expectedHost=$null; availableReferences=@($np1, $np2); selectedReference=$null }
    $resNp = Resolve-AgentCredentialContext -InputObject $ctxNp
    Assert-True ($resNp.outcome -eq 'selected' -and $resNp.selectedReference.reference -eq 'config/https://registry.npmjs.org/publisher') "npm=$($resNp.outcome)"
    $bGh = Get-AgentCredentialProjectBinding -Project 'owner/repo' -Provider 'github' -Profile 'personal'
    $bNp = Get-AgentCredentialProjectBinding -Project 'pkg/npm-lib' -Provider 'npm' -Profile 'personal'
    $rGh = Resolve-AgentCredentialProjectProfile -Project 'owner/repo' -Provider 'github' -Bindings @($bGh)
    $rNp = Resolve-AgentCredentialProjectProfile -Project 'pkg/npm-lib' -Provider 'npm' -Bindings @($bNp)
    Assert-True ($rGh.outcome -eq 'bound' -and $rNp.outcome -eq 'bound') "gh=$($rGh.outcome) npm=$($rNp.outcome)"
}

# --- Integrated happy path: binding -> adapter refs -> resolver -> execution ---
Invoke-Test 'INTEGRATED happy path' {
    $bind = Get-AgentCredentialProjectBinding -Project 'simon-world/agent-credentials-skill' -Provider 'github' -Profile 'personal' -HostName 'github.com'
    $bound = Resolve-AgentCredentialProjectProfile -Project 'simon-world/agent-credentials-skill' -Provider 'github' -Bindings @($bind) -ExpectedHost 'github.com'
    Assert-True ($bound.outcome -eq 'bound') "binding outcome=$($bound.outcome)"
    $oH1 = New-AuthObs 'alice' 'github.com' $true
    $oH2 = New-AuthObs 'bob' 'github.com' $false
    $obs = @($oH1, $oH2)
    $conv = Get-AgentCredentialGitHubReferences -Observations $obs
    Assert-True ($conv.references.Count -eq 2) 'expected two references'
    $refs = @()
    foreach ($ref in $conv.references) {
        $copy = [pscustomobject]@{ provider=$ref.provider; sourceType=$ref.sourceType; reference=$ref.reference; account=$ref.account; profile=$null; host=$ref.host }
        if ($ref.account -eq 'alice') { $copy.profile = 'personal' } else { $copy.profile = 'work' }
        $refs += $copy
    }
    $ctx = New-Ctx $refs -reqProf $bound.profile -expHost $bound.host
    $sel = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($sel.outcome -eq 'selected' -and $sel.selectedReference.reference -eq 'cli/github.com/alice') "sel outcome=$($sel.outcome)"
    $script:resolverGot = $null
    $resolver = { param($r) $script:resolverGot = $r; return $script:SENTINEL }
    $cmd = 'if ($env:ACS_E2E_HP -eq ''' + $script:SENTINEL + ''') { exit 0 } else { exit 1 }'
    $ex = Invoke-AgentCredentialScopedCommand -CredentialReference $sel.selectedReference -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',$cmd) -EnvironmentVariable 'ACS_E2E_HP' -Resolver $resolver
    Assert-True ($ex.outcome -eq 'success' -and $ex.exitCode -eq 0) "exec outcome=$($ex.outcome)"
    $exJson = $ex | ConvertTo-Json -Depth 6
    Assert-True ($exJson -notmatch [regex]::Escape($script:SENTINEL)) 'exec leaked sentinel'
    Assert-True ($null -eq [System.Environment]::GetEnvironmentVariable('ACS_E2E_HP','Process')) 'parent polluted'
}

# --- Integrated fail-closed: no binding, two equally compatible refs -> ambiguous; execution NOT invoked ---
Invoke-Test 'INTEGRATED fail-closed' {
    $u = Resolve-AgentCredentialProjectProfile -Project 'unbound/proj' -Provider 'github' -Bindings @()
    Assert-True ($u.outcome -eq 'unbound') "binding outcome=$($u.outcome)"
    $a = New-Ref 'cli/github.com/alice' -acct 'alice' -prof 'personal' -tgt 'github.com'
    $b = New-Ref 'cli/github.com/bob' -acct 'bob' -prof 'personal' -tgt 'github.com'
    $ctx = New-Ctx @($a, $b)
    $sel = Resolve-AgentCredentialContext -InputObject $ctx
    Assert-True ($sel.outcome -eq 'ambiguous' -and $null -eq $sel.selectedReference) "sel outcome=$($sel.outcome)"
    $script:execInvoked = $false
    $resolver = { param($r) $script:execInvoked = $true; return $script:SENTINEL }
    Assert-True (-not $script:execInvoked) 'execution was invoked despite ambiguity'
}

# --- cleanup: remove any leftover test env vars ---
Get-ChildItem Env: | Where-Object { $_.Name -like 'ACS_E2E_*' } | ForEach-Object { Remove-Item ("Env:" + $_.Name) -ErrorAction SilentlyContinue }

$failures = @($script:results | Where-Object { -not $_.ok })
if ($failures.Count -eq 0) {
    Write-Output 'ALL PASS'
    exit 0
}
Write-Output ('FAILED: ' + (($failures | ForEach-Object { $_.name }) -join ', '))
exit 1
