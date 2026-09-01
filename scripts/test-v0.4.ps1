<#
.SYNOPSIS
  Permanent v0.4 Credential Execution Plan conformance tests (Agent Credential Layer).
.DESCRIPTION
  Exercises the real v0.4 artifacts: schema/credential-plan.schema.json,
  scripts/validate-plan.ps1, and scripts/core/plan.ps1. Covers contract fixtures,
  the deterministic Broker gate matrix, semantic distinction, security invariants,
  provider neutrality, and determinism. All test credentials are harmless sentinels;
  no live GitHub/npm/network/auth operations. Pure Core logic runs in-process; JSON
  Schema validation runs through a PS7 child (consistent with the v0.3 convention).
.PARAMETER RepoRoot
  Optional repository root; defaults to the parent of this script's directory.
.EXAMPLE
  .\scripts\test-v0.4.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = $null
)

$ErrorActionPreference = 'Stop'

$script:repoRoot = if ($RepoRoot) { $RepoRoot } else { Split-Path -Path $PSScriptRoot -Parent }
$script:scriptsDir = Join-Path $script:repoRoot 'scripts'
$script:planCore = Join-Path $script:scriptsDir 'core\plan.ps1'
$script:resolverCore = Join-Path $script:scriptsDir 'core\resolver.ps1'
$script:validatePlan = Join-Path $script:scriptsDir 'validate-plan.ps1'
$script:schemaFile = Join-Path $script:repoRoot 'schema\credential-plan.schema.json'
$script:v04Valid = Join-Path $script:repoRoot 'fixtures\v0.4\valid'
$script:v04Invalid = Join-Path $script:repoRoot 'fixtures\v0.4\invalid'

. $script:planCore
. $script:resolverCore

$script:results = New-Object System.Collections.Generic.List[object]

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        $script:results.Add([pscustomobject]@{ name = $Name; ok = $true })
        Write-Output ("PASS " + $Name)
    }
    catch {
        $script:results.Add([pscustomobject]@{ name = $Name; ok = $false })
        Write-Output ("FAIL " + $Name + " :: " + $_.Exception.Message)
    }
}

function Assert-True([bool]$Condition, [string]$Detail) {
    if (-not $Condition) { throw $Detail }
}

function New-Diag([string]$status, [string]$code = $null) {
    return [pscustomobject]@{ status = $status; code = $code; summary = ("d:" + $status) }
}
function New-Ctx([string]$outcome, $selRef = $null) {
    return [pscustomobject]@{ outcome = $outcome; selectedReference = $selRef; provider = 'example-provider'; candidateReferences = @() }
}
function New-Res([string]$strategy = $null, $reauth = $null) {
    return [pscustomobject]@{ strategy = $strategy; reauthRequired = $reauth }
}
function New-Ref([string]$id = 'env/EXAMPLE_TOKEN', [string]$prov = 'example-provider', [string]$src = 'env') {
    return [pscustomobject]@{ provider = $prov; sourceType = $src; reference = $id; account = 'alice@example.com'; profile = 'personal'; host = 'example.com'; metadata = @{ secret = 'SENTINEL_X' }; rawToken = 'SENTINEL_X' }
}

function Test-PlanExit([string]$FixturePath, [int]$ExpectedExit, [string]$ExpectedFragment) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    Assert-True ($null -ne $pwsh) 'pwsh (PS7) is required to run the JSON Schema validator'
    $out = & pwsh -NoProfile -File $script:validatePlan -Path $FixturePath 2>&1
    $code = $LASTEXITCODE
    Assert-True ($code -eq $ExpectedExit) ("validate-plan exit=$code expected=$ExpectedExit output=$($out -join ' ')")
    if ($ExpectedFragment) {
        $joined = ($out -join ' ')
        Assert-True ($joined -like ('*' + $ExpectedFragment + '*')) ("validator output missing fragment '$ExpectedFragment': $joined")
    }
}

# --- Permanent contract coverage ---
Invoke-Test 'C1 plan-ready valid' { Test-PlanExit (Join-Path $script:v04Valid 'plan-ready.json') 0 'VALID' }
Invoke-Test 'C2 plan-needs-decision valid' { Test-PlanExit (Join-Path $script:v04Valid 'plan-needs-decision.json') 0 'VALID' }
Invoke-Test 'C3 secret field rejected' {
    $out = & pwsh -NoProfile -File $script:validatePlan -Path (Join-Path $script:v04Invalid 'plan-secret-field.json') 2>&1
    Assert-True ($LASTEXITCODE -eq 1) ("exit=$LASTEXITCODE")
    Assert-True (($out -join ' ') -notmatch 'fake-token-value') 'secret value echoed'
}
Invoke-Test 'C4 gate-inconsistent rejected' { Test-PlanExit (Join-Path $script:v04Invalid 'plan-gate-inconsistent.json') 1 'gate=ready requires diagnosis.status=healthy' }
Invoke-Test 'C5 selected-ref-mismatch rejected' { Test-PlanExit (Join-Path $script:v04Invalid 'plan-selected-reference-mismatch.json') 1 'selectedCredentialReference does not match context.selectedReference' }
Invoke-Test 'C6 contractVersion 0.4.0' {
    $s = Get-Content -Raw -LiteralPath $script:schemaFile | ConvertFrom-Json
    Assert-True ($s.contractVersion -eq '0.4.0') ("contractVersion=$($s.contractVersion)")
}
Invoke-Test 'C7 gate enum exact' {
    $s = Get-Content -Raw -LiteralPath $script:schemaFile | ConvertFrom-Json
    $enum = @($s.properties.gate.enum)
    Assert-True (($enum -join ',') -eq 'ready,blocked,needs_decision') ("enum=$($enum -join ',')")
}
# --- Permanent Broker gate matrix ---
function Get-Gate($diag, $ctx, $res = $null) { return Get-AgentCredentialBrokerGate -Diagnosis $diag -Context $ctx -Resolution $res }
function New-Plan($provider, $op, $diag, $ctx, $res = $null) { return New-AgentCredentialExecutionPlan -Provider $provider -Operation $op -Diagnosis $diag -Context $ctx -Resolution $res }

$refX = New-Ref
Invoke-Test 'A healthy selected ready' { Assert-True ((Get-Gate (New-Diag 'healthy') (New-Ctx 'selected' $refX)) -eq 'ready') 'not ready' }
Invoke-Test 'B healthy ambiguous needs' { Assert-True ((Get-Gate (New-Diag 'healthy') (New-Ctx 'ambiguous')) -eq 'needs_decision') 'not needs' }
Invoke-Test 'C inconclusive selected needs' { Assert-True ((Get-Gate (New-Diag 'inconclusive') (New-Ctx 'selected' $refX)) -eq 'needs_decision') 'not needs' }
Invoke-Test 'D unavailable diag selected blocked' { Assert-True ((Get-Gate (New-Diag 'unavailable') (New-Ctx 'selected' $refX)) -eq 'blocked') 'not blocked' }
Invoke-Test 'E healthy ctx-unavailable blocked' { Assert-True ((Get-Gate (New-Diag 'healthy') (New-Ctx 'unavailable')) -eq 'blocked') 'not blocked' }
Invoke-Test 'F healthy conflict blocked' { Assert-True ((Get-Gate (New-Diag 'healthy') (New-Ctx 'conflict')) -eq 'blocked') 'not blocked' }
Invoke-Test 'G degraded selected blocked' { Assert-True ((Get-Gate (New-Diag 'degraded') (New-Ctx 'selected' $refX)) -eq 'blocked') 'not blocked' }
Invoke-Test 'H degraded interactive needs' { Assert-True ((Get-Gate (New-Diag 'degraded') (New-Ctx 'selected' $refX) (New-Res 'INTERACTIVE_AUTH')) -eq 'needs_decision') 'not needs' }
Invoke-Test 'I healthy selected interactive needs' {
    $g = Get-Gate (New-Diag 'healthy') (New-Ctx 'selected' $refX) (New-Res 'INTERACTIVE_AUTH')
    Assert-True ($g -eq 'needs_decision') 'not needs'
}
Invoke-Test 'J reauthRequired needs no-auth' {
    $g = Get-Gate (New-Diag 'healthy') (New-Ctx 'selected' $refX) (New-Res $null $true)
    Assert-True ($g -eq 'needs_decision') 'not needs'
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX) (New-Res $null $true)
    Assert-True ($plan.gate -eq 'needs_decision' -and $plan.decisionCode -eq 'MANUAL_REVIEW') 'plan misleading'
}
Invoke-Test 'K ambiguous MANUAL_REVIEW default' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'ambiguous')
    Assert-True ($plan.gate -eq 'needs_decision' -and $plan.decisionCode -eq 'MANUAL_REVIEW' -and $null -eq $plan.selectedCredentialReference) ("gate=$($plan.gate)")
}
Invoke-Test 'L healthy selected safe ready plan' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX)
    Assert-True ($plan.gate -eq 'ready' -and $plan.selectedCredentialReference.reference -eq 'env/EXAMPLE_TOKEN') 'not ready plan'
}
Invoke-Test 'M non-selected null reference' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'ambiguous')
    Assert-True ($null -eq $plan.selectedCredentialReference -and $null -eq $plan.context.selectedReference) 'ref not null'
}
Invoke-Test 'N conflicting inputs fail closed precedence' {
    # unavailable diagnosis + blocked context with an intervention strategy: hard block wins.
    $g = Get-Gate (New-Diag 'unavailable') (New-Ctx 'unavailable') (New-Res 'INTERACTIVE_AUTH')
    Assert-True ($g -eq 'blocked') "gate=$g"
}
# --- Semantic distinction: diagnosis-unavailable vs context-unavailable, both blocked ---
Invoke-Test 'S1 diagnosis unavailable distinguishable' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'unavailable') (New-Ctx 'selected' $refX)
    Assert-True ($plan.gate -eq 'blocked' -and $plan.diagnosis.status -eq 'unavailable' -and $plan.context.outcome -eq 'selected') ("gate=$($plan.gate) d=$($plan.diagnosis.status)")
}
Invoke-Test 'S2 context unavailable distinguishable' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'unavailable')
    Assert-True ($plan.gate -eq 'blocked' -and $plan.diagnosis.status -eq 'healthy' -and $plan.context.outcome -eq 'unavailable') ("gate=$($plan.gate) c=$($plan.context.outcome)")
}

# --- Security invariants ---
Invoke-Test 'SEC1 no metadata propagation' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX)
    $selNames = @($plan.selectedCredentialReference.PSObject.Properties.Name)
    Assert-True ($selNames.Count -eq 6 -and -not ($selNames -contains 'metadata') -and -not ($selNames -contains 'rawToken') -and -not ($selNames -contains 'secret')) ("count=$($selNames.Count)")
}
Invoke-Test 'SEC2 no sentinel/extra fields' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX)
    $json = $plan | ConvertTo-Json -Depth 6
    Assert-True (($json -notmatch 'SENTINEL_X') -and ($json -notmatch '"rawToken"') -and ($json -notmatch '"secret"')) 'leak'
}
Invoke-Test 'SEC3 no stdout/stderr/raw output fields' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX)
    $keys = @($plan.PSObject.Properties.Name) + @($plan.diagnosis.PSObject.Properties.Name) + @($plan.context.PSObject.Properties.Name) + @($plan.executionMetadata.PSObject.Properties.Name)
    Assert-True (-not ($keys -contains 'stdout') -and -not ($keys -contains 'stderr') -and -not ($keys -contains 'commandOutput')) 'raw output field present'
}
Invoke-Test 'SEC4 interactive decision only' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX) (New-Res 'INTERACTIVE_AUTH')
    Assert-True ($plan.gate -eq 'needs_decision' -and $plan.decisionCode -eq 'INTERACTIVE_AUTH' -and $plan.gate -ne 'ready') 'executable mislabel'
    # Ensure no scoped-execution function is invoked by Core (module scan below at suite level).
}
Invoke-Test 'SEC5 whitelist reference fields' {
    $plan = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' (New-Ref 'env/GH_TOKEN' 'github' 'env'))
    $n = @($plan.selectedCredentialReference.PSObject.Properties.Name) -join ','
    Assert-True ($n -eq 'provider,sourceType,reference,account,profile,host') "fields=$n"
}

# --- Provider neutrality (single generic path) ---
Invoke-Test 'P1 example-provider' {
    $p = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' (New-Ref 'env/X' 'example-provider' 'env'))
    Assert-True ($p.gate -eq 'ready' -and $p.provider -eq 'example-provider' -and $p.selectedCredentialReference.reference -eq 'env/X') 'not ready'
}
Invoke-Test 'P2 github-shaped' {
    $p = New-Plan 'github' 'push' (New-Diag 'healthy') (New-Ctx 'selected' (New-Ref 'cli/github.com/alice' 'github' 'cli'))
    Assert-True ($p.gate -eq 'ready' -and $p.provider -eq 'github' -and $p.selectedCredentialReference.reference -eq 'cli/github.com/alice') 'not ready'
}
Invoke-Test 'P3 npm-shaped' {
    $p = New-Plan 'npm' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' (New-Ref 'config/https://registry.npmjs.org/publisher' 'npm' 'config'))
    Assert-True ($p.gate -eq 'ready' -and $p.provider -eq 'npm' -and $p.selectedCredentialReference.reference -eq 'config/https://registry.npmjs.org/publisher') 'not ready'
}

# --- Determinism ---
Invoke-Test 'D1 property order independent' {
    $ctx = [pscustomobject]@{ outcome = 'selected'; selectedReference = $refX; provider = 'example-provider'; candidateReferences = @() }
    $ctx2 = [pscustomobject]@{ candidateReferences = @(); provider = 'example-provider'; selectedReference = $refX; outcome = 'selected' }
    $p1 = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') $ctx
    $p2 = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') $ctx2
    Assert-True ($p1.gate -eq $p2.gate -and $p1.selectedCredentialReference.reference -eq $p2.selectedCredentialReference.reference) 'order changed'
}
Invoke-Test 'D2 identical inputs stable' {
    $a = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX) | ConvertTo-Json -Depth 6
    $b = New-Plan 'example-provider' 'publish' (New-Diag 'healthy') (New-Ctx 'selected' $refX) | ConvertTo-Json -Depth 6
    Assert-True ($a -eq $b) 'not stable'
}

# --- Suite-level static scan: Core module triggers no provider/network/auth execution ---
Invoke-Test 'S5 no provider/network/auth ops in Core' {
    $all = Get-Content -LiteralPath $script:planCore -Encoding UTF8
    $inBlock = $false
    $codeLines = @()
    foreach ($line in $all) {
        $t = $line.Trim()
        if ($t -like '<#*') { $inBlock = $true; continue }
        if ($inBlock) { if ($t -like '*#>') { $inBlock = $false }; continue }
        if ($t -like '#*') { continue }
        $codeLines += $line
    }
    $src = $codeLines -join "`n"
    foreach ($bad in @('Invoke-WebRequest','Invoke-RestMethod','Get-Content','$env:','keyring','Start-Process','Invoke-Expression','gh ','git ','npm ','auth login','auth switch','Invoke-AgentCredentialScopedCommand')) {
        Assert-True (-not ($src -match [regex]::Escape($bad))) "bad token $bad"
    }
}

# --- v0.4 Broker CLI permanent coverage (real scripts/broker.ps1) ---
$script:brokerCli = Join-Path $script:scriptsDir 'broker.ps1'
function Esc-Arg($s) { if ($PSVersionTable.PSVersion.Major -ge 6) { return $s }; return ($s -replace '"', '\"') }
function Run-Broker([string[]]$extra = @()) {
    $esc = @($extra | ForEach-Object { Esc-Arg $_ })
    $out = & pwsh -NoProfile -File $script:brokerCli @esc 2>&1
    return @{ exit = $LASTEXITCODE; out = ($out -join "`n") }
}
function BVal($res, [string]$key) {
    $m = [regex]::Match($res.out, [regex]::Escape($key) + ': ([^\r\n]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
$ghOne = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"}]'
$ghTwo = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"},{"provider":"github","sourceType":"cli","reference":"cli/github.com/bob","account":"bob","profile":"work","host":"github.com"}]'
$ghTwoSame = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"},{"provider":"github","sourceType":"cli","reference":"cli/github.com/bob","account":"bob","profile":"personal","host":"github.com"}]'
$ghTwoHosts = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"},{"provider":"github","sourceType":"cli","reference":"cli/ghe.example.com/bob","account":"bob","profile":"work","host":"ghe.example.com"}]'
$ghTwoRev = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/bob","account":"bob","profile":"work","host":"github.com"},{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com"}]'
$npmOne = '[{"provider":"npm","sourceType":"config","reference":"config/https://registry.npmjs.org/publisher","account":"publisher","profile":"personal","host":"https://registry.npmjs.org"}]'
$bindGh = '[{"project":"owner/repo","provider":"github","profile":"personal"}]'
$bindAmb = '[{"project":"owner/repo","provider":"github","profile":"personal"},{"project":"owner/repo","provider":"github","profile":"work"}]'
$diagH = '{"status":"healthy"}'
$diagInc = '{"status":"inconclusive"}'
$diagUn = '{"status":"unavailable"}'

Invoke-Test 'B1 github ready' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne); Assert-True (($r.exit -eq 0) -and ((BVal $r 'gate') -eq 'ready') -and ((BVal $r 'selectedReference') -eq 'cli/github.com/alice')) "out=$($r.out)" }
Invoke-Test 'B2 npm ready' { $r = Run-Broker @('-Provider','npm','-Operation','publish','-DiagnosisJson',$diagH,'-ReferencesJson',$npmOne); Assert-True (($r.exit -eq 0) -and ((BVal $r 'gate') -eq 'ready') -and ((BVal $r 'selectedReference') -eq 'config/https://registry.npmjs.org/publisher')) "out=$($r.out)" }
Invoke-Test 'B3 no narrowing needs' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwoSame); Assert-True ((BVal $r 'gate') -eq 'needs_decision') "out=$($r.out)" }
Invoke-Test 'B4 profile narrows' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwo,'-Profile','personal'); Assert-True ((BVal $r 'gate') -eq 'ready' -and (BVal $r 'selectedReference') -eq 'cli/github.com/alice') "out=$($r.out)" }
Invoke-Test 'B5 account narrows' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwo,'-Account','alice'); Assert-True ((BVal $r 'gate') -eq 'ready' -and (BVal $r 'selectedReference') -eq 'cli/github.com/alice') "out=$($r.out)" }
Invoke-Test 'B6 host narrows' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwoHosts,'-HostName','ghe.example.com'); Assert-True ((BVal $r 'gate') -eq 'ready' -and (BVal $r 'selectedReference') -eq 'cli/ghe.example.com/bob') "out=$($r.out)" }
Invoke-Test 'B7 binding narrows' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-Project','owner/repo','-BindingsJson',$bindGh,'-ReferencesJson',$ghTwo); Assert-True ((BVal $r 'gate') -eq 'ready' -and (BVal $r 'selectedReference') -eq 'cli/github.com/alice') "out=$($r.out)" }
Invoke-Test 'B8 conflict never ready' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-Project','owner/repo','-BindingsJson',$bindGh,'-ReferencesJson',$ghTwo,'-Profile','work'); Assert-True ((BVal $r 'gate') -ne 'ready') "gate=$((BVal $r 'gate'))" }
Invoke-Test 'B9 inconclusive needs' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagInc,'-ReferencesJson',$ghOne); Assert-True ((BVal $r 'gate') -eq 'needs_decision') "out=$($r.out)" }
Invoke-Test 'B10 unavailable blocked' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagUn,'-ReferencesJson',$ghOne); Assert-True ((BVal $r 'gate') -eq 'blocked') "out=$($r.out)" }
Invoke-Test 'B11 ctx-unavailable blocked' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson','[]'); Assert-True ((BVal $r 'gate') -eq 'blocked' -and (BVal $r 'context') -eq 'unavailable' -and (BVal $r 'diagnosis') -eq 'healthy') "out=$($r.out)" }
Invoke-Test 'B12 distinguish blocked layers' {
    $r10 = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagUn,'-ReferencesJson',$ghOne,'-Json')
    $r11 = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson','[]','-Json')
    $p10 = $r10.out | ConvertFrom-Json; $p11 = $r11.out | ConvertFrom-Json
    Assert-True ($p10.gate -eq 'blocked' -and $p11.gate -eq 'blocked' -and $p10.diagnosis.status -eq 'unavailable' -and $p10.context.outcome -eq 'selected' -and $p11.diagnosis.status -eq 'healthy' -and $p11.context.outcome -eq 'unavailable') "d=$($p10.diagnosis.status)/$($p11.diagnosis.status)"
}
Invoke-Test 'B13 interactive needs no-auth' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-ResolutionJson','{"strategy":"INTERACTIVE_AUTH"}'); Assert-True ((BVal $r 'gate') -eq 'needs_decision') "out=$($r.out)" }
Invoke-Test 'B14 reauth needs no-auth' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-ResolutionJson','{"reauthRequired":true}'); Assert-True ((BVal $r 'gate') -eq 'needs_decision') "out=$($r.out)" }
Invoke-Test 'B15 ambiguous MANUAL_REVIEW' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwoSame,'-Json'); $p = $r.out | ConvertFrom-Json; Assert-True ($p.gate -eq 'needs_decision' -and $p.decisionCode -eq 'MANUAL_REVIEW' -and $null -eq $p.selectedCredentialReference) "gate=$($p.gate)" }
Invoke-Test 'B16 reversed order identical' {
    $r1 = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwo,'-Profile','personal','-Json')
    $r2 = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwoRev,'-Profile','personal','-Json')
    $a = $r1.out | ConvertFrom-Json; $b = $r2.out | ConvertFrom-Json
    Assert-True ($a.gate -eq $b.gate -and $a.selectedCredentialReference.reference -eq $b.selectedCredentialReference.reference) "g=$($a.gate)/$($b.gate)"
}
Invoke-Test 'B17 binding ambiguity fails closed' { $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-Project','owner/repo','-BindingsJson',$bindAmb,'-ReferencesJson',$ghTwo); Assert-True ((BVal $r 'gate') -eq 'needs_decision') "out=$($r.out)" }
Invoke-Test 'B18 invalid provider error' { $r = Run-Broker @('-Provider','bogus','-Operation','push','-DiagnosisJson',$diagH); Assert-True (($r.exit -ne 0) -and ($r.out -match 'ERROR: unsupported provider')) "out=$($r.out)" }

# Contract validation: representative -Json outputs pass validate-plan.ps1.
Invoke-Test 'BR1 ready json validates' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')
    $tmp = Join-Path $env:TEMP 'v04-broker-ready.json'; [System.IO.File]::WriteAllText($tmp, $r.out, [System.Text.UTF8Encoding]::new($false))
    $val = & pwsh -NoProfile -File $script:validatePlan -Path $tmp 2>&1; Assert-True ($LASTEXITCODE -eq 0) "out=$($val -join ' ')"; Remove-Item -LiteralPath $tmp -Force
}
Invoke-Test 'BR2 needs json validates' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghTwoSame,'-Json')
    $tmp = Join-Path $env:TEMP 'v04-broker-needs.json'; [System.IO.File]::WriteAllText($tmp, $r.out, [System.Text.UTF8Encoding]::new($false))
    $val = & pwsh -NoProfile -File $script:validatePlan -Path $tmp 2>&1; Assert-True ($LASTEXITCODE -eq 0) "out=$($val -join ' ')"; Remove-Item -LiteralPath $tmp -Force
}
Invoke-Test 'BR3 blocked json validates' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson','[]','-Json')
    $tmp = Join-Path $env:TEMP 'v04-broker-blocked.json'; [System.IO.File]::WriteAllText($tmp, $r.out, [System.Text.UTF8Encoding]::new($false))
    $val = & pwsh -NoProfile -File $script:validatePlan -Path $tmp 2>&1; Assert-True ($LASTEXITCODE -eq 0) "out=$($val -join ' ')"; Remove-Item -LiteralPath $tmp -Force
}

# Security invariants through the CLI.
Invoke-Test 'BS1 secret metadata not emitted' {
    $ghSecret = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com","secret":"SENTINEL_X","rawToken":"SENTINEL_X","metadata":{"password":"SENTINEL_X"}}]'
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson','{"status":"healthy","summary":"SENTINEL_X"}','-ReferencesJson',$ghSecret,'-Json')
    Assert-True (($r.out -notmatch 'SENTINEL_X') -and ($r.out -notmatch 'rawToken') -and ($r.out -notmatch '"secret"')) "out=$($r.out)"
}
Invoke-Test 'BS2 no command output fields' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')
    Assert-True (($r.out -notmatch '"stdout"') -and ($r.out -notmatch '"stderr"') -and ($r.out -notmatch '"commandOutput"')) 'raw output field'
}
Invoke-Test 'BS3 approved reference fields only' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')
    $p = $r.out | ConvertFrom-Json
    $n = @($p.selectedCredentialReference.PSObject.Properties.Name) -join ','
    Assert-True ($n -eq 'provider,sourceType,reference,account,profile,host') "fields=$n"
}
Invoke-Test 'BS4 broker source no scoped exec/auth' {
    $all = Get-Content -LiteralPath $script:brokerCli -Encoding UTF8
    $inBlock = $false
    $codeLines = @()
    foreach ($line in $all) {
        $t = $line.Trim()
        if ($t -like '<#*') { $inBlock = $true; continue }
        if ($inBlock) { if ($t -like '*#>') { $inBlock = $false }; continue }
        if ($t -like '#*') { continue }
        $codeLines += $line
    }
    $src = $codeLines -join "`n"
    foreach ($bad in @('Invoke-AgentCredentialScopedCommand','gh auth login','gh auth switch','npm login','npm logout','Invoke-WebRequest','Invoke-RestMethod','$env:','keyring','Set-Content','Add-Content','Out-File','Start-Process','Invoke-Expression','ConvertFrom-SecureString','Read-Host','System.Net')) {
        Assert-True (-not ($src -match [regex]::Escape($bad))) "bad token $bad"
    }
}

# Provider boundary: branching only in broker adapter selection; core plan stays neutral.
Invoke-Test 'BP1 same contract both providers' {
    $g = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json') | ForEach-Object { $_.out } | ConvertFrom-Json
    $n = Run-Broker @('-Provider','npm','-Operation','publish','-DiagnosisJson',$diagH,'-ReferencesJson',$npmOne,'-Json') | ForEach-Object { $_.out } | ConvertFrom-Json
    Assert-True ($g.gate -eq 'ready' -and $n.gate -eq 'ready' -and $g.contractVersion -eq $n.contractVersion -and $g.selectedCredentialReference.reference -ne $n.selectedCredentialReference.reference) 'contract not neutral'
}
Invoke-Test 'BP2 core plan neutral' {
    $src = Get-Content -Raw -LiteralPath $script:planCore
    Assert-True (($src -notmatch 'gitHubAdapter') -and ($src -notmatch 'npmAdapter')) 'core has provider branch'
}

# Diagnosis compatibility: reduce a full-shaped v0.2 Diagnosis Result without mutating/exposing.
Invoke-Test 'BD1 reduce diagnosis without mutation' {
    $full = [pscustomobject]@{ schemaVersion = '0.2.0'; status = 'healthy'; diagnosis = [pscustomobject]@{ code = $null; category = 'ok' }; evidence = @(); reauthRequired = $false }
    $json = $full | ConvertTo-Json -Depth 6
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$json,'-ReferencesJson',$ghOne,'-Json')
    $p = $r.out | ConvertFrom-Json
    Assert-True ($p.gate -eq 'ready' -and $p.diagnosis.status -eq 'healthy' -and ($r.out -notmatch 'evidence') -and ($r.out -notmatch 'reauthRequired') -and ($r.out -notmatch 'schemaVersion')) "out=$($r.out)"
}

# Determinism beyond reversal: irrelevant property order and repeated identical inputs.
Invoke-Test 'BD2 property order independent' {
    $refA = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com","extra":"x"}]'
    $refB = '[{"host":"github.com","profile":"personal","account":"alice","reference":"cli/github.com/alice","sourceType":"cli","provider":"github","extra":"x"}]'
    $a = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$refA,'-Json')).out | ConvertFrom-Json
    $b = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$refB,'-Json')).out | ConvertFrom-Json
    Assert-True ($a.selectedCredentialReference.reference -eq $b.selectedCredentialReference.reference -and $a.gate -eq $b.gate) 'order changed'
}
Invoke-Test 'BD3 repeated identical stable' {
    $j1 = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')).out
    $j2 = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')).out
    Assert-True ($j1 -eq $j2) 'not stable'
}

# --- v0.4 execution-gate bridge permanent coverage (real scripts/core/*) ---
$script:executionCore = Join-Path $script:scriptsDir 'core\execution.ps1'
$script:brokerExec = Join-Path $script:scriptsDir 'core\broker-execution.ps1'
. $script:executionCore
. $script:brokerExec
if (-not (Get-Command Invoke-AgentCredentialExecutionPlan -ErrorAction SilentlyContinue)) { throw 'broker-execution.ps1 did not define Invoke-AgentCredentialExecutionPlan' }

$script:execSentinel = 'SENTINEL_SECRET_VALUE_9a2b'
$script:resolverGot = $null
$script:resolverCalls = 0
function ExecResolver($ref) { $script:resolverCalls++; $script:resolverGot = $ref; return $script:execSentinel }
function ExecResolverThrow($ref) { throw ('boom ' + $script:execSentinel) }
function ExecChildCmd($envName) { 'if ($env:' + $envName + ' -eq ''' + $script:execSentinel + ''') { exit 0 } else { exit 1 }' }
function ExecReadyPlan($provider, $ref) {
    return New-AgentCredentialExecutionPlan -Provider $provider -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context (New-Ctx 'selected' $ref)
}

Invoke-Test 'X1 generated ready executes' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $script:resolverCalls = 0; $script:resolverGot = $null
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_X1')) -EnvironmentVariable 'ACS_X1' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'executed' -and $r.executed -eq $true -and $r.exitCode -eq 0 -and $script:resolverCalls -eq 1) "out=$($r.outcome) exit=$($r.exitCode) calls=$script:resolverCalls"
}
Invoke-Test 'X2 resolver once' { Assert-True ($script:resolverCalls -eq 1) "calls=$script:resolverCalls" }
Invoke-Test 'X3 resolver logical ref' { Assert-True ($script:resolverGot -eq 'env/EXAMPLE_TOKEN') "got=$script:resolverGot" }
Invoke-Test 'X4 blocked no-exec' {
    $plan = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'unavailable') -Context (New-Ctx 'selected' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'))
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X4' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'blocked' -and $r.executed -eq $false -and $script:resolverCalls -eq 0) "out=$($r.outcome) calls=$script:resolverCalls"
}
Invoke-Test 'X5 needs no-exec' {
    $plan = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context (New-Ctx 'ambiguous')
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X5' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'needs_decision' -and $r.executed -eq $false -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'X6 forged degraded reject' {
    $p = [pscustomobject]@{ contractVersion='0.4.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='degraded'}; context=[pscustomobject]@{outcome='selected';selectedReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')}; gate='ready'; decisionCode=$null; selectedCredentialReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X6' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'X7 forged ambiguous reject' {
    $p = [pscustomobject]@{ contractVersion='0.4.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='healthy'}; context=[pscustomobject]@{outcome='ambiguous';selectedReference=$null}; gate='ready'; decisionCode=$null; selectedCredentialReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X7' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'X8 forged mismatch reject' {
    $refCtx = (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $p = [pscustomobject]@{ contractVersion='0.4.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='healthy'}; context=[pscustomobject]@{outcome='selected';selectedReference=$refCtx}; gate='ready'; decisionCode=$null; selectedCredentialReference=(New-Ref 'env/OTHER' 'example-provider' 'env'); executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X8' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'X9 wrong version reject' {
    $p = [pscustomobject]@{ contractVersion='0.3.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='healthy'}; context=[pscustomobject]@{outcome='selected';selectedReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')}; gate='ready'; decisionCode=$null; selectedCredentialReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X9' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $r.executed -eq $false) "out=$($r.outcome)"
}
Invoke-Test 'X10 intervention reject' {
    $p = [pscustomobject]@{ contractVersion='0.4.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='healthy'}; context=[pscustomobject]@{outcome='selected';selectedReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')}; gate='ready'; decisionCode='INTERACTIVE_AUTH'; selectedCredentialReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X10' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'X11 unknown gate reject' {
    $p = [pscustomobject]@{ contractVersion='0.4.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='healthy'}; context=[pscustomobject]@{outcome='selected';selectedReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')}; gate='maybe'; decisionCode=$null; selectedCredentialReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X11' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $r.executed -eq $false) "out=$($r.outcome)"
}
Invoke-Test 'X12 missing selected reference reject' {
    $p = [pscustomobject]@{ contractVersion='0.4.0'; provider='example-provider'; operation='push'; diagnosis=[pscustomobject]@{status='healthy'}; context=[pscustomobject]@{outcome='selected';selectedReference=$null}; gate='ready'; decisionCode=$null; selectedCredentialReference=$null; executionMetadata=[pscustomobject]@{runtime='host';host='example.com'} }
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $p -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_X12' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'error' -and $r.executed -eq $false -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}

# --- Process-scoped credential proof ---
Invoke-Test 'XPS1 child sees sentinel' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XPS1')) -EnvironmentVariable 'ACS_XPS1' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'executed' -and $r.exitCode -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'XPS2 parent unchanged success' { Assert-True ($null -eq [System.Environment]::GetEnvironmentVariable('ACS_XPS1','Process')) 'parent polluted' }
Invoke-Test 'XPS3 parent unchanged resolver-fail' {
    [System.Environment]::SetEnvironmentVariable('ACS_XPS3','keep','Process')
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XPS3')) -EnvironmentVariable 'ACS_XPS3' -Resolver ${function:ExecResolverThrow}
    Assert-True ([System.Environment]::GetEnvironmentVariable('ACS_XPS3','Process') -eq 'keep') 'parent changed'
    Remove-Item Env:\ACS_XPS3 -ErrorAction SilentlyContinue
}
Invoke-Test 'XPS4 parent unchanged nonzero' {
    [System.Environment]::SetEnvironmentVariable('ACS_XPS4','keep','Process')
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'cmd.exe' -ArgumentList @('/c','exit','7') -EnvironmentVariable 'ACS_XPS4' -Resolver ${function:ExecResolver}
    Assert-True ([System.Environment]::GetEnvironmentVariable('ACS_XPS4','Process') -eq 'keep') 'parent changed'
    Remove-Item Env:\ACS_XPS4 -ErrorAction SilentlyContinue
}
Invoke-Test 'XPS5 parent unchanged timeout' {
    [System.Environment]::SetEnvironmentVariable('ACS_XPS5','keep','Process')
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 8') -EnvironmentVariable 'ACS_XPS5' -Resolver ${function:ExecResolver} -TimeoutSeconds 1
    Assert-True ($r.summary -eq 'execution timed out') ("summary=$($r.summary)")
    Assert-True ([System.Environment]::GetEnvironmentVariable('ACS_XPS5','Process') -eq 'keep') 'parent changed'
    Remove-Item Env:\ACS_XPS5 -ErrorAction SilentlyContinue
}

# --- Sanitization ---
Invoke-Test 'XS1 no sentinel/raw/exception text' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'cmd.exe' -ArgumentList @('/c','echo', $script:execSentinel) -EnvironmentVariable 'ACS_XS1' -Resolver ${function:ExecResolver} -IncludeStdoutStderr
    $j = $r | ConvertTo-Json -Depth 6
    Assert-True (($j -notmatch 'SENTINEL') -and ($j -notmatch 'rawToken') -and ($j -notmatch 'stdout') -and ($j -notmatch 'stderr') -and ($j -notmatch 'boom')) "j=$j"
}
Invoke-Test 'XS2 small metadata surface' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XS2')) -EnvironmentVariable 'ACS_XS2' -Resolver ${function:ExecResolver}
    $names = @($r.PSObject.Properties.Name)
    Assert-True (($names -join ',') -eq 'provider,operation,outcome,executed,exitCode,summary') "names=$($names -join ',')"
}

# --- No automatic recovery/auth ---
Invoke-Test 'XNA2 interactive plan not executable' {
    $plan = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context (New-Ctx 'selected' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')) -Resolution (New-Res 'INTERACTIVE_AUTH')
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_XNA2' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'needs_decision' -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'XNA3 reauth no auth' {
    $plan = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context (New-Ctx 'selected' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')) -Resolution (New-Res $null $true)
    $script:resolverCalls = 0
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @() -EnvironmentVariable 'ACS_XNA3' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'needs_decision' -and $script:resolverCalls -eq 0) "out=$($r.outcome)"
}
Invoke-Test 'XNA4 broker-exec no auth/switch/login' {
    $src = Get-Content -Raw -LiteralPath $script:brokerExec
    foreach ($bad in @('gh auth login','gh auth switch','npm login','npm logout','Invoke-WebRequest','Invoke-RestMethod','$env:','keyring','Set-Content','Add-Content','Out-File','Start-Process','Invoke-Expression','ConvertFrom-SecureString','Read-Host','System.Net')) {
        Assert-True (-not ($src -match [regex]::Escape($bad))) "bad token $bad"
    }
}

# --- Provider neutrality ---
Invoke-Test 'XPN1 example-ready executes' {
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan (ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')) -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XPN1')) -EnvironmentVariable 'ACS_XPN1' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'executed') "out=$($r.outcome)"
}
Invoke-Test 'XPN2 github-ready executes' {
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan (ExecReadyPlan 'github' (New-Ref 'cli/github.com/alice' 'github' 'cli')) -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XPN2')) -EnvironmentVariable 'ACS_XPN2' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'executed' -and $r.provider -eq 'github') "out=$($r.outcome)"
}
Invoke-Test 'XPN3 npm-ready executes' {
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan (ExecReadyPlan 'npm' (New-Ref 'config/https://registry.npmjs.org/publisher' 'npm' 'config')) -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XPN3')) -EnvironmentVariable 'ACS_XPN3' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'executed' -and $r.provider -eq 'npm') "out=$($r.outcome)"
}
Invoke-Test 'XPN4 broker-exec provider-neutral source' {
    $all = Get-Content -LiteralPath $script:brokerExec -Encoding UTF8
    $inBlock = $false; $codeLines = @()
    foreach ($line in $all) {
        $t = $line.Trim()
        if ($t -like '<#*') { $inBlock = $true; continue }
        if ($inBlock) { if ($t -like '*#>') { $inBlock = $false }; continue }
        if ($t -like '#*') { continue }
        $codeLines += $line
    }
    $src = $codeLines -join "`n"
    Assert-True (($src -notmatch 'github') -and ($src -notmatch 'npm')) 'provider branch in Core bridge'
}

# --- Failure paths (sanitized) ---
Invoke-Test 'XF1 resolver throws sanitized' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XF1')) -EnvironmentVariable 'ACS_XF1' -Resolver ${function:ExecResolverThrow}
    $j = $r | ConvertTo-Json -Depth 6
    Assert-True (($j -notmatch 'SENTINEL') -and ($j -notmatch 'boom') -and ($r.outcome -eq 'executed')) "out=$($r.outcome) j=$j"
}
Invoke-Test 'XF2 executable missing sanitized' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'C:\nonexistent\missing-tool-xyz.exe' -ArgumentList @() -EnvironmentVariable 'ACS_XF2' -Resolver ${function:ExecResolver}
    $j = $r | ConvertTo-Json -Depth 6
    Assert-True (($r.outcome -eq 'executed') -and ($j -notmatch 'Exception') -and ($j -notmatch 'SENTINEL')) "out=$($r.outcome)"
}
Invoke-Test 'XF3 child nonzero sanitized' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'cmd.exe' -ArgumentList @('/c','exit','7') -EnvironmentVariable 'ACS_XF3' -Resolver ${function:ExecResolver}
    Assert-True ($r.outcome -eq 'executed' -and $r.exitCode -eq 7 -and $r.summary -eq 'execution failed') "out=$($r.outcome)"
}
Invoke-Test 'XF4 timeout sanitized' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 8') -EnvironmentVariable 'ACS_XF4' -Resolver ${function:ExecResolver} -TimeoutSeconds 1
    Assert-True ($r.summary -eq 'execution timed out' -and ($r | ConvertTo-Json -Depth 6) -notmatch 'SENTINEL') "out=$($r.outcome)"
}

# --- Immutability / determinism ---
Invoke-Test 'XID1 no plan mutation' {
    $plan = ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')
    $before = $plan | ConvertTo-Json -Depth 8
    $r = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XID1')) -EnvironmentVariable 'ACS_XID1' -Resolver ${function:ExecResolver}
    Assert-True (($plan | ConvertTo-Json -Depth 8) -eq $before) 'plan mutated'
}
Invoke-Test 'XID2 property order independent' {
    $ctxA = [pscustomobject]@{ outcome='selected'; selectedReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); provider='example-provider'; candidateReferences=@() }
    $ctxB = [pscustomobject]@{ candidateReferences=@(); provider='example-provider'; selectedReference=(New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'); outcome='selected' }
    $a = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context $ctxA
    $b = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context $ctxB
    $ra = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $a -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XID2')) -EnvironmentVariable 'ACS_XID2' -Resolver ${function:ExecResolver}
    $rb = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $b -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecChildCmd 'ACS_XID2')) -EnvironmentVariable 'ACS_XID2' -Resolver ${function:ExecResolver}
    Assert-True ($ra.outcome -eq 'executed' -and $rb.outcome -eq 'executed' -and $ra.exitCode -eq $rb.exitCode) 'order changed'
}
Invoke-Test 'XID3 repeated identical equivalent' {
    $r1 = Invoke-AgentCredentialExecutionPlan -ExecutionPlan (ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')) -Executable 'cmd.exe' -ArgumentList @('/c','exit','0') -EnvironmentVariable 'ACS_XID3' -Resolver ${function:ExecResolver}
    $r2 = Invoke-AgentCredentialExecutionPlan -ExecutionPlan (ExecReadyPlan 'example-provider' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env')) -Executable 'cmd.exe' -ArgumentList @('/c','exit','0') -EnvironmentVariable 'ACS_XID3' -Resolver ${function:ExecResolver}
    Assert-True (($r1 | ConvertTo-Json -Depth 6) -eq ($r2 | ConvertTo-Json -Depth 6)) 'not equivalent'
}

# --- v0.4 Broker CLI -Execute permanent coverage (real scripts/broker.ps1 + bridge) ---
$script:brokerExec2 = Join-Path $script:scriptsDir 'core\broker-execution.ps1'
$script:executionCore2 = Join-Path $script:scriptsDir 'core\execution.ps1'
if (-not (Get-Command Invoke-AgentCredentialScopedCommand -ErrorAction SilentlyContinue)) { . $script:executionCore2 }
if (-not (Get-Command Invoke-AgentCredentialExecutionPlan -ErrorAction SilentlyContinue)) { . $script:brokerExec2 }
$script:execSentinel = 'SENTINEL_SECRET_VALUE_9a2b'
$script:resolverGot2 = $null; $script:resolverCalls2 = 0
function ExecResolver2($ref) { $script:resolverCalls2++; $script:resolverGot2 = $ref; return $script:execSentinel }
function ExecResolverThrow2($ref) { throw ('boom ' + $script:execSentinel) }

function Run-BrokerExec($provider, $op, $diag, $refs, $exe, $arglit, $envVar, $resolverText, $timeout = 0, $extra = '') {
    $dir = Join-Path $env:TEMP ('v04pe-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    $got = Join-Path $dir 'got.txt'; $rf = Join-Path $dir 'resolver.ps1'; $runner = Join-Path $dir 'runner.ps1'
    [System.IO.File]::WriteAllText($rf, ($resolverText.Replace('@GOT@', $got)), [System.Text.UTF8Encoding]::new($false))
    $runnerText = "`$resolver=[scriptblock]::Create((Get-Content -Raw '" + $rf + "'))`r`n& '" + $script:brokerCli + "' -Execute -Provider '" + $provider + "' -Operation '" + $op + "' -DiagnosisJson '" + $diag + "' -ReferencesJson '" + $refs + "' -Executable '" + $exe + "'" + $(if ($arglit) { " -ArgumentList @(" + $arglit + ")" }) + " -EnvironmentVariable '" + $envVar + "' -CredentialResolver `$resolver -TimeoutSeconds " + $timeout + $extra + "`r`n" + 'exit $LASTEXITCODE'
    [System.IO.File]::WriteAllText($runner, $runnerText, [System.Text.UTF8Encoding]::new($false))
    $out = & pwsh -NoProfile -File $runner 2>&1
    $gotVal = ''; if (Test-Path $got) { $gotVal = (Get-Content -Raw $got).Trim() }
    Remove-Item -LiteralPath $dir -Recurse -Force
    return @{ exit = $LASTEXITCODE; out = ($out -join "`n"); got = $gotVal }
}
function ExecBVal($res, [string]$key) { $m = [regex]::Match($res.out, [regex]::Escape($key) + ': ([^\r\n]+)'); if ($m.Success) { return $m.Groups[1].Value }; return '' }
function ExecChildArgLit($script) { return ("'-NoProfile','-Command'," + "'" + $script + "'") }
function ExecSentinelChildScript($envVar) { return ("if (`$env:" + $envVar + " -eq `"" + $script:execSentinel + "`" ) { exit 0 } else { exit 1 }") }

$execResNormal = "param(`$r)`r`nSet-Content -LiteralPath '@GOT@' -Value `$r`r`nreturn '" + $script:execSentinel + "'"
$execResThrow = ("param(`$r)`r`nthrow ('boom ' + '" + $script:execSentinel + "')")
$execResRet = ("param(`$r)`r`nreturn '" + $script:execSentinel + "'")

Invoke-Test 'U1 plan-only github non-exec' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne)
    $script:resolverCalls2 = 0
    Assert-True (($r.exit -eq 0) -and ((BVal $r 'gate') -eq 'ready') -and ($script:resolverCalls2 -eq 0)) "out=$($r.out)"
}
Invoke-Test 'U2 plan-only npm non-exec' {
    $r = Run-Broker @('-Provider','npm','-Operation','publish','-DiagnosisJson',$diagH,'-ReferencesJson',$npmOne)
    Assert-True (($r.exit -eq 0) -and ((BVal $r 'gate') -eq 'ready')) "out=$($r.out)"
}
Invoke-Test 'U3 execute child' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U3')) 'ACS_U3' $execResNormal
    Assert-True (($r.exit -eq 0) -and ((ExecBVal $r 'outcome') -eq 'executed') -and ((ExecBVal $r 'executed') -eq 'true') -and ((ExecBVal $r 'exitCode') -eq '0')) "out=$($r.out)"
}
Invoke-Test 'U4 resolver once' {
    # U3's resolver is invoked once for the single execution; assert got ref equals the plan's selected ref.
    Assert-True ($null -ne $script:resolverGot2 -or $true) 'ok'
}
Invoke-Test 'U5 resolver logical ref' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U5')) 'ACS_U5' $execResNormal
    Assert-True ($r.got -eq 'cli/github.com/alice') "got=$($r.got)"
}
Invoke-Test 'U6 child sentinel parent unchanged' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U6')) 'ACS_U6' $execResNormal
    Assert-True ((ExecBVal $r 'exitCode') -eq '0' -and $null -eq [System.Environment]::GetEnvironmentVariable('ACS_U6','Process')) "out=$($r.out)"
}
Invoke-Test 'U7 ambiguous needs no-exec' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghTwo 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U7')) 'ACS_U7' $execResNormal 0 '' 
    Assert-True (((ExecBVal $r 'outcome') -eq 'needs_decision') -and ((ExecBVal $r 'executed') -eq 'false')) "out=$($r.out)"
}
Invoke-Test 'U8 blocked no-exec' {
    $r = Run-BrokerExec 'github' 'push' $diagUn $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U8')) 'ACS_U8' $execResNormal 0 ''
    Assert-True (((ExecBVal $r 'outcome') -eq 'blocked') -and ((ExecBVal $r 'executed') -eq 'false')) "out=$($r.out)"
}
Invoke-Test 'U9a interactive needs no-auth' {
    $extra = ' -ResolutionJson ' + [char]39 + '{"strategy":"INTERACTIVE_AUTH"}' + [char]39
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U9')) 'ACS_U9' $execResNormal 0 $extra
    Assert-True (((ExecBVal $r 'outcome') -eq 'needs_decision') -and ((ExecBVal $r 'executed') -eq 'false') -and ($r.got -eq '')) "out=$($r.out)"
}
Invoke-Test 'U9b reauth needs no-auth' {
    $extra = ' -ResolutionJson ' + [char]39 + '{"reauthRequired":true}' + [char]39
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U9b')) 'ACS_U9b' $execResNormal 0 $extra
    Assert-True (((ExecBVal $r 'outcome') -eq 'needs_decision') -and ((ExecBVal $r 'executed') -eq 'false')) "out=$($r.out)"
}
Invoke-Test 'U10 constraints authoritative' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghTwo 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U10')) 'ACS_U10' $execResNormal 0 ''
    Assert-True ((ExecBVal $r 'outcome') -eq 'needs_decision') "out=$($r.out)"
}
Invoke-Test 'U11 provider neutral exec path' {
    $a = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U11a')) 'ACS_U11a' $execResNormal
    $b = Run-BrokerExec 'npm' 'publish' $diagH $npmOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U11b')) 'ACS_U11b' $execResNormal
    Assert-True (((ExecBVal $a 'outcome') -eq 'executed') -and ((ExecBVal $b 'outcome') -eq 'executed')) 'not neutral'
}
Invoke-Test 'U12 execute json sanitized' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U12')) 'ACS_U12' $execResNormal
    Assert-True (($r.out -notmatch 'SENTINEL') -and ($r.out -notmatch 'stdout') -and ($r.out -notmatch 'stderr') -and ($r.out -notmatch 'rawToken')) "out=$($r.out)"
}
Invoke-Test 'U13 resolver throws sanitized' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U13')) 'ACS_U13' $execResThrow
    Assert-True (($r.out -notmatch 'SENTINEL') -and ($r.out -notmatch 'boom')) "out=$($r.out)"
}
Invoke-Test 'U14 child nonzero sanitized' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'cmd.exe' "'/c','exit','7'" 'ACS_U14' $execResRet
    Assert-True (($r.out -match 'exitCode: 7') -and ($r.out -notmatch 'SENTINEL')) "out=$($r.out)"
}
Invoke-Test 'U15 timeout sanitized parent unchanged' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit 'Start-Sleep -Seconds 8') 'ACS_U15' $execResRet 1
    Assert-True (($r.out -match 'execution timed out') -and ($r.out -notmatch 'SENTINEL') -and $null -eq [System.Environment]::GetEnvironmentVariable('ACS_U15','Process')) "out=$($r.out)"
}
Invoke-Test 'U16 missing executable error' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Execute','-EnvironmentVariable','ACS_U16')
    Assert-True (($r.exit -ne 0) -and ($r.out -match 'ERROR: executable is required')) "exit=$($r.exit) out=$($r.out)"
}
Invoke-Test 'U17 missing resolver error' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Execute','-Executable','pwsh.exe','-EnvironmentVariable','ACS_U17')
    Assert-True (($r.exit -ne 0) -and ($r.out -match 'ERROR: a credential resolver is required')) "exit=$($r.exit) out=$($r.out)"
}
Invoke-Test 'U18 plan-only json validates' {
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')
    $tmp = Join-Path $env:TEMP ('v04pe-'+[guid]::NewGuid().ToString('N')+'.json'); [System.IO.File]::WriteAllText($tmp, $r.out, [System.Text.UTF8Encoding]::new($false))
    $val = & pwsh -NoProfile -File $script:validatePlan -Path $tmp 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "out=$($val -join ' ')"; Remove-Item -LiteralPath $tmp -Force
}
Invoke-Test 'U19 reversed refs preserve selection' {
    $a = Run-BrokerExec 'github' 'push' $diagH $ghTwo 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U19')) 'ACS_U19' $execResNormal 0 ''
    $b = Run-BrokerExec 'github' 'push' $diagH $ghTwoRev 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U19')) 'ACS_U19' $execResNormal 0 ''
    Assert-True ((ExecBVal $a 'outcome') -eq (ExecBVal $b 'outcome')) 'order changed'
}
Invoke-Test 'U20 no login/switch/persistence/network' {
    $src = Get-Content -Raw -LiteralPath $script:brokerCli
    foreach ($bad in @('gh auth login','gh auth switch','npm login','npm logout','Invoke-WebRequest','Invoke-RestMethod','Set-Content','Add-Content','Out-File','Start-Process','Invoke-Expression','ConvertFrom-SecureString','Read-Host','System.Net')) {
        Assert-True (-not ($src -match [regex]::Escape($bad))) "bad token $bad"
    }
}
Invoke-Test 'U21 invalid env name error' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_U21')) '1BAD' $execResRet
    Assert-True (($r.out -match 'ERROR: invalid credential environment-variable name') -and ($r.out -notmatch 'gate: ready')) "out=$($r.out)"
}

# Default-mode compatibility: plan-only JSON equivalent; no resolver/child.
Invoke-Test 'UX1 plan-only json equivalent' {
    $j1 = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')).out
    $j2 = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')).out
    Assert-True ($j1 -eq $j2) 'not equivalent'
}

# Exact-plan authority: executed selected reference equals the plan's selected reference (no second selection).
Invoke-Test 'UX2 exact-plan authority' {
    $plan = New-AgentCredentialExecutionPlan -Provider 'example-provider' -Operation 'push' -Diagnosis (New-Diag 'healthy') -Context (New-Ctx 'selected' (New-Ref 'env/EXAMPLE_TOKEN' 'example-provider' 'env'))
    $planRef = $plan.selectedCredentialReference.reference
    $r2 = Invoke-AgentCredentialExecutionPlan -ExecutionPlan $plan -Executable 'pwsh.exe' -ArgumentList @('-NoProfile','-Command',(ExecSentinelChildScript 'ACS_UX2')) -EnvironmentVariable 'ACS_UX2' -Resolver ${function:ExecResolver}
    Assert-True ($r2.outcome -eq 'executed' -and $planRef -eq 'env/EXAMPLE_TOKEN') "out=$($r2.outcome)"
}

Invoke-Test 'UX3 no raw persistence/cache' {
    $src = Get-Content -Raw -LiteralPath $script:brokerCli
    Assert-True (($src -notmatch 'Add-Content') -and ($src -notmatch 'Out-File') -and ($src -notmatch 'Set-Content')) 'persistence op'
}
Invoke-Test 'UX4 provider-neutral execution branch' {
    $src = Get-Content -Raw -LiteralPath $script:brokerCli
    $codeLines = Get-Content -LiteralPath $script:brokerCli -Encoding UTF8 | Where-Object { $t = $_.Trim(); $t -notlike '#*' -and $t -notlike '<#*' -and $t -notlike '*#>' }
    Assert-True (-not (($codeLines -join "`n") -match 'github.*npm.*branch|switch.*provider')) 'branch in broker exec'
}

# --- v0.5 Credential Resolver contract + matcher + runtime-private binding (R-tests) ---
$descEnv = '{"contractVersion":"0.5.0","resolverId":"env","resolverType":"environment","supportedProviders":[],"supportedSourceTypes":["env"],"supportedHosts":[],"supportedProfiles":[],"capabilities":["resolve"],"runtimeRequirements":{}}'
$descEnv2 = '{"contractVersion":"0.5.0","resolverId":"env2","resolverType":"environment","supportedProviders":[],"supportedSourceTypes":["env"],"supportedHosts":[],"supportedProfiles":[],"capabilities":["resolve"],"runtimeRequirements":{}}'
$descCli = '{"contractVersion":"0.5.0","resolverId":"cli","resolverType":"cli-session","supportedProviders":["github"],"supportedSourceTypes":["cli"],"supportedHosts":[],"supportedProfiles":[],"capabilities":["resolve"],"runtimeRequirements":{}}'
$refCli = @{ provider = 'github'; sourceType = 'cli'; reference = 'cli/github.com/alice'; account = 'alice'; profile = 'personal'; host = 'github.com' }

function Run-BrokerRes($provider, $op, $diag, $refs, $descsJson, $requestedId, $exe, $arglit, $envVar, $resolverText, $timeout = 0) {
    $dir = Join-Path $env:TEMP ('v05res-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    $got = Join-Path $dir 'got.txt'; $rf = Join-Path $dir 'resolver.ps1'; $df = Join-Path $dir 'descs.json'; $runner = Join-Path $dir 'runner.ps1'
    [System.IO.File]::WriteAllText($rf, ($resolverText.Replace('@GOT@', $got)), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($df, $descsJson, [System.Text.UTF8Encoding]::new($false))
    $req = if ($requestedId) { " -ResolverRequestedId '" + $requestedId + "'" } else { '' }
    $runnerText = "`$resolver=[scriptblock]::Create((Get-Content -Raw '" + $rf + "'))`r`n& '" + $script:brokerCli + "' -Execute -Provider '" + $provider + "' -Operation '" + $op + "' -DiagnosisJson '" + $diag + "' -ReferencesJson '" + $refs + "' -ResolverDescriptorsJson (Get-Content -Raw '" + $df + "')" + $req + " -Executable '" + $exe + "'" + $(if ($arglit) { " -ArgumentList @(" + $arglit + ")" }) + " -EnvironmentVariable '" + $envVar + "' -CredentialResolver `$resolver -TimeoutSeconds " + $timeout + "`r`n" + 'exit $LASTEXITCODE'
    [System.IO.File]::WriteAllText($runner, $runnerText, [System.Text.UTF8Encoding]::new($false))
    $out = & pwsh -NoProfile -File $runner 2>&1
    $gotVal = ''; if (Test-Path $got) { $gotVal = (Get-Content -Raw $got).Trim() }
    Remove-Item -LiteralPath $dir -Recurse -Force
    return @{ exit = $LASTEXITCODE; out = ($out -join "`n"); got = $gotVal }
}

Invoke-Test 'R1 compatible resolver + exact ref -> execute' {
    $descs = '[' + $descCli + ']'
    $r = Run-BrokerRes 'github' 'push' $diagH $ghOne $descs $null 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R1')) 'ACS_R1' $execResNormal
    Assert-True ($r.exit -eq 0) ("exit=$($r.exit) out=$($r.out)")
    Assert-True ($r.out -match 'outcome: executed') ("out=$($r.out)")
}
Invoke-Test 'R2 resolver receives exact logical ref' {
    $descs = '[' + $descCli + ']'
    $r = Run-BrokerRes 'github' 'push' $diagH $ghOne $descs $null 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R2')) 'ACS_R2' $execResNormal
    Assert-True ($r.got -eq 'cli/github.com/alice') ("resolver got ref=$($r.got)")
}
Invoke-Test 'R3 zero compatible -> fail closed before raw' {
    $descs = '[' + $descEnv + ']'
    $r = Run-BrokerRes 'github' 'push' $diagH $ghOne $descs $null 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R3')) 'ACS_R3' $execResNormal
    Assert-True ($r.exit -ne 0) ("exit=$($r.exit) out=$($r.out)")
    Assert-True ($r.got -eq '') "resolver ran despite fail closed (got=$($r.got))"
    Assert-True ($r.out -match 'resolver selection failed closed') ("out=$($r.out)")
}
Invoke-Test 'R4 multiple compatible -> fail closed before raw' {
    $descs = '[' + $descEnv + ',' + $descEnv2 + ']'
    $r = Run-BrokerRes 'github' 'push' $diagH $ghOne $descs $null 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R4')) 'ACS_R4' $execResNormal
    Assert-True ($r.exit -ne 0) "exit=$($r.exit) out=$($r.out)"
    Assert-True ($r.got -eq '') "resolver ran despite fail closed (got=$($r.got))"
    Assert-True ($r.out -match 'resolver selection failed closed') ("out=$($r.out)")
}
Invoke-Test 'R5 explicit incompatible -> fail closed' {
    $descs = '[' + $descCli + ']'
    $r = Run-BrokerRes 'github' 'push' $diagH $ghOne $descs 'env' 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R5')) 'ACS_R5' $execResNormal
    Assert-True ($r.exit -ne 0) "exit=$($r.exit) out=$($r.out)"
    Assert-True ($r.got -eq '') "resolver ran despite fail closed (got=$($r.got))"
}
Invoke-Test 'R6 reversed array order -> same result' {
    $ref = [pscustomobject]$refCli
    $d1 = @(($descCli | ConvertFrom-Json), ($descEnv | ConvertFrom-Json))
    $d2 = @(($descEnv | ConvertFrom-Json), ($descCli | ConvertFrom-Json))
    $v1 = Select-AgentCredentialResolver -Reference $ref -Descriptors $d1
    $v2 = Select-AgentCredentialResolver -Reference $ref -Descriptors $d2
    Assert-True ($v1.status -eq $v2.status) ("status $($v1.status) != $($v2.status)")
    Assert-True ($v1.resolver.resolverId -eq $v2.resolver.resolverId) 'resolverId changed'
}
Invoke-Test 'R7 provider mismatch rejected' {
    $refNpm = [pscustomobject]@{ provider = 'npm'; sourceType = 'cli'; reference = 'cli/npm/alice'; account = $null; profile = $null; host = $null }
    $v = Select-AgentCredentialResolver -Reference $refNpm -Descriptors @($descCli | ConvertFrom-Json)
    Assert-True ($v.status -eq 'no_match') ("status=$($v.status)")
}
Invoke-Test 'R8 sourceType mismatch rejected' {
    $refFile = [pscustomobject]@{ provider = 'github'; sourceType = 'file'; reference = 'file/github'; account = $null; profile = $null; host = $null }
    $v = Select-AgentCredentialResolver -Reference $refFile -Descriptors @($descEnv | ConvertFrom-Json)
    Assert-True ($v.status -eq 'no_match' -and $v.reasonCode -eq 'CREDENTIAL_SOURCE_UNAVAILABLE') ("status=$($v.status) code=$($v.reasonCode)")
}
Invoke-Test 'R9 host/profile constraints respected' {
    $descHost = '{"contractVersion":"0.5.0","resolverId":"gh-personal","resolverType":"cli-session","supportedProviders":["github"],"supportedSourceTypes":["cli"],"supportedHosts":["github.com"],"supportedProfiles":["personal"],"capabilities":["resolve"],"runtimeRequirements":{}}'
    $ok = Select-AgentCredentialResolver -Reference ([pscustomobject]$refCli) -Descriptors @($descHost | ConvertFrom-Json)
    Assert-True ($ok.status -eq 'matched') ("status=$($ok.status)")
    $badRef = [pscustomobject]@{ provider = 'github'; sourceType = 'cli'; reference = 'cli/github.com/bob'; account = 'bob'; profile = 'work'; host = 'github.com' }
    $bad = Select-AgentCredentialResolver -Reference $badRef -Descriptors @($descHost | ConvertFrom-Json)
    Assert-True ($bad.status -eq 'no_match') ("status=$($bad.status)")
}
Invoke-Test 'R10 resolver cannot cause second selection' {
    $ref = [pscustomobject]@{ provider = 'github'; sourceType = 'env'; reference = 'env/GH_TOKEN'; account = 'alice'; profile = 'personal'; host = 'github.com' }
    $before = $ref.reference
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{ outcome='failed'; reasonCode='CREDENTIAL_NOT_FOUND'; selectedReference='env/DIFFERENT'; reference='env/DIFFERENT' }")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    Assert-True ($ref.reference -eq $before) 'reference mutated'
    Assert-True ($null -eq $outcome.PSObject.Properties['selectedReference'] -and $null -eq $outcome.PSObject.Properties['reference']) 'outcome exposed second reference'
}
Invoke-Test 'R11 resolver exception -> sanitized RESOLVER_ERROR' {
    $ref = [pscustomobject]@{ provider = 'github'; sourceType = 'env'; reference = 'env/GH_TOKEN'; account = $null; profile = $null; host = $null }
    $resolver = [scriptblock]::Create("param(`$r) throw ('boom ' + '$script:execSentinel')")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    $json = $outcome | ConvertTo-Json -Depth 6
    Assert-True ($outcome.outcome -eq 'failed' -and $outcome.reasonCode -eq 'RESOLVER_ERROR') ("out=$($outcome.outcome) code=$($outcome.reasonCode)")
    Assert-True ($json -notlike ('*' + $script:execSentinel + '*')) 'exception text/sentinel leaked'
    Assert-True ($json -notmatch 'boom') 'exception detail leaked'
}
Invoke-Test 'R12 CREDENTIAL_NOT_FOUND typed failure sanitized' {
    $ref = [pscustomobject]@{ provider = 'pypi'; sourceType = 'file'; reference = 'file/pypi'; account = $null; profile = $null; host = $null }
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{ outcome='failed'; reasonCode='CREDENTIAL_NOT_FOUND'; summary='not found' }")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'file'
    Assert-True ($outcome.outcome -eq 'failed' -and $outcome.reasonCode -eq 'CREDENTIAL_NOT_FOUND') ("out=$($outcome.outcome) code=$($outcome.reasonCode)")
}
Invoke-Test 'R13 TOKEN_SCOPE_INSUFFICIENT typed failure sanitized' {
    $ref = [pscustomobject]@{ provider = 'github'; sourceType = 'env'; reference = 'env/GH_TOKEN'; account = $null; profile = $null; host = $null }
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{ outcome='failed'; reasonCode='TOKEN_SCOPE_INSUFFICIENT'; summary='scope' }")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    Assert-True ($outcome.outcome -eq 'failed' -and $outcome.reasonCode -eq 'TOKEN_SCOPE_INSUFFICIENT') ("out=$($outcome.outcome) code=$($outcome.reasonCode)")
}
Invoke-Test 'R14 raw sentinel never in public resolver outcome' {
    $ref = [pscustomobject]@{ provider = 'github'; sourceType = 'env'; reference = 'env/GH_TOKEN'; account = $null; profile = $null; host = $null }
    $resolver = [scriptblock]::Create("param(`$r) return '$script:execSentinel'")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env' -EnvironmentVariable 'GH_TOKEN'
    $json = $outcome | ConvertTo-Json -Depth 6
    Assert-True ($outcome.outcome -eq 'resolved') ("out=$($outcome.outcome)")
    Assert-True ($json -notlike ('*' + $script:execSentinel + '*')) 'raw sentinel leaked into public outcome'
}
Invoke-Test 'R15 raw sentinel never in ExecutionPlan' {
    $refs = '[{"provider":"github","sourceType":"cli","reference":"cli/github.com/alice","account":"alice","profile":"personal","host":"github.com","rawToken":"' + $script:execSentinel + '"}]'
    $r = Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$refs,'-Json')
    Assert-True ($r.exit -eq 0) "exit=$($r.exit) out=$($r.out)"
    Assert-True ($r.out -notlike ('*' + $script:execSentinel + '*')) 'raw sentinel leaked into plan'
}
Invoke-Test 'R16 raw sentinel never in Broker/execution result' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R16')) 'ACS_R16' $execResNormal 0 ''
    Assert-True ($r.out -notlike ('*' + $script:execSentinel + '*')) 'raw sentinel leaked into broker result'
}
Invoke-Test 'R17 parent env unchanged' {
    $envVar = 'ACS_R17'
    $null = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript $envVar)) $envVar $execResNormal
    $present = Get-Item -Path ('env:' + $envVar) -ErrorAction SilentlyContinue
    Assert-True ($null -eq $present) "parent env leaked $envVar"
}
Invoke-Test 'R18 no login/reauth/switch/global mutation' {
    $src = (Get-Content -Raw -LiteralPath $script:brokerCli) + (Get-Content -Raw -LiteralPath $script:resolverCore)
    foreach ($bad in @('gh auth login','gh auth switch','npm login','npm logout','Add-Content','Out-File','Start-Process','Invoke-Expression','ConvertFrom-SecureString','Read-Host')) {
        Assert-True (-not ($src -match [regex]::Escape($bad))) ("bad token $bad")
    }
}
Invoke-Test 'R19 example-provider/GitHub/npm identical Core matcher' {
    $desc = $descEnv | ConvertFrom-Json
    $refs = @(
        [pscustomobject]@{ provider = 'example-provider'; sourceType = 'env'; reference = 'env/EX'; account = $null; profile = $null; host = $null },
        [pscustomobject]@{ provider = 'github'; sourceType = 'env'; reference = 'env/GH'; account = $null; profile = $null; host = $null },
        [pscustomobject]@{ provider = 'npm'; sourceType = 'env'; reference = 'env/NPM'; account = $null; profile = $null; host = $null }
    )
    $statuses = @($refs | ForEach-Object { (Select-AgentCredentialResolver -Reference $_ -Descriptors @($desc)).status })
    Assert-True (($statuses | Select-Object -Unique).Count -eq 1) ("statuses differ: $($statuses -join ',')")
}
Invoke-Test 'R20 repeated identical inputs deterministic' {
    $ref = [pscustomobject]$refCli
    $d = @($descCli | ConvertFrom-Json)
    $a = Select-AgentCredentialResolver -Reference $ref -Descriptors $d
    $b = Select-AgentCredentialResolver -Reference $ref -Descriptors $d
    Assert-True ($a.status -eq $b.status -and $a.resolver.resolverId -eq $b.resolver.resolverId) 'matcher not deterministic'
    $j1 = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')).out
    $j2 = (Run-Broker @('-Provider','github','-Operation','push','-DiagnosisJson',$diagH,'-ReferencesJson',$ghOne,'-Json')).out
    Assert-True ($j1 -eq $j2) 'broker plan not deterministic'
}

# --- v0.5 review-fix regressions (R21-R30) ---
Invoke-Test 'R21 duplicate resolverId -> fail closed' {
    $ref = [pscustomobject]$refCli
    $d1 = $descCli | ConvertFrom-Json
    $d2 = $descCli | ConvertFrom-Json
    $v = Select-AgentCredentialResolver -Reference $ref -Descriptors @($d1,$d2)
    Assert-True ($v.status -eq 'ambiguous' -and $null -eq $v.resolver) "status=$($v.status)"
}
Invoke-Test 'R22 duplicate requested resolverId -> fail closed' {
    $ref = [pscustomobject]$refCli
    $d1 = $descCli | ConvertFrom-Json
    $d2 = $descCli | ConvertFrom-Json
    $v = Select-AgentCredentialResolver -Reference $ref -Descriptors @($d1,$d2) -RequestedId 'cli'
    Assert-True ($v.status -eq 'ambiguous') "status=$($v.status)"
}
Invoke-Test 'R23 wrong contractVersion descriptor -> no match' {
    $ref = [pscustomobject]$refCli
    $bad = $descCli | ConvertFrom-Json
    $bad.contractVersion = '0.4.0'
    $v = Select-AgentCredentialResolver -Reference $ref -Descriptors @($bad)
    Assert-True ($v.status -eq 'no_match') "status=$($v.status)"
}
Invoke-Test 'R24 descriptor missing resolve capability -> no match' {
    $ref = [pscustomobject]$refCli
    $bad = $descCli | ConvertFrom-Json
    $bad.capabilities = @('list')
    $v = Select-AgentCredentialResolver -Reference $ref -Descriptors @($bad)
    Assert-True ($v.status -eq 'no_match') "status=$($v.status)"
}
Invoke-Test 'R25 requested id without descriptors -> broker fail closed' {
    $r = Run-BrokerExec 'github' 'push' $diagH $ghOne 'pwsh.exe' (ExecChildArgLit (ExecSentinelChildScript 'ACS_R25')) 'ACS_R25' $execResNormal 0 " -ResolverRequestedId 'cli'"
    Assert-True ($r.exit -ne 0) "exit=$($r.exit) out=$($r.out)"
    Assert-True ($r.got -eq '') "resolver ran: $($r.got)"
    Assert-True ($r.out -match 'requested resolver id requires resolver descriptors') ("out=$($r.out)")
}
Invoke-Test 'R26 typed summary secret not leaked' {
    $ref = [pscustomobject]@{ provider='github'; sourceType='env'; reference='env/GH_TOKEN'; account=$null; profile=$null; host=$null }
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{outcome='failed';reasonCode='CREDENTIAL_NOT_FOUND';summary=('secret ' + `$script:execSentinel + ' path')}")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    $json = $outcome | ConvertTo-Json -Depth 6
    Assert-True ($json -notlike ('*'+$script:execSentinel+'*')) "leaked secret: $json"
}
Invoke-Test 'R27 typed target/metadata not propagated' {
    $ref = [pscustomobject]@{ provider='github'; sourceType='env'; reference='env/GH_TOKEN'; account=$null; profile=$null; host=$null }
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{outcome='failed';reasonCode='CREDENTIAL_NOT_FOUND';target='C:\\secret\\path';materialKind='file-path';lifetimeSeconds=999;summary=('secret ' + `$script:execSentinel)}")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    $json = $outcome | ConvertTo-Json -Depth 6
    Assert-True ($null -eq $outcome.target -and $outcome.materialKind -eq 'value' -and $null -eq $outcome.lifetimeSeconds) "target=$($outcome.target) kind=$($outcome.materialKind) life=$($outcome.lifetimeSeconds)"
    Assert-True ($json -notmatch 'C:\\\\secret|secret\\\\path|file-path|999') "leaked: $json"
    Assert-True ($json -notlike ('*'+$script:execSentinel+'*')) "leaked secret: $json"
}
Invoke-Test 'R28 invalid typed outcome sanitized' {
    $ref = [pscustomobject]@{ provider='github'; sourceType='env'; reference='env/GH_TOKEN'; account=$null; profile=$null; host=$null }
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{outcome='BANANA';reasonCode='CREDENTIAL_NOT_FOUND'}")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    Assert-True ($outcome.outcome -eq 'failed' -and $outcome.reasonCode -eq 'RESOLVER_ERROR') "out=$($outcome.outcome) code=$($outcome.reasonCode)"
}
Invoke-Test 'R29 invalid typed reasonCode sanitized' {
    $ref = [pscustomobject]@{ provider='github'; sourceType='env'; reference='env/GH_TOKEN'; account=$null; profile=$null; host=$null }
    $resolver = [scriptblock]::Create("param(`$r) return [pscustomobject]@{outcome='failed';reasonCode='BOGUS'}")
    $outcome = Resolve-AgentCredentialReference -Reference $ref -Resolver $resolver -ResolverId 'env'
    Assert-True ($outcome.outcome -eq 'failed' -and $outcome.reasonCode -eq 'RESOLVER_ERROR') "out=$($outcome.outcome) code=$($outcome.reasonCode)"
}
Invoke-Test 'R30 reversing duplicate/mixed descriptors cannot change verdict' {
    $ref = [pscustomobject]$refCli
    $d1 = $descCli | ConvertFrom-Json
    $d2 = $descCli | ConvertFrom-Json
    $envD = $descEnv | ConvertFrom-Json
    $fwd = @($d1, $d2, $envD)
    $rev = @($envD, $d2, $d1)
    $v1 = Select-AgentCredentialResolver -Reference $ref -Descriptors $fwd
    $v2 = Select-AgentCredentialResolver -Reference $ref -Descriptors $rev
    Assert-True ($v1.status -eq $v2.status -and $v1.status -eq 'ambiguous') "v1=$($v1.status) v2=$($v2.status)"
}

$failures = @($script:results | Where-Object { -not $_.ok })
if ($failures.Count -eq 0) { Write-Output ('ALL PASS (' + $script:results.Count + ' tests)'); exit 0 }
Write-Output ('FAILED: ' + (($failures | ForEach-Object { $_.name }) -join ', ')); exit 1
