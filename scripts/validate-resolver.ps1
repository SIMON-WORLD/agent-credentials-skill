<#
.SYNOPSIS
  Reference contract validator for the Agent Credential Layer v0.5 Credential Resolver.
.DESCRIPTION
  Reads schema/credential-resolver.schema.json (resolved relative to this script's own location)
  and validates a supplied resolver document: full JSON Schema validation when compatible support
  is available, plus the v0.5 cross-field semantic invariants. A document is either a public-safe
  ResolverDescriptor (capability metadata) or a public-safe ResolverOutcome (sanitized outcome
  metadata only). The runtime-private CredentialMaterial is intentionally absent from every public
  shape. Developer/conformance tooling only. Never reads credential files or environment variables,
  never inspects keychains, and never executes provider/network/auth/policy operations.
.PARAMETER Path
  Path to the Credential Resolver descriptor or outcome JSON document to validate.
.EXAMPLE
  .\scripts\validate-resolver.ps1 -Path .\fixtures\v0.5\valid\resolver-descriptor-env.json
.EXAMPLE
  .\scripts\validate-resolver.ps1 -Path .\fixtures\v0.5\valid\resolver-outcome-resolved.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Path $scriptRoot -Parent
$schemaFile = Join-Path $repoRoot 'schema\credential-resolver.schema.json'
$registryFile = Join-Path $repoRoot 'schema\diagnostic-codes.json'

# Exit codes: 0 = valid document; 1 = invalid input/instance; 2 = validator/tooling error.
function Exit-Valid { Write-Output 'VALID: Agent Credential Layer credential resolver v0.5.0'; exit 0 }
function Exit-Invalid([string]$message) { Write-Output ('INVALID: ' + $message); exit 1 }
function Exit-Error([string]$message) { Write-Output ('ERROR: ' + $message); exit 2 }

$resolverSpecificCode = 'RESOLVER_ERROR'

if (-not (Test-Path -LiteralPath $schemaFile)) { Exit-Error ("resolver schema not found: " + $schemaFile) }
if (-not (Test-Path -LiteralPath $registryFile)) { Exit-Error ("code registry not found: " + $registryFile) }
if (-not (Test-Path -LiteralPath $Path)) { Exit-Invalid ("input file not found: " + $Path) }

try { $jsonText = Get-Content -Raw -LiteralPath $Path } catch { Exit-Invalid 'input file could not be read' }
try { $doc = $jsonText | ConvertFrom-Json } catch { Exit-Invalid 'input is not valid JSON' }
try { $schemaText = Get-Content -Raw -LiteralPath $schemaFile } catch { Exit-Error 'resolver schema could not be read' }
try { $schema = $schemaText | ConvertFrom-Json } catch { Exit-Error 'resolver schema is not valid JSON' }
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
if (-not $schemaResult) { Exit-Invalid 'instance does not conform to schema/credential-resolver.schema.json' }

# --- v0.5 semantic invariants (representation consistency only) ---

if ($doc.contractVersion -ne '0.5.0') { Exit-Invalid 'contractVersion is not 0.5.0' }

# Resolve failure-code vocabulary from the v0.2 registry (no hard-coded manual list).
$failureCodes = @($registry.codes.failure.PSObject.Properties.Name)
$allowedReasonCodes = @($failureCodes) + @($resolverSpecificCode)

$isOutcome = ($null -ne $doc.PSObject.Properties['outcome'])
$isDescriptor = ($null -ne $doc.PSObject.Properties['resolverType'])

if ($isOutcome -and $isDescriptor) {
    Exit-Invalid 'document is both a resolver descriptor and a resolver outcome; must be exactly one'
}

if ($isOutcome) {
    if ($null -ne $doc.reasonCode -and -not [string]::IsNullOrEmpty($doc.reasonCode)) {
        if ($allowedReasonCodes -notcontains $doc.reasonCode) {
            Exit-Invalid ('reasonCode is not an allowed v0.2 failure code or ' + $resolverSpecificCode + ': ' + $doc.reasonCode)
        }
    }
}
elseif ($isDescriptor) {
    if (@($doc.supportedSourceTypes).Count -eq 0) { Exit-Invalid 'resolver descriptor must declare at least one supportedSourceTypes' }
    if (@($doc.capabilities).Count -eq 0) { Exit-Invalid 'resolver descriptor must declare at least one capability' }
}
else {
    Exit-Invalid 'document is neither a resolver descriptor nor a resolver outcome'
}

# --- no raw secret-bearing values are accepted (deterministic scan; field names are already
#     rejected by the schema propertyNames/additionalProperties guards). The secret is never echoed. ---
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
    if ($jsonText -match $pat) { Exit-Invalid 'input contains a secret-bearing value pattern' }
}

Exit-Valid
