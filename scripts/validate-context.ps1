<#
.SYNOPSIS
  Reference contract validator for the Agent Credential Layer v0.3 Credential Context.
.DESCRIPTION
  Reads schema/credential-context.schema.json (resolved relative to this script's own
  location) and validates a supplied Credential Context JSON document: full JSON Schema
  validation when compatible support is available, plus the v0.3 semantic invariants.
  Developer/conformance tooling only. It never reads credential files or credential
  environment variables, never inspects keychains, and never executes provider, network,
  authentication, or policy operations.
.PARAMETER Path
  Path to the Credential Context JSON document to validate.
.EXAMPLE
  .\scripts\validate-context.ps1 -Path .\fixtures\v0.3\valid\context-basic.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Path $scriptRoot -Parent
$schemaFile = Join-Path $repoRoot 'schema\credential-context.schema.json'

# Exit codes: 0 = valid context instance; 1 = invalid input/instance; 2 = validator/tooling error.
function Exit-Valid { Write-Output 'VALID: Agent Credential Layer credential context v0.3.0'; exit 0 }
function Exit-Invalid([string]$message) { Write-Output ('INVALID: ' + $message); exit 1 }
function Exit-Error([string]$message) { Write-Output ('ERROR: ' + $message); exit 2 }

# --- locate contract file (independent of the current working directory) ---
if (-not (Test-Path -LiteralPath $schemaFile)) { Exit-Error ("context schema not found: " + $schemaFile) }
if (-not (Test-Path -LiteralPath $Path)) { Exit-Invalid ("input file not found: " + $Path) }

# --- parse inputs; never echo document content ---
try { $jsonText = Get-Content -Raw -LiteralPath $Path } catch { Exit-Invalid 'input file could not be read' }
try { $doc = $jsonText | ConvertFrom-Json } catch { Exit-Invalid 'input is not valid JSON' }
try { $schemaText = Get-Content -Raw -LiteralPath $schemaFile } catch { Exit-Error 'context schema could not be read' }
try { $schema = $schemaText | ConvertFrom-Json } catch { Exit-Error 'context schema is not valid JSON' }

# --- full JSON Schema validation only when compatible support is available ---
$testJsonCmd = Get-Command Test-Json -ErrorAction SilentlyContinue
$schemaSupported = ($null -ne $testJsonCmd) -and $testJsonCmd.Parameters.ContainsKey('Schema')
if (-not $schemaSupported) {
    Exit-Error 'compatible JSON Schema validation is unavailable'
}
$schemaResult = $false
try { $schemaResult = Test-Json -Json $jsonText -Schema $schemaText -ErrorAction SilentlyContinue } catch {
    Exit-Error 'compatible JSON Schema validation failed to run'
}
if (-not $schemaResult) { Exit-Invalid 'instance does not conform to schema/credential-context.schema.json' }

# --- v0.3 semantic invariants (representation consistency only) ---

# 1. contractVersion
if ($doc.contractVersion -ne '0.3.0') { Exit-Invalid 'contractVersion is not 0.3.0' }

# 2. context.provider must match every available reference provider
$refs = @($doc.availableReferences)
foreach ($ref in $refs) {
    if ($ref.provider -ne $doc.provider) { Exit-Invalid ('available reference provider does not match context provider: ' + $ref.reference) }
}

# 3. duplicate logical references are invalid
$refIds = @($refs | ForEach-Object { $_.reference })
if (($refIds | Select-Object -Unique).Count -ne $refIds.Count) { Exit-Invalid 'availableReferences contains duplicate logical references' }

# 4. selectedReference, when non-null, must correspond to exactly one available reference
if ($null -ne $doc.selectedReference) {
    $selRef = $doc.selectedReference
    if ($selRef.provider -ne $doc.provider) { Exit-Invalid 'selectedReference provider does not match context provider' }
    $matches = @($refs | Where-Object { $_.reference -eq $selRef.reference })
    if ($matches.Count -ne 1) { Exit-Invalid ('selectedReference must correspond to exactly one available reference (matches=' + $matches.Count + ')') }
}

# 5. selectedProfile must not contradict requestedProfile. The v0.3 contract defines
#    no deliberate-override marker, so any contradiction is invalid.
if (($null -ne $doc.requestedProfile) -and ($null -ne $doc.selectedProfile) -and ($doc.requestedProfile -ne $doc.selectedProfile)) {
    Exit-Invalid 'selectedProfile contradicts requestedProfile'
}

# 6. no raw secret-bearing fields or values are accepted. Field names are already
#    rejected by the schema (additionalProperties/propertyNames); this deterministic
#    pattern scan is an additional guard over the raw document text.
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
