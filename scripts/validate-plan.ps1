<#
.SYNOPSIS
  Reference contract validator for the Agent Credential Layer v0.4 Credential Execution Plan.
.DESCRIPTION
  Reads schema/credential-plan.schema.json (resolved relative to this script's own location)
  and validates a supplied Execution Plan JSON document: full JSON Schema validation when
  compatible support is available, plus the v0.4 cross-field semantic invariants.
  Developer/conformance tooling only. Never reads credential files or environment variables,
  never inspects keychains, and never executes provider/network/auth/policy operations.
.PARAMETER Path
  Path to the Credential Execution Plan JSON document to validate.
.EXAMPLE
  .\scripts\validate-plan.ps1 -Path .\fixtures\v0.4\valid\plan-ready.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Path $scriptRoot -Parent
$schemaFile = Join-Path $repoRoot 'schema\credential-plan.schema.json'
$registryFile = Join-Path $repoRoot 'schema\diagnostic-codes.json'

# Exit codes: 0 = valid plan; 1 = invalid input/instance; 2 = validator/tooling error.
function Exit-Valid { Write-Output 'VALID: Agent Credential Layer credential execution plan v0.4.0'; exit 0 }
function Exit-Invalid([string]$message) { Write-Output ('INVALID: ' + $message); exit 1 }
function Exit-Error([string]$message) { Write-Output ('ERROR: ' + $message); exit 2 }

if (-not (Test-Path -LiteralPath $schemaFile)) { Exit-Error ("plan schema not found: " + $schemaFile) }
if (-not (Test-Path -LiteralPath $registryFile)) { Exit-Error ("code registry not found: " + $registryFile) }
if (-not (Test-Path -LiteralPath $Path)) { Exit-Invalid ("input file not found: " + $Path) }

try { $jsonText = Get-Content -Raw -LiteralPath $Path } catch { Exit-Invalid 'input file could not be read' }
try { $doc = $jsonText | ConvertFrom-Json } catch { Exit-Invalid 'input is not valid JSON' }
try { $schemaText = Get-Content -Raw -LiteralPath $schemaFile } catch { Exit-Error 'plan schema could not be read' }
try { $schema = $schemaText | ConvertFrom-Json } catch { Exit-Error 'plan schema is not valid JSON' }
try { $registryText = Get-Content -Raw -LiteralPath $registryFile } catch { Exit-Error 'code registry could not be read' }
try { $registry = $registryText | ConvertFrom-Json } catch { Exit-Error 'code registry is not valid JSON' }

# --- full JSON Schema validation only when compatible support is available ---
$testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
$schemaSupported = ($null -ne $testJsonCmd) -and $testJsonCmd.Parameters.ContainsKey('Schema')
if (-not $schemaSupported) { Exit-Error 'compatible JSON Schema validation is unavailable' }
$schemaResult = $false
try { $schemaResult = Test-Json -Json $jsonText -Schema $schemaText -ErrorAction SilentlyContinue } catch {
    Exit-Error 'compatible JSON Schema validation failed to run'
}
if (-not $schemaResult) { Exit-Invalid 'instance does not conform to schema/credential-plan.schema.json' }

# --- v0.4 semantic invariants (representation consistency only) ---

# 1. contractVersion
if ($doc.contractVersion -ne '0.4.0') { Exit-Invalid 'contractVersion is not 0.4.0' }

# 2. decisionCode, when non-null, must reuse a v0.2 public resolution/decision code.
$resolutionCodes = @($registry.codes.resolution.PSObject.Properties.Name)
if ($null -ne $doc.decisionCode -and -not [string]::IsNullOrEmpty($doc.decisionCode)) {
    if ($resolutionCodes -notcontains $doc.decisionCode) {
        Exit-Invalid ('decisionCode is not a known v0.2 resolution code: ' + $doc.decisionCode)
    }
}

# 3. cross-field: selectedCredentialReference, when non-null, must match context.selectedReference.
$selRef = $doc.selectedCredentialReference
$ctxRef = $doc.context.selectedReference
if ($null -ne $selRef) {
    if ($null -eq $ctxRef) { Exit-Invalid 'selectedCredentialReference is set but context.selectedReference is null' }
    if ($selRef.reference -ne $ctxRef.reference) { Exit-Invalid 'selectedCredentialReference does not match context.selectedReference' }
    if ($selRef.provider -ne $ctxRef.provider) { Exit-Invalid 'selectedCredentialReference provider does not match context.selectedReference' }
}

# 4. gate=ready: healthy diagnosis + selected context + non-null selected reference.
if ($doc.gate -eq 'ready') {
    if ($doc.diagnosis.status -ne 'healthy') { Exit-Invalid 'gate=ready requires diagnosis.status=healthy' }
    if ($doc.context.outcome -ne 'selected') { Exit-Invalid 'gate=ready requires context.outcome=selected' }
    if ($null -eq $selRef) { Exit-Invalid 'gate=ready requires a non-null selectedCredentialReference' }
}

# 5. gate=needs_decision: fails closed (not executable-ready) and carries a non-null decisionCode.
if ($doc.gate -eq 'needs_decision') {
    if ($doc.diagnosis.status -eq 'healthy' -and $doc.context.outcome -eq 'selected') {
        Exit-Invalid 'gate=needs_decision conflicts with ready conditions'
    }
    if ([string]::IsNullOrEmpty($doc.decisionCode)) { Exit-Invalid 'gate=needs_decision requires a non-null decisionCode' }
}

# 6. gate=blocked: never claims ready; non-selected context implies null selected reference.
if ($doc.gate -eq 'blocked') {
    if ($doc.diagnosis.status -eq 'healthy' -and $doc.context.outcome -eq 'selected') {
        Exit-Invalid 'gate=blocked conflicts with ready conditions'
    }
    if ($doc.context.outcome -ne 'selected' -and $null -ne $selRef) {
        Exit-Invalid 'gate=blocked: non-selected context must have null selectedCredentialReference'
    }
}

# 7. no raw secret-bearing values are accepted (deterministic scan; field names are already
#    rejected by the schema propertyNames/additionalProperties guards).
$secretPatterns = @(
    'gho_[A-Za-z0-9]{20,}',
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'pypi-Ag[A-Za-z0-9]{10,}',
    'glpat-[A-Za-z0-9_-]{20,}',
    'AKIA[0-9A-Z]{16}',
    'xox[baprs]-[A-Za-z0-9-]{10,}'
)
foreach ($pat in $secretPatterns) {
    if ($jsonText -match $pat) { Exit-Invalid ('input contains a secret-bearing value pattern: ' + $pat) }
}

Exit-Valid
