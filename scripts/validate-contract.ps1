<#
.SYNOPSIS
  Reference contract validator for the Agent Credential Layer v0.2 Diagnosis Result.
.DESCRIPTION
  Reads schema/diagnosis-result.schema.json and schema/diagnostic-codes.json from the
  repository (resolved relative to this script's own location) and validates a supplied
  Diagnosis Result JSON document: full JSON Schema validation when compatible support is
  available, plus the v0.2 cross-file semantic invariants.
  This is developer/conformance tooling only. It never reads credential files, never reads
  credential environment variables, never inspects keychains, and never executes provider,
  authentication, or policy operations.
.PARAMETER Path
  Path to the Diagnosis Result JSON document to validate.
.EXAMPLE
  .\scripts\validate-contract.ps1 -Path .\example-result.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Path $scriptRoot -Parent
$schemaFile = Join-Path $repoRoot 'schema\diagnosis-result.schema.json'
$registryFile = Join-Path $repoRoot 'schema\diagnostic-codes.json'

# Exit codes: 0 = valid contract instance; 1 = invalid input/instance; 2 = validator/tooling error.
function Exit-Valid { Write-Output 'VALID: Agent Credential Layer diagnosis result v0.2.0'; exit 0 }
function Exit-Invalid([string]$message) { Write-Output ('INVALID: ' + $message); exit 1 }
function Exit-Error([string]$message) { Write-Output ('ERROR: ' + $message); exit 2 }

# --- locate contract files (independent of the current working directory) ---
if (-not (Test-Path -LiteralPath $schemaFile)) { Exit-Error ("contract schema not found: " + $schemaFile) }
if (-not (Test-Path -LiteralPath $registryFile)) { Exit-Error ("code registry not found: " + $registryFile) }
if (-not (Test-Path -LiteralPath $Path)) { Exit-Invalid ("input file not found: " + $Path) }

# --- parse inputs; never echo document content ---
try { $jsonText = Get-Content -Raw -LiteralPath $Path } catch { Exit-Invalid 'input file could not be read' }
try { $doc = $jsonText | ConvertFrom-Json } catch { Exit-Invalid 'input is not valid JSON' }
try { $schemaText = Get-Content -Raw -LiteralPath $schemaFile } catch { Exit-Error 'contract schema could not be read' }
try { $schema = $schemaText | ConvertFrom-Json } catch { Exit-Error 'contract schema is not valid JSON' }
try { $registryText = Get-Content -Raw -LiteralPath $registryFile } catch { Exit-Error 'code registry could not be read' }
try { $registry = $registryText | ConvertFrom-Json } catch { Exit-Error 'code registry is not valid JSON' }

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
if (-not $schemaResult) { Exit-Invalid 'instance does not conform to schema/diagnosis-result.schema.json' }

# --- registry code sets; the registry is the single source of truth ---
$capabilityCodes = @($registry.codes.capability.PSObject.Properties.Name)
$failureCodes = @($registry.codes.failure.PSObject.Properties.Name)
$resolutionCodes = @($registry.codes.resolution.PSObject.Properties.Name)
# evidence[].code must be a diagnosis/failure code only; capability/state codes are represented via capabilities[], not evidence.code

function Test-IsCode([string]$code, [string[]]$allowed) { return ($allowed -contains $code) }

# --- v0.2 semantic invariants (representation consistency only) ---

# 1. schemaVersion
if ($doc.schemaVersion -ne '0.2.0') { Exit-Invalid 'schemaVersion is not 0.2.0' }

# 2. primary diagnosis code, when present, must exist in the diagnosis-code registry
$primary = $doc.diagnosis.code
if (($null -ne $primary) -and (-not (Test-IsCode $primary $failureCodes))) {
    Exit-Invalid 'unknown primary diagnosis code'
}

# 3-5. relatedCodes: registry membership, no primary duplication, no duplicates
$related = @()
if ($null -ne $doc.diagnosis.relatedCodes) { $related = @($doc.diagnosis.relatedCodes) }
foreach ($rc in $related) {
    if (-not (Test-IsCode $rc $failureCodes)) { Exit-Invalid 'unknown related diagnosis code' }
}
if (($null -ne $primary) -and ($related -contains $primary)) {
    Exit-Invalid 'diagnosis.relatedCodes contains primary diagnosis code'
}
if (($related | Select-Object -Unique).Count -ne $related.Count) {
    Exit-Invalid 'diagnosis.relatedCodes contains duplicate codes'
}

# 6-7. capabilities: registry membership and no duplicates
$caps = @()
if ($null -ne $doc.capabilities) { $caps = @($doc.capabilities) }
foreach ($c in $caps) {
    if (-not (Test-IsCode $c $capabilityCodes)) { Exit-Invalid 'unknown capability code' }
}
if (($caps | Select-Object -Unique).Count -ne $caps.Count) { Exit-Invalid 'capabilities contains duplicate codes' }

# 8. resolution strategy must exist in the resolution-strategy registry
if (-not (Test-IsCode $doc.recommendedResolution.strategy $resolutionCodes)) {
    Exit-Invalid 'unknown resolution strategy'
}

# 9. evidence codes, when present, must exist in the diagnosis/failure registry only
foreach ($ev in @($doc.evidence)) {
    $evCode = $ev.code
    if (($null -ne $evCode) -and (-not (Test-IsCode $evCode $failureCodes))) {
        Exit-Invalid 'evidence contains unknown code'
    }
}

# 10. Representation-only rule: reauthRequired=true never causes or synthesizes an
#     INTERACTIVE_AUTH strategy here. The validator checks representation consistency;
#     it does not re-run policy evaluation and never modifies the document.
# 11. When recommendedResolution.strategy is INTERACTIVE_AUTH, the validator does not
#     infer that authentication is safe or authorized. Contract validity only.

Exit-Valid