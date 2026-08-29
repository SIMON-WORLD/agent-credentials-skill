# Provider Adapter Contract v0.2

- Status: accepted architecture contract (implementation-level)
- Contract version: `0.2.0`
- Repository: `agent-credentials-skill`
- Related artifacts:
  - Architecture: `docs/rfc-v0.2-credential-diagnosis.md`
  - Public result contract: `schema/diagnosis-result.schema.json`
  - Public code registry: `schema/diagnostic-codes.json`
  - Reference validator: `scripts/validate-contract.ps1`
  - Conformance fixtures: `fixtures/v0.2/`

## Important design rule

There is exactly one public result protocol: **Diagnosis Result v0.2** (defined by
`schema/diagnosis-result.schema.json` and `schema/diagnostic-codes.json`). This document
describes how provider adapters feed that protocol. It introduces no second status enum,
no second diagnosis enum, no second resolution enum, and no second credential result schema.
Provider-specific behavior stays behind the adapter boundary.

---

## 1. Purpose and Boundary

A **provider adapter** is the provider-specific probing and normalization layer of the Agent
Credential Layer. It translates provider state (CLI behavior, HTTP outcomes, configuration,
identity claims) into **normalized, sanitized observations** that the provider-neutral
diagnosis core consumes.

A provider adapter is **not**:

- a credential vault or secret store;
- a plugin or distribution package;
- a full policy engine (it reports options; it does not decide final policy);
- a second Diagnosis Result format;
- an interactive login UI.

A provider adapter must **never redefine public protocol enums**: status, diagnosis/failure
codes, capability/state codes, or resolution strategy codes all come from the accepted
registry and schema.

---

## 2. Inputs

Safe conceptual inputs available to an adapter:

| Input | Meaning |
|---|---|
| `provider` | Provider identifier (for example `github`, `pypi`, `npm`, `huggingface`). |
| `operation` | Requested operation/capability (for example `push`, `api`, `release`, `publish`, `auth-check`). |
| `executionContext` | Runtime kind and safe context metadata (runtime, optional runtimeIdentifier, platform, isolation). |
| `credentialSourceReferences` | Optional references to candidate sources; never values. |
| `expectedIdentity` | Optional expected account/profile/host binding. |
| `policyMetadata` | Policy/config metadata the adapter may use to shape its probes (for example required scope). |

Raw credentials are **not** required as inputs across the LLM-facing interface. If a lower
execution layer needs a raw secret, it obtains it **by reference at execution time**, inside
a process-scoped step, and it is kept outside public diagnostic output.

---

## 3. Discover

Discovery answers: what exists in this execution context?

Examples:

- Is the provider CLI installed?
- Is a platform connector advertised/authenticated?
- Do configured credential references exist?
- Is provider-specific configuration present?
- Is an expected account/profile binding present?

Discovery returns **references and availability**, not validity. A source existing does not
mean the credential is valid. Discovery never calls interactive login.

---

## 4. Diagnose / Probe

Provider-specific probes produce normalized, sanitized observations. Probe categories:

- identity verification;
- auth check (credential accepted or rejected);
- scope/permission check;
- host check;
- provider endpoint reachability.

Preserved invariant:

> provider command failure != credential invalidity.

For the future GitHub adapter: `gh auth status` remains **evidence, not verdict**. Its
failure may reflect keyring visibility, network, tooling, or scope — the diagnosis core
classifies it, never the adapter alone.

Probes are read-only whenever possible and must not mutate unrelated provider/global state.

---

## 5. Resolve

Adapters may report which resolution options/capabilities apply (for example "a protected
file source is available", "a connector is usable"). The **provider-neutral policy layer**
chooses the final `recommendedResolution.strategy` from the accepted resolution registry,
unless a future architecture explicitly delegates that policy.

No provider may automatically trigger interactive authentication from a single probe
failure. Interactive authentication remains a last-resort policy outcome that requires
diagnosis, exhaustion of non-interactive paths, and user consent.

---

## 6. Verify

Post-resolution verification answers:

- is the required capability now usable?
- which identity is active?
- does the required scope/permission exist?
- is the selected host/profile correct?

Verification produces sanitized observations and ultimately a normal Diagnosis Result
(`status`, `capabilities`, `diagnosis`, `evidence`). It never returns credential values.

---

## 7. Recover

Recovery covers provider-specific mechanisms that may be invoked **only when selected by
policy**. Conceptual examples:

- refresh credential;
- select account;
- request additional scope;
- retry provider check (`RETRY_AUTH_CHECK`).

Interactive authentication remains last-resort and user-consented. Recovery effects are
process-scoped and reversible where practical; global credential mutation requires explicit
policy selection.

---

## 8. Adapter Output

Adapters communicate with the diagnosis core through a small **internal observation shape**.
This is a conceptual contract, **not** a new public JSON Schema file. It is capable of
representing:

- probe type;
- check name;
- outcome;
- safe code where appropriate;
- sanitized summary;
- safe reference;
- safe metadata;
- identity observations;
- source observations;
- network observations.

Conceptual shape:

```text
{
  "probeType": "<identity|auth|scope|host|network|tool|source|context>",
  "check": "<probe identifier>",
  "outcome": "<success|failure|unavailable|timeout|skipped|unknown>",
  "code": "<existing diagnosis/failure code|null>",
  "summary": "<sanitized summary>",
  "reference": "<safe credential reference|null>",
  "metadata": { "<safe provider-specific metadata>" },
  "identity": { "account": "<...>", "host": "<...>", "profile": "<...>" } | null,
  "source": { "type": "<source type>", "reference": "<source reference>", "available": true } | null,
  "network": { "reachable": ..., "dns": ..., "proxy": ..., "timeout": ..., "tls": ... } | null
}
```

`code`, when present, must be an existing **diagnosis/failure** registry code. Capability/state
codes (for example `CONNECTOR_AVAILABLE`) are expressed through the Diagnosis Result
`capabilities[]`, never through `evidence[].code`.

The final externally consumable result is **Diagnosis Result v0.2**, not this internal
adapter observation shape. The diagnosis core transforms observations into the public
result.
---

## 9. Error / Failure Mapping

Adapters map raw outcomes to **existing** generic diagnosis codes. Context and corroborating
evidence matter; the contract does not require one HTTP status to always equal one diagnosis.

Conceptual mappings (illustrative, not exhaustive):

| Raw observation | Corroborating context | Existing diagnosis code |
|---|---|---|
| HTTP 401 / 403 on credential use | Network and keyring verified normal | `CREDENTIAL_INVALID` |
| Authenticates but required scope missing | Scope assertion against operation | `TOKEN_SCOPE_INSUFFICIENT` |
| Provider CLI missing | Execution context probe | `TOOL_NOT_INSTALLED` |
| Validation probe exceeded time budget | Network otherwise reachable | `AUTH_CHECK_TIMEOUT` |
| Valid credential, identity mismatch | Expected identity binding | `WRONG_ACCOUNT` |
| Valid credential, different host | Expected host binding | `WRONG_HOST` |

Adapters do not invent provider-specific public codes. If a raw outcome cannot be classified
confidently, the adapter reports an inconclusive observation and lets the core decide
(`DIAGNOSIS_INCONCLUSIVE` / fail closed).

---

## 10. Credential Source Interaction

Adapters refer to sources by **reference**, never by value. Conceptual reference forms:

- `connector/default`
- `cli/github.com`
- `env/GH_TOKEN`
- `file/github/personal`
- `broker/github/work`

Public structures carry references and metadata only. State explicitly:

> credentials by reference, not by value.

Values are materialized only inside a bounded, process-scoped execution step, and never
appear in public diagnostic output.

---

## 11. Identity and Profile Semantics

Generic concepts, kept separate:

- `account` — the identity that owns the credential;
- `profile` — a named selection/binding (for example personal vs work) within or across contexts;
- `host` — the endpoint/host the credential targets (for example github.com or an enterprise host).

> account != profile != host.

Future multi-account and per-project bindings must be representable (for example account A
for project X, account B for project Y). The contract does **not** introduce GitHub-specific
global account switching as a core mechanism; switching is a policy-selected resolution
(`SELECT_ACCOUNT` / `SELECT_PROFILE` / `CORRECT_HOST`), not an adapter default.

---

## 12. Security Invariants

- No raw secrets in public diagnostic structures.
- No raw subprocess stdout/stderr propagation into public output.
- Sanitized evidence by construction.
- No automatic interactive login.
- No global credential mutation unless explicitly selected by policy.
- Prefer process-scoped effects.
- Adapters must not mutate unrelated provider/global state during diagnosis.
- Diagnosis probes should be read-only whenever possible.

---

## 13. Runtime Neutrality

The contract is implementable in PowerShell, Node.js, Python, Rust, or other runtimes.

It does not require:

- PowerShell;
- Windows;
- `gh` or any provider CLI;
- Credential Manager or a specific OS keychain;
- Codex, Claude, or OpenClaw.

Windows-specific keyring behavior, where it exists, belongs in credential-source/platform
adapters, not in this provider contract.

---

## 14. Reference Provider Mapping Table

Illustrative only — no commands are implemented here. The table shows the same generic
adapter operations mapping to different providers, proving the contract is broader than
GitHub.

| Adapter operation | GitHub | PyPI | npm | Hugging Face |
|---|---|---|---|---|
| `discover` | gh installed? connector advertised? configured refs? | twine/uv installed? `.pypirc` or env reference? | npm installed? `.npmrc` or env reference? | CLI or env reference present? |
| `diagnose` | identity + auth + scope + host probes | token prefix/expiry decode + upload endpoint check | `npm whoami`-style identity probe | `whoami-v2`-style identity probe |
| `resolve` | report connector/keyring/file options | report env/file options | report env/file options | report env/file options |
| `verify` | confirm identity, scope, host | confirm identity and upload capability | confirm identity and publish scope | confirm identity and write scope |
| `recover` | refresh credential, select account, request scope | refresh credential, request upload scope | refresh credential, request publish scope | refresh credential, request write scope |

All probes normalize into the same internal observation shape (§8); the core emits the same
Diagnosis Result v0.2.

---

## 15. Conformance Requirements

An adapter is v0.2-conformant only if:

- it uses accepted protocol codes from `schema/diagnostic-codes.json`;
- it does not invent provider-specific public result codes;
- its output can be transformed into a valid Diagnosis Result;
- valid final results pass `scripts/validate-contract.ps1`;
- contract fixtures remain valid/invalid as expected (`fixtures/v0.2/`);
- no secret values enter public output;
- runtime/provider-specific observations remain behind adapter boundaries.

---

## 16. Non-goals

- Full secret storage.
- Encryption or keychain implementation.
- Plugin packaging.
- Provider implementation (GitHub/PyPI/npm/Hugging Face adapters come later).
- Automatic token rotation.
- Interactive authentication UI.
- Broad provider support within this task.