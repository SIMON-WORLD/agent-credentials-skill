# RFC v0.2 — Agent Credential Layer: Credential Diagnosis (Discover → Diagnose → Resolve)

- Status: Draft for implementation
- Schema version (diagnosis result): `0.2.0`
- Scope: v0.2 core = `Discover -> Diagnose -> Resolve`. No runtime/broker, no plugins, no vault.
- Repository: `agent-credentials-skill`
- Target lifecycle: `Discover -> Diagnose -> Resolve -> Execute -> Verify -> Recover` (v0.2 implements the first three only).

---

## 1. Problem Statement

An agent may execute in a sandbox, container, subprocess, remote runtime, or other isolated context where a **valid** host credential exists but is **not visible or not usable** from that context. Treating every such failure as "credentials are invalid" causes repeated, incorrect re-authentication attempts and user login fatigue.

Two facts must be kept separate:

- **Credential validity**: does the credential itself satisfy the provider (identity, secret, scope)?
- **Execution-context visibility**: can this process read and use the credential (keyring, environment, file, connector)?

Four semantic layers must also be kept separate (see §6.1): **capability/availability**, **diagnostic outcome (status)**, **failure/cause code**, and **recommended resolution**. An observation such as "a platform connector is authenticated" is a positive capability, not a failure.

Failure classes observed in practice:

| Class | Example | Misdiagnosis risk |
|---|---|---|
| Sandbox / keyring | Codex sandbox cannot read the OS keyring that holds the gh token | Reported as "token invalid" by `gh auth status` |
| Environment | Host env var not propagated into the subprocess | Reported as "not logged in" |
| Network | Egress blocked, DNS fails, proxy misconfigured, TLS interception | Reported as "auth failed" |
| Account / host / profile | Valid credential for the wrong account, host, or profile | Reported as "invalid" |
| Scope | Token authenticates but lacks `repo` / `workflow` | Reported as "permission denied" |
| Tool | CLI (`gh`, `twine`) missing or execution denied | Reported as "auth failed" |
| Ambiguity | Validation call times out; result inconclusive | Blindly re-authenticates or locks out |

**Why `gh auth status` failure alone must never imply invalid credentials**: the command fails for keyring-unavailability, network blocking, wrong-host, and tool problems with the same surface symptom. Its result is one **probe** — evidence, not a verdict. Verdicts require isolated probes (context, sources, network, candidate validation) classified by the diagnosis core, and a failed `gh auth status` must never by itself transition to interactive authentication.

---

## 2. Design Principles

1. **Diagnosis before re-authentication.** No adapter, skill instruction, or agent may invoke a login/refresh flow before a diagnosis run has classified the failure. `reauthRequired` is an output of diagnosis + policy, never an input.
2. **Last-resort interactive authentication (provider-neutral).** Interactive authentication is permitted only after diagnosis establishes that **no usable existing credential path remains** and the **non-interactive recovery paths applicable to the provider have been exhausted**. It must remain a last resort. This rule is decided by the provider-neutral core from diagnosis plus the provider's non-interactive recovery options; it is **not** hard-coded as a single failure-code chain such as `CREDENTIAL_INVALID -> refresh failure -> interactive login`.
3. **Credentials by reference where possible, not by value.** The core and adapters pass references (`env:GH_TOKEN`, `file:<path>`, `keyring:github.com`, `connector:<id>`) between layers. Values are materialized only inside a bounded, process-scoped execution step, and only when an adapter needs them.
4. **Process-scoped credential use.** Injected values live only in the environment of the child process performing the operation; they are never written to global config, never persisted, and are cleared after the step.
5. **Raw secrets must not be printed or returned in structured output.** The JSON diagnosis contract has no secret fields. Evidence carries codes, references, booleans, and safe details only. Masking (e.g., `gho_****ZHIy`) applies to any human-readable output.
6. **Provider-neutral core.** The diagnosis core knows failure codes, state codes, source kinds, and policy ordering. GitHub/PyPI/npm/Hugging Face knowledge lives in provider adapters. Nothing in the core is named after a provider.
7. **Fail closed when diagnosis is ambiguous.** `DIAGNOSIS_INCONCLUSIVE`, `AUTH_CHECK_TIMEOUT`, or any probe that cannot run → no action, no re-auth, no credential exposure; return the result and let the policy/skill layer decide escalation.
8. **Runtime-neutral core.** The Diagnosis Core contract — failure taxonomy, result schema, provider adapter contract, and resolution policy — is runtime/language neutral. PowerShell is an **initial reference implementation / adapter path only**, because v0.1 already uses it. A future implementation in another language must be possible without changing the public diagnostic contract. Windows-specific keyring behavior belongs in credential-source/platform adapters, never in the provider-neutral core.
9. **v0.1 remains usable during migration.** Existing `SKILL.md`, `scripts/check.ps1`, `scripts/refresh.ps1`, and `.machine-tokens` storage keep working unchanged. v0.2 is additive.
---

## 3. Architecture

Logical layers (v0.2 implements the first four as code; the last two are explicit seams):

```
+---------------------------------------------------------------+
| Skill / policy layer        SKILL.md, resolution policy table |
+---------------------------------------------------------------+
| Diagnosis core              orchestration, taxonomy, contract |
+-----------------------------+---------------------------------+
| Provider adapters           | Credential source adapters      |
| github / pypi / npm / hf    | env / keyring / connector /    |
|                             | file / broker / interactive     |
+-----------------------------+---------------------------------+
| Future deterministic broker/CLI   (v0.3+ seam, not built)     |
| Ecosystem / plugin adapters       (Codex/Claude/OpenClaw)     |
+---------------------------------------------------------------+
```

- **Skill / policy layer**: human- and agent-readable policy; maps diagnostic outcomes to ordered resolution strategies; decides when a protected file fallback is "explicitly configured" and when interactive login may be offered. (v0.1 `SKILL.md` evolves into this layer.)
- **Diagnosis core**: provider-neutral engine. Enumerates candidate credential sources, runs provider probes, classifies observations into the taxonomy (failure codes vs. state/capability codes), derives the diagnostic `status`, emits the JSON diagnosis result, and applies the resolution policy with fail-closed semantics. **The core contract is language/runtime neutral; PowerShell is only the initial reference implementation.** No PowerShell concept (cmdlets, PSDrive, profiles) may appear in the taxonomy, schema, provider contract, or policy.
- **Provider adapters**: per-provider probes and parsers (see §5). They translate raw outcomes (HTTP status, CLI exit, scope strings) into failure codes, state codes, and evidence.
- **Credential source adapters**: per-source availability checks and reference/value semantics (see §4). Platform-specific behavior (e.g., Windows keyring access, macOS Keychain, Linux secret service) lives **here**, not in the core.
- **Future deterministic broker/CLI**: a standalone executable that runs the diagnosis core and safe execution outside the agent sandbox. v0.2 defines the seam (the core is importable/standalone), does not build it.
- **Ecosystem/plugin adapters**: distribution wrappers (Codex skill, Claude plugin, OpenClaw skill). v0.2 defines only the mapping "skill = policy layer"; no plugin packaging is implemented.

**Data flow (v0.2)**: operation triggers skill → policy layer requests diagnosis → core enumerates sources → provider probes run with timeouts → classification (capabilities + failure codes) → status derived → JSON result emitted → policy resolves (ordered strategy; fail closed if ambiguous) → resolution steps returned (not executed in v0.2 beyond safe reference actions like verify).

---

## 4. Credential Sources

A **CredentialSource** is described by:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | stable identifier (`env`, `cli-keyring`, `platform-connector`, `protected-local-file`, `external-broker`, `interactive`) |
| `availability()` | → `{available, code?, detail?}` | context-aware check (does NOT touch the secret value) |
| `describeReference()` | → `{kind, location}` | a reference, never a value |
| `acquireForProcess(scope)` | → value \| denied | bounded, process-scoped materialization |
| `privacy` | enum | `by-reference` \| `process-scoped` \| `raw-never` |
| `priority` | int | used by resolution ordering (higher = preferred) |

Source kinds (v0.2 minimum set):

| Kind | Example | Reference form | Availability probe | When used |
|---|---|---|---|---|
| `platform-connector` | GitHub connector in Codex/ChatGPT | `connector:<id>` | connector reports an authenticated identity | First when present and authenticated (state code `CONNECTOR_AVAILABLE`) |
| `cli-keyring` | `gh` token in OS keychain | `keyring:<host>` | keyring backend accessible in this context | Second when keyring is reachable |
| `env` | `GH_TOKEN` / `TWINE_PASSWORD` | `env:<NAME>` | variable present in this process env | When host env is propagated |
| `protected-local-file` | `~/.machine-tokens/github_token.txt` | `file:<path>` | file exists and ACL is user-restricted; used only when explicitly configured | Fallback for sandbox where keyring is invisible |
| `external-broker` (future) | secret broker | `broker:<name>/<key>` | broker reachable | Post-v0.2, behind contract |
| `interactive` | `gh auth login` | `interactive:<provider>` | n/a | **Last resort only**, gated by §2 principle 2 and user consent |

Invariant: source adapters never emit values into the diagnosis contract; `describeReference` is the only form that crosses layer boundaries by default. Platform-specific keyring behavior is implemented inside the `cli-keyring` source adapter per platform, never in the core.

---

## 5. Provider Adapter Contract

Language-neutral interface (pseudocode; the contract is not PowerShell-specific and contains no PowerShell concepts):

```
interface ProviderAdapter {
  id: string                      // "github", "pypi", "npm", "huggingface", ...
  defaultHost: string | null

  // enumerate candidate credential references for this provider
  discover(ctx) -> [{sourceId, reference, confidence}]

  // run probes against a reference; classify into failure codes AND state codes
  diagnose(ctx, reference) -> [{observationCode, kind: "failure"|"state", evidence[], identity?, network?, scope?}]

  // choose an ordered resolution from diagnosis + policy
  resolve(ctx, diagnosis, policy) -> ResolutionPlan {
    strategy: string,             // a RESOLUTION_STRATEGY code (see §8)
    steps: [string],              // safe, reference-based steps
    reauthRequired: boolean
  }

  // positive confirmation that a credential works and has required scope
  verify(ctx, reference, requiredScope?) -> {ok, identity?, scopes[]}

  // apply a resolution step; may require user action
  recover(ctx, reference, plan) -> {ok, result?, actionRequired?}
}
```

Contract rules:

- Adapters return **observation codes** (failure or state) as the primary signal; free text is secondary (`detail`).
- Adapters never print or return secrets; `verify` returns identity/scopes, not tokens.
- Adapters never invoke login flows; `recover` may request a user action (e.g., "reissue token with `repo, workflow`") that the policy layer renders.
- Probe results carry `evidence[]` with `{probeType, check, outcome, code?, summary?, reference?}` (vocabulary per §7) and must be JSON-safe; adapters must not transport raw subprocess or provider output into the public result.
- Each adapter defines its validation probe set (e.g., GitHub: `GET /user` + scope assertion; PyPI: token prefix/expiry decode plus optional test-upload check; npm: `npm whoami`; Hugging Face: `GET /api/whoami-v2`).
---

## 6. Failure Taxonomy and State Codes

### 6.1 Semantic layers

The model keeps four layers strictly distinct. A single observation must not be forced into all four roles:

1. **Capability / availability** — what exists and is usable in this context (e.g., `CONNECTOR_AVAILABLE`, keyring reachable, file present). Positive observations are **state codes**, not failures.
2. **Diagnostic outcome (`status`)** — the derived overall state: `healthy` / `degraded` / `unavailable` / `inconclusive` (see §7).
3. **Failure / cause code** — a negative observation that explains why the operation failed (e.g., `SANDBOX_KEYRING_UNAVAILABLE`, `CREDENTIAL_INVALID`).
4. **Recommended resolution** — the chosen strategy code (e.g., `USE_CONNECTOR`, `USE_PROCESS_SCOPED_ENV`, `INTERACTIVE_AUTH`).

`CONNECTOR_AVAILABLE` is a **state/capability code**, not a failure, and must never be treated as a failure by policy or status derivation.

### 6.2 Failure codes

For each: meaning, whether re-authentication is appropriate, and preferred recovery direction (as a resolution strategy code from §8).

| Code | Meaning | Re-authenticate? | Preferred recovery |
|---|---|---|---|
| `CREDENTIAL_NOT_FOUND` | No candidate credential in any enabled source | Only as final fallback (see §6.4) | Configure a source (env/file/connector); if none possible and user consents → `INTERACTIVE_AUTH` |
| `CREDENTIAL_INVALID` | Candidate credential present but provider rejects (401/403) | Conditionally, after refresh fails (see §6.4) | `REFRESH_CREDENTIAL` → re-verify → if still invalid → `INTERACTIVE_AUTH` |
| `CREDENTIAL_SOURCE_UNAVAILABLE` | A configured source cannot be read (ACL, connector offline, file missing) | No | Fix source availability; fall back to another source; `MANUAL_REVIEW` if none |
| `SANDBOX_KEYRING_UNAVAILABLE` | Keyring backend inaccessible from this execution context | **No** | `USE_PROCESS_SCOPED_ENV` or `USE_CONNECTOR`; do not login |
| `ENV_NOT_PROPAGATED` | Env var absent here although expected | No | Propagate env explicitly; read protected file |
| `NETWORK_BLOCKED` | Provider endpoint unreachable due to policy/egress | No | `FIX_NETWORK`; retry after diagnosis |
| `DNS_FAILURE` | Hostname resolution failed | No | `FIX_DNS`; retry |
| `PROXY_MISCONFIGURED` | Proxy env/settings invalid or intercepting | No | `FIX_PROXY` |
| `TOOL_NOT_INSTALLED` | Required CLI missing (`gh`, `twine`, `npm`) | No | `INSTALL_TOOL` (install the tool or use a REST adapter) |
| `TOOL_EXECUTION_UNAVAILABLE` | CLI present but cannot execute in context (subprocess denied) | No | `MANUAL_REVIEW` / `USE_EXTERNAL_BROKER` |
| `WRONG_ACCOUNT` | Credential valid but identity ≠ target account | No | `SELECT_ACCOUNT` (select correct account credential/profile) |
| `WRONG_HOST` | Credential for a different host (e.g., GHE vs github.com) | No | `CORRECT_HOST` |
| `WRONG_PROFILE` | Credential matches account but wrong profile/selection | No | `SELECT_PROFILE` |
| `TOKEN_SCOPE_INSUFFICIENT` | Authenticates but lacks required scope (e.g., `workflow`) | No (re-login won't change scopes) | `REQUEST_ADDITIONAL_SCOPE` with required scopes (user action) |
| `AUTH_CHECK_TIMEOUT` | Validation probe exceeded its time budget | No (inconclusive) | `RETRY_AUTH_CHECK`; escalate to `MANUAL_REVIEW` if repeated |
| `DIAGNOSIS_INCONCLUSIVE` | Evidence insufficient to classify | No — fail closed | `MANUAL_REVIEW` / `RETRY_AUTH_CHECK` |

### 6.3 State / capability codes (non-error)

Kept in the taxonomy for compatibility with the original requested code list, but classified explicitly as **non-error diagnostic/state codes**.

| Code | Meaning | Re-authenticate? | Preferred resolution |
|---|---|---|---|
| `CONNECTOR_AVAILABLE` | An already-authenticated platform connector is usable for this provider | N/A (positive state) | `USE_CONNECTOR` — route the operation through the connector |

Additional state codes may be added by future adapters (e.g., `CREDENTIAL_SOURCE_AVAILABLE`, `KEYRING_AVAILABLE`); the core treats unknown state codes as positive observations until a failure code is produced.

### 6.4 Interactive-authentication policy (provider-neutral)

Interactive authentication is **inappropriate** by default. It becomes available only via the provider-neutral rule in §2 principle 2 (no usable existing credential path remains **and** provider-appropriate non-interactive recovery is exhausted), evaluated by the policy layer with user consent. Classification per code:

| Code | Interactive authentication? | Rationale / resolution |
|---|---|---|
| `CREDENTIAL_NOT_FOUND` | **Potentially required as final fallback** | All sources enumerated and none usable, no connector, no keyring, no env, no configured file, no broker → `INTERACTIVE_AUTH` with user consent |
| `CREDENTIAL_INVALID` | **Conditionally appropriate** | Only after `REFRESH_CREDENTIAL` fails and re-verify still rejects; then last resort |
| `WRONG_ACCOUNT` | **Inappropriate** | Resolution is `SELECT_ACCOUNT`; logging in would authenticate the wrong account again |
| `TOKEN_SCOPE_INSUFFICIENT` | **Inappropriate** | Resolution is `REQUEST_ADDITIONAL_SCOPE` with required scopes; interactive login does not add scopes |
| `SANDBOX_KEYRING_UNAVAILABLE` | **Inappropriate** | Resolution is `USE_PROCESS_SCOPED_ENV` or `USE_CONNECTOR`; the credential is likely valid elsewhere |
| `NETWORK_BLOCKED` | **Inappropriate** | Resolution is `FIX_NETWORK`; interactive login cannot succeed while the network is blocked |

### 6.5 Invariant

`reauthRequired` defaults to `false`. It is set to `true` only when the diagnosis establishes that **no usable existing credential path remains** and the **non-interactive recovery paths applicable to the provider have been exhausted** (for example: `CREDENTIAL_INVALID` after refresh failure and re-verify; or `CREDENTIAL_NOT_FOUND` with all sources enumerated and none usable). Interactive authentication is never triggered by a single failure observation (including a failed `gh auth status`); it is always the output of the full diagnosis + policy evaluation, and always requires user consent.
---

## 7. Diagnosis Result Contract

Stable JSON shape, schema version `0.2.0`. No raw credential values ever appear. The public vocabulary below (status, diagnosis, evidence, executionContext) is aligned with `schema/diagnosis-result.schema.json`; `schema/diagnostic-codes.json` is authoritative for all codes.

```json
{
  "schemaVersion": "0.2.0",
  "provider": "<provider id>",
  "operation": "<push|api|release|publish|...>",
  "status": "healthy | degraded | unavailable | inconclusive",
  "executionContext": {
    "runtime": "<host|sandbox|container|remote|ci|unknown>",
    "runtimeIdentifier": "<safe runtime identifier|null>",
    "platform": "<generic platform identifier|null>",
    "isolation": "<isolation information|null>"
  },
  "availableCredentialSources": ["<sourceId>", "..."],
  "selectedCredentialSource": "<sourceId>" | null,
  "capabilities": ["<STATE_CODE>", "..."],
  "identity": { "account": "...", "host": "...", "profile": "..." } | null,
  "network": {
    "reachable": true | false | null,
    "dnsOk": true | false | null,
    "proxyOk": true | false | null,
    "blocked": true | false | null,
    "tlsOk": true | false | null
  } | null,
  "diagnosis": {
    "code": "<primary failure code|null>",
    "relatedCodes": ["<secondary/related failure code>", "..."],
    "category": "<failure category|null>",
    "conclusive": true,
    "summary": "<human-safe one-liner>"
  },
  "recommendedResolution": {
    "strategy": "<RESOLUTION_STRATEGY code>",
    "steps": ["<safe, reference-based step>", "..."],
    "reauthRequired": false
  },
  "evidence": [
    { "probeType": "<context|command|network|credential-source|identity|provider-api>", "check": "<probe id>", "outcome": "<success|failure|unavailable|timeout|skipped|unknown>", "code": "<failure or state code|null>", "summary": "<sanitized summary>", "reference": "<safe reference|null>" }
  ]
}
```

`status` semantics:

| status | Meaning |
|---|---|
| `healthy` | The requested credential capability is usable in the current execution context |
| `degraded` | A usable credential path exists, but a preferred/default path is unavailable or impaired (e.g., keyring unavailable while connector/file path usable) |
| `unavailable` | No currently usable credential path was established (e.g., `CREDENTIAL_NOT_FOUND`, `CREDENTIAL_INVALID`, or network blocking with no alternative) |
| `inconclusive` | The system cannot safely determine availability (`AUTH_CHECK_TIMEOUT` / `DIAGNOSIS_INCONCLUSIVE`) → fail closed |

Specific failures (invalid credential, wrong account, insufficient scope, network, tool) are expressed in `diagnosis` and the failure taxonomy — never as an additional top-level status.

### Example A — healthy usable credential path

```json
{
  "schemaVersion": "0.2.0",
  "provider": "github",
  "operation": "push",
  "status": "healthy",
  "executionContext": {
    "runtime": "host",
    "runtimeIdentifier": "local-shell",
    "platform": "linux",
    "isolation": null
  },
  "availableCredentialSources": [
    { "type": "platformConnector", "reference": "connector:github-main", "available": true }
  ],
  "selectedCredentialSource": { "type": "platformConnector", "reference": "connector:github-main" },
  "capabilities": ["CONNECTOR_AVAILABLE"],
  "identity": { "account": "alice", "host": "github.com", "profile": "default" },
  "network": { "reachable": true, "dns": true, "proxy": true, "timeout": false, "tls": true },
  "diagnosis": {
    "code": null,
    "conclusive": true,
    "summary": "All probes positive; the requested credential capability is usable."
  },
  "recommendedResolution": {
    "strategy": "USE_CONNECTOR",
    "steps": ["proceed with the operation"],
    "actionRequired": false
  },
  "reauthRequired": false,
  "evidence": [
    { "probeType": "provider-api", "check": "provider.verify", "outcome": "success", "code": null, "summary": "Verification succeeded" }
  ]
}
```

### Example B — valid host GitHub credential, sandbox cannot access the preferred keyring path (degraded)

```json
{
  "schemaVersion": "0.2.0",
  "provider": "github",
  "operation": "push",
  "status": "degraded",
  "executionContext": {
    "runtime": "sandbox",
    "runtimeIdentifier": "codex-sandbox",
    "platform": "windows",
    "isolation": "sandbox"
  },
  "availableCredentialSources": [
    { "type": "environment", "reference": "env:CREDENTIAL_NAME", "available": true },
    { "type": "protectedFile", "reference": "file:/home/user/.credential-store/github", "available": true }
  ],
  "selectedCredentialSource": { "type": "protectedFile", "reference": "file:/home/user/.credential-store/github" },
  "capabilities": [],
  "identity": null,
  "network": { "reachable": true, "dns": true, "proxy": true, "timeout": false, "tls": true },
  "diagnosis": {
    "code": "SANDBOX_KEYRING_UNAVAILABLE",
    "relatedCodes": ["CREDENTIAL_SOURCE_UNAVAILABLE"],
    "category": "execution-context",
    "conclusive": true,
    "confidence": 0.9,
    "summary": "Keyring is not readable in this sandbox; a protected file source is available."
  },
  "recommendedResolution": {
    "strategy": "USE_PROCESS_SCOPED_ENV",
    "steps": ["inject credential reference into the child process", "verify", "execute operation"],
    "actionRequired": false
  },
  "reauthRequired": false,
  "evidence": [
    { "probeType": "context", "check": "execution-context.keyring", "outcome": "unavailable", "code": "SANDBOX_KEYRING_UNAVAILABLE", "summary": "Keyring backend not accessible from sandbox" },
    { "probeType": "network", "check": "network.endpoint", "outcome": "success", "code": null, "summary": "Endpoint reachable" },
    { "probeType": "credential-source", "check": "source.protectedFile", "outcome": "success", "code": null, "summary": "Protected file exists with restricted access" }
  ]
}
```

### Example C — genuinely invalid GitHub credential

```json
{
  "schemaVersion": "0.2.0",
  "provider": "github",
  "operation": "api",
  "status": "unavailable",
  "executionContext": {
    "runtime": "host",
    "runtimeIdentifier": "local-shell",
    "platform": "windows",
    "isolation": null
  },
  "availableCredentialSources": [
    { "type": "cliKeyring", "reference": "keyring:github.com", "available": true },
    { "type": "protectedFile", "reference": "file:/home/user/.credential-store/github", "available": true }
  ],
  "selectedCredentialSource": { "type": "cliKeyring", "reference": "keyring:github.com" },
  "capabilities": [],
  "identity": null,
  "network": { "reachable": true, "dns": true, "proxy": true, "timeout": false, "tls": true },
  "diagnosis": {
    "code": "CREDENTIAL_INVALID",
    "category": "credential",
    "conclusive": true,
    "summary": "The candidate credential was rejected by GitHub (401); network and keyring are normal."
  },
  "recommendedResolution": {
    "strategy": "REFRESH_CREDENTIAL",
    "steps": [
      "re-register the credential from a configured source",
      "re-verify",
      "if still rejected: INTERACTIVE_AUTH with user consent as final fallback"
    ],
    "actionRequired": false
  },
  "reauthRequired": true,
  "evidence": [
    { "probeType": "provider-api", "check": "provider.verify", "outcome": "failure", "code": "CREDENTIAL_INVALID", "summary": "Candidate credential rejected" },
    { "probeType": "network", "check": "network.endpoint", "outcome": "success", "code": null, "summary": "Endpoint reachable" },
    { "probeType": "context", "check": "execution-context.keyring", "outcome": "success", "code": null, "summary": "Keyring accessible" }
  ]
}
```

### Example D — no credential found (unavailable)

```json
{
  "schemaVersion": "0.2.0",
  "provider": "github",
  "operation": "push",
  "status": "unavailable",
  "executionContext": {
    "runtime": "unknown"
  },
  "availableCredentialSources": [],
  "selectedCredentialSource": null,
  "capabilities": [],
  "identity": null,
  "network": null,
  "diagnosis": {
    "code": "CREDENTIAL_NOT_FOUND",
    "conclusive": true,
    "summary": "No credential source is available in this context."
  },
  "recommendedResolution": {
    "strategy": "MANUAL_REVIEW",
    "steps": ["configure a credential source", "re-diagnose"],
    "actionRequired": true
  },
  "reauthRequired": false,
  "evidence": [
    { "probeType": "credential-source", "check": "source.enumeration", "outcome": "failure", "code": "CREDENTIAL_NOT_FOUND", "summary": "No source found" }
  ]
}
```
Contract rules: `identity` is set only after a positive probe; evidence is structured and sanitized — `summary` and `reference` never contain credential values, and adapters must not transport raw subprocess or provider output into the public result; `recommendedResolution.steps` contain references, not credential values; `capabilities` lists state codes only; `diagnosis.code` is the authoritative primary diagnosis and is `null` when there is no failure; `relatedCodes` are optional secondary codes from the same diagnosis registry and must not repeat the primary code.
---

## 8. Resolution Policy

Resolution strategies are machine-readable codes (used in `recommendedResolution.strategy`):

| Strategy code | Meaning |
|---|---|
| `USE_CONNECTOR` | Route through an already-authenticated platform connector |
| `USE_EXISTING_CLI_AUTH` | Use the accessible authenticated CLI/keyring path |
| `USE_PROCESS_SCOPED_ENV` | Materialize a reference (`env:`/`file:`) into the child-process environment for the operation only |
| `USE_PROTECTED_FILE` | Protected-file fallback, only when explicitly configured |
| `FIX_NETWORK` | Repair network/DNS/proxy, then re-diagnose |
| `SELECT_ACCOUNT` / `CORRECT_HOST` / `SELECT_PROFILE` | Select the correct account/host/profile credential |
| `REQUEST_ADDITIONAL_SCOPE` | Reissue a token with required scopes (user action) |
| `REFRESH_CREDENTIAL` | Re-register the existing credential (e.g., gh re-registration from a file source) |
| `INTERACTIVE_AUTH` | Interactive authentication, only via §2 principle 2 and user consent |
| `NO_ACTION` | Fail closed; report evidence, take no action |

Ordered default strategy:

1. `USE_CONNECTOR` — when `CONNECTOR_AVAILABLE` and the operation can use it.
2. `USE_EXISTING_CLI_AUTH` — when keyring is reachable in this context.
3. `USE_PROCESS_SCOPED_ENV` — from `env:`/`file:` references, process-scoped.
4. `USE_PROTECTED_FILE` — only if the user explicitly enabled it for this provider; never silently reads arbitrary files.
5. `INTERACTIVE_AUTH` — only when §6.4/§6.5 conditions hold (no usable existing path remains, non-interactive recovery exhausted, user consent).

Provider policy may differ and is expressed as a per-provider strategy table inside the adapter:

| Provider | Preferred order (non-interactive first) |
|---|---|
| GitHub | `USE_CONNECTOR` → `USE_EXISTING_CLI_AUTH` → `USE_PROCESS_SCOPED_ENV` → `USE_PROTECTED_FILE` → `INTERACTIVE_AUTH` |
| PyPI | `USE_PROCESS_SCOPED_ENV` (env) → `USE_PROTECTED_FILE` (`.pypirc`) → `INTERACTIVE_AUTH` |
| npm | `USE_PROCESS_SCOPED_ENV` (env) → `USE_PROTECTED_FILE` (`.npmrc`) → `INTERACTIVE_AUTH` |
| Hugging Face | `USE_PROCESS_SCOPED_ENV` (env) → `USE_PROTECTED_FILE` → `INTERACTIVE_AUTH` |

Fail-closed rule: if `status` is `inconclusive` (primary code `DIAGNOSIS_INCONCLUSIVE` or `AUTH_CHECK_TIMEOUT`), or any probe errored without a code, the resolution is `NO_ACTION` and `reauthRequired=false`.

---

## 9. GitHub Reference Flow

Trigger: `gh auth status` fails (or any GitHub operation fails).

**Invariant: `gh auth status` is evidence, not verdict.** A failed `gh auth status` must never, by itself, transition to interactive authentication. It only starts the diagnosis flow below.

1. **Context probe**: runtime type, `keyringAccessible`, `envPropagated`, `toolAvailable: gh`.
2. **Source enumeration**: `cli-keyring`, `platform-connector`, `env:GH_TOKEN`, `protected-local-file` → references only.
3. **Network probe**: DNS for `api.github.com`, HTTPS reachability, proxy check, TLS result.
4. **Candidate validation**: for each reference, `GET https://api.github.com/user` with a bounded timeout; classify `200` (→ identity/scope assertion), `401/403` (→ `CREDENTIAL_INVALID`), timeout (→ `AUTH_CHECK_TIMEOUT`).

Branching table (resolution uses strategy codes from §8):

| Observed | Primary code | status | Re-auth? | Resolution |
|---|---|---|---|---|
| keyring inaccessible in sandbox; network OK; file/env reference present and validates 200 | `SANDBOX_KEYRING_UNAVAILABLE` | `degraded` | No | `USE_PROCESS_SCOPED_ENV` → verify → push |
| keyring inaccessible but authenticated connector present | `SANDBOX_KEYRING_UNAVAILABLE` + `CONNECTOR_AVAILABLE` (state) | `degraded` | No | `USE_CONNECTOR` |
| network unreachable / DNS fail / proxy misconfigured | `NETWORK_BLOCKED` / `DNS_FAILURE` / `PROXY_MISCONFIGURED` | `unavailable` | No | `FIX_NETWORK` → re-diagnose |
| candidate validates 200 but identity ≠ target account | `WRONG_ACCOUNT` | `unavailable` | No | `SELECT_ACCOUNT` |
| candidate validates 200 but scope missing (`repo`/`workflow`) | `TOKEN_SCOPE_INSUFFICIENT` | `unavailable` | No | `REQUEST_ADDITIONAL_SCOPE` (user action) |
| keyring OK + network OK + candidate 401 | `CREDENTIAL_INVALID` | `unavailable` | Conditionally (after refresh fails) | `REFRESH_CREDENTIAL` → re-verify → `INTERACTIVE_AUTH` only if still 401 |
| no credential in any source | `CREDENTIAL_NOT_FOUND` | `unavailable` | Potentially required as final fallback | Configure a source; else `INTERACTIVE_AUTH` with user consent |
| any probe timeout or unknown outcome | `AUTH_CHECK_TIMEOUT` / `DIAGNOSIS_INCONCLUSIVE` | `inconclusive` | No | `NO_ACTION` (fail closed); return evidence |

Flow:

```
gh auth status fails
   └─ diagnosis core
        ├─ context probe ──────────────── keyringAccessible? runtime?
        ├─ source enumeration ─────────── references only
        ├─ network probe ──────────────── DNS/HTTPS/proxy/TLS
        └─ candidate validation ───────── REST /user (timeout-bounded)
             └─ classify → state codes + failure codes → status → JSON result
                  └─ policy resolution (fail closed; interactive only as last resort)
```

The REST validation isolates credential validity from CLI/keyring/tool failures, which is why `gh auth status` failure alone is never a verdict and never triggers interactive login by itself.
---

## 10. Compatibility / Migration

v0.1 behavior remains usable during the v0.2 migration; v0.2 is strictly additive.

| v0.1 artifact | v0.2 relationship |
|---|---|
| `SKILL.md` | Becomes the policy layer. v0.2 adds a "Diagnosis" section and failure-code reference; existing instructions (injection, git push fallback, refresh) remain authoritative and unchanged. |
| `scripts/check.ps1` | Keeps exit codes `0/1/2` and current output. v0.2 adds a `-Json` mode emitting the diagnosis contract and maps old outcomes to failure codes; old invocations behave identically. |
| `scripts/refresh.ps1` | Semantics unchanged. v0.2 flows only invoke refresh when `reauthRequired=true` (diagnosis-gated); refresh itself gains a pre-check that requires a diagnosis result. |
| `.machine-tokens` storage | Remains the `protected-local-file` source; file format and paths unchanged. |

Migration rules: no existing file is rewritten in v0.2; new modules/adapters/tests are added alongside; both entry points (v0.1 scripts and v0.2 diagnosis) are usable during the transition; release/versioning follows tags.

---

## 11. Non-goals for v0.2

- Building a full secrets manager / vault.
- Storing arbitrary application secrets.
- Encryption or keychain implementation.
- Codex/Claude/OpenClaw plugin packaging.
- GUI.
- Automatic credential rotation.
- Broad provider support before the contract is proven (only GitHub reference flow is fully specified; PyPI/npm/HF adapters come after contract validation).

---

## 12. Proposed Implementation Sequence

Each step is independently testable; no large rewrites. The contract (taxonomy, schema, provider contract, policy) is language-neutral; PowerShell is used only for the reference implementation because v0.1 already uses it.

1. Add the failure/state taxonomy module (constants + meaning/recovery metadata, incl. the state-code class) with unit tests over all 16 failure codes and the `CONNECTOR_AVAILABLE` state code.
2. Add the execution-context probe (runtime, keyring accessibility, env propagation, tool availability) returning structured facts.
3. Add credential-source adapters (env, protected-local-file, cli-keyring, platform-connector stub) returning references only, with availability checks. Windows keyring specifics live in the `cli-keyring` adapter.
4. Add the GitHub provider adapter: REST probes with bounded timeouts mapping to codes (401/403/timeout/identity/scope).
5. Implement the diagnosis core orchestrator: enumerate → probe → classify → derive `status` → emit JSON `0.2.0`; ship Examples A–D as fixture tests. The orchestrator contains no PowerShell-specific constructs.
6. Implement the resolution policy engine (ordered strategies + fail-closed rule + §6.4/§6.5 interactive gate) with per-provider strategy tables (GitHub first).
7. Add the PowerShell reference CLI entry point (`diagnose.ps1 -Provider github [-Json]`) with `-Json` output and masked human output; keep v0.1 `check.ps1` untouched. Note in code comments that this is a reference implementation of a language-neutral contract.
8. Migration tests: run v0.1 `check.ps1`/`refresh.ps1` unchanged (backward compatibility), and map their exit codes to diagnosis codes.
9. Document the contract in `SKILL.md` (additive "Diagnosis" section) and finalize the provider adapter template for the next provider.
10. Tag v0.2.0 and publish a Release after user confirmation; then add the PyPI adapter as contract validation step.

---

## Open Design Questions (to resolve during implementation)

- Platform-connector probe APIs differ per runtime (Codex/Claude/OpenClaw); v0.2 uses an availability+identity-assertion abstraction; concrete connector adapters land with ecosystem work.
- Reference-implementation language: PowerShell is the **initial reference implementation** for v0.2 (consistent with v0.1); the future broker/CLI language is undecided. The public contract must not change when that language is chosen.
- Keyring accessibility probing depends on platform and gh version; needs calibration on real machines during step 2, inside the `cli-keyring` source adapter.
- Network probe thresholds (timeout budgets, proxy/TLS detection) need calibration against CI and corporate-network false positives.
- Per-provider identity/scope assertion endpoints differ (GitHub `/user`+scopes; PyPI has no whoami — token prefix/expiry decode plus optional test-upload; npm `whoami`; HF `whoami-v2`); each adapter defines its own in step 9+.
- Status derivation rules (e.g., when `degraded` vs `unavailable` with multiple codes) need a small decision table in the core; the four examples fix the main cases.