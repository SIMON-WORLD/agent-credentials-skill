# RFC v0.5 — Agent Credential Layer: Credential Resolver (Reference → Material)

- Status: Implemented / Release candidate
- Contract version: `0.5.0` (resolver layer); `v0.2` Diagnosis Result, `v0.3` Credential Context, and `v0.4` Credential ExecutionPlan/`v0.4.0` remain unchanged
- Scope: `v0.5 core = Credential Resolver`. Freeze the architecture and trust boundary for resolving an already-selected logical `CredentialReference` into runtime-private, ephemeral `CredentialMaterial`. Runtime/resolver reference implementation now lives in `scripts/core/resolver.ps1`.
- Repository: `agent-credentials-skill`
- Baseline: released `origin/main = 3a26a67fdca2916a092adeab36ae0a34df4b4938` (`v0.4.0`)

---

## 1. Problem Statement

`v0.4` selected a logical `CredentialReference` and gated execution (`ready | blocked | needs_decision`). But the actual step from
**logical reference** → **runtime credential value** was only an ad-hoc caller-supplied PowerShell `[scriptblock]` passed to
`Invoke-AgentCredentialScopedCommand` (`-CredentialResolver` in `scripts/broker.ps1`). That seam has no contract: no descriptor, no
request shape, no outcome type, no lifetime/disposal rules, and it is the only place a raw credential value may appear.

`v0.5` freezes that seam. It does **not** change credential selection (already done), does **not** re-run diagnosis, and does **not**
add provider-specific behavior to Core.

---

## 2. Design Principles

1. **The ExecutionPlan-selected reference is authoritative.** A resolver never selects; it resolves that one reference or fails.
2. **Raw material is runtime-private.** It exists only transiently inside an execution scope and is never serialized, logged,
   persisted, cached, or returned through any public result.
3. **Reference-in, material-out, metadata-only in public output.** Public shapes carry logical references and safe outcome metadata.
4. **Provider-neutral Core.** Resolver selection/capability matching is generic; provider/source knowledge lives in resolvers.
5. **Reuse v0.2 vocabulary where it matches.** The resolver uses `v0.2` diagnostic codes as the canonical failure reason vocabulary
   wherever a one-to-one semantic exists; introduce a single resolver-specific code only where `v0.2` has no equivalent.
6. **Fail closed.** Zero/multiple/incompatible resolvers never silently pick one; no array-order authority.
7. **Runtime-neutral contract.** `PowerShell [scriptblock]` is a reference binding, not the protocol. A Python/Node/Rust/Go
   implementation must be possible without changing the public resolver contract.
8. **`.machine-tokens` is a reference convention, not protocol.** File layout/profile conventions never become a portable contract.

---

## 3. Layer A — CredentialReference (unchanged)

The public logical identity produced by `v0.3` (`schema/credential-context.schema.json`, `CredentialReference`, contractVersion `0.3.0`).
Fields: `provider`, `sourceType`, `reference`, optional `account`, `profile`, `host`. Never a raw value.

`v0.5` does **not** change this layer; a resolver consumes it verbatim.

---

## 4. Layer B — ResolverDescriptor / ResolverCapability

Public-safe metadata describing **what a resolver can handle**. No credential values.

Minimum fields:

| Field | Type | Meaning |
|---|---|---|
| `resolverId` | string | Stable resolver identifier (e.g. `env`, `file`, `keyring`, `cli-session`, `connector`, `external-broker`, plus a provider-qualified form when needed) |
| `resolverType` | enum | Family classification (see 安全 §9) |
| `supportedProviders` | string[] | Provider namespaces this resolver can serve (empty = provider-agnostic) |
| `supportedSourceTypes` | enum[] | `env`, `file`, `keyring`, `connector`, `cli`, `broker`, `profile`, `config`, `other` |
| `supportedHosts` | string[] | Optional host constraints (empty = any host) |
| `supportedProfiles` | string[] | Optional profile constraints (empty = any profile) |
| `capabilities` | string[] | Safe operation/capability tokens (e.g. `resolve`) |
| `runtimeRequirements` | object | Safe, non-secret runtime hints (e.g. `powershell`, `node`, `os-keyring`) |

Invariants:

- Never contains a credential value.
- `sourceType`/`provider` matching is explicit; an empty field means "no constraint", never "any secret".

---

## 5. Layer C — Resolve Request

Runtime-neutral logical request containing **only** the information needed to resolve the already-selected reference.

```json
{
  "contractVersion": "0.5.0",
  "resolverId": "env",
  "reference": {
    "provider": "github",
    "sourceType": "env",
    "reference": "env/GH_TOKEN",
    "account": null,
    "profile": null,
    "host": "github.com"
  },
  "operation": "push",
  "hint": { "expectedHost": "github.com", "expectedAccount": null }
}
```

Rules:

- A resolve request is derived from a **single selected** `CredentialReference`; the resolver MUST NOT perform a second credential
  selection, must not fall back, must not relax host/profile/account constraints, and must not choose a different reference.
- `hint` is optional and safe (expected host/profile/account), used only for context; it never changes the reference authority.
- No raw value, no keyring path, no env content, no provider command, no agent-visible secret enters a request.

---

## 6. Layer D — Runtime-private CredentialMaterial

**This is NOT a public JSON result.** It is a runtime-private object produced transiently by a resolver.

Defined properties (conceptual):

| Property | Meaning |
|---|---|
| `material` | The raw value (or a strongly-typed handle to it) |
| `kind` | How the value is delivered (e.g. `value`, `file-path`, `token-handle`) |
| `target` | Intended injection/use target (e.g. an environment-variable name, a header, a file reference) |
| `lifetime` | Bounded valid lifetime; after expiry the material is unusable |
| `dispose` | Cleanup/disposal responsibility (see below) |

Explicitly forbidden:

- Public serialization (never serialized into any public result).
- Logging.
- Persistence/cache.
- Returning through `ExecutionPlan` or `Broker` result.
- Storing in agent-visible state.

Cleanup/disposal responsibility:

- The resolver that produced the material is responsible for disposing any backing resource.
- The executing runtime is responsible for clearing it from the child environment and discarding the local copy after the operation,
  including failure/timeout paths.
- The material never outlives its bounded lifetime or the single operation it was produced for.

---

## 7. Layer E — Public Resolver Outcome

Sanitized resolver outcome **metadata only**. No raw material, no arbitrary resolver exception text.

```json
{
  "contractVersion": "0.5.0",
  "resolverId": "env",
  "outcome": "resolved",
  "reasonCode": null,
  "materialKind": "value",
  "target": "GH_TOKEN",
  "lifetimeSeconds": 300
}
```

Typed state model:

- `resolved` — material was produced and is under the caller's bounded control.
- `unavailable` — source present but material not currently available.
- `failed` — resolver could not produce material.

Public outcome NEVER exposes raw material, filesystem/keyring paths, command stdout/stderr, or arbitrary exception text.

---

## 8. Failure Semantics (typed reason vocabulary)

The resolver borrows the `v0.2` diagnostic-code vocabulary as its canonical reason vocabulary wherever semantics match one-to-one,
and adds exactly one resolver-specific code only where `v0.2` has no equivalent.

| Candidate reason | Decision | `v0.2` mapping | Rationale |
|---|---|---|---|
| `reference_not_found` | reuse | `CREDENTIAL_NOT_FOUND` | Exact match. |
| `source_unavailable` | reuse | `CREDENTIAL_SOURCE_UNAVAILABLE` | Exact match. |
| `access_denied` | reuse | `CREDENTIAL_INVALID` | Rejected credential; identity mismatch → `WRONG_ACCOUNT`/`WRONG_HOST`/`WRONG_PROFILE`. |
| `scope_insufficient` | reuse | `TOKEN_SCOPE_INSUFFICIENT` | Exact match. |
| `material_invalid` | reuse | `CREDENTIAL_INVALID` | Malformed/unusable material ⇒ invalid-credential family. |
| `resolver_error` | **new** | `RESOLVER_ERROR` | Infrastructure failure of the resolver itself; no `v0.2` equivalent. |

Rules:

- Reuse overrides invention; any 1:1 mapping MUST reuse the existing `v0.2` code and MUST NOT add a resolver alias.
- The single new code `RESOLVER_ERROR` is resolver-specific (infrastructure, not credential/identity). It is **not** added to
  `schema/diagnostic-codes.json` in this RFC task.
- Resolver `outcome` (resolved/unavailable/failed) is resolver-layer state; mapped to `v0.2` diagnosis `status` only for reporting.

---

## 9. Resolver Authority (frozen rules)

- The `ExecutionPlan`-selected `CredentialReference` is authoritative.
- A resolver receives exactly that logical reference.
- A resolver may resolve material for that reference, or fail.
- A resolver MUST NOT:
  - select a different account/profile/reference;
  - relax host/profile/account constraints;
  - fall back to the first available credential;
  - trigger login/reauth;
  - mutate global auth state;
  - alter the `ExecutionPlan`.

---

## 10. Capability Matching (resolver selection ≠ credential selection)

Two distinct selections:

- **Credential selection**: which `CredentialReference`? (done by `v0.3/v0.4` before `v0.5`).
- **Resolver selection**: which resolver implementation is capable of resolving that already-selected reference? (new `v0.5`).

Deterministic matching, fail-closed:

| Condition | Behavior |
|---|---|
| Zero matching resolvers | `failed` + `RESOLVER_ERROR` (or `CREDENTIAL_SOURCE_UNAVAILABLE` for unsupported source type); never pick a default. |
| Multiple equally eligible resolvers | `failed` + `RESOLVER_ERROR` (ambiguous resolver); never use array order as authority. |
| Unsupported sourceType/provider | `failed` + `RESOLVER_ERROR` (or `CREDENTIAL_NOT_FOUND` if genuinely absent). |
| Explicit resolver requested but incompatible | `failed` + `RESOLVER_ERROR`; never silently substitute. |

Matching is a pure function of `(CredentialReference, ResolverDescriptor[])`. It does not read credentials, does not query providers,
and does not depend on array order.

---

## 11. Resolver Types (classification, no implementation)

| Family | Protocol vs reference impl | May expose a filesystem path internally? | May require provider-specific adaptation? |
|---|---|---|---|
| `environment` | Protocol-safe | No | No |
| `file` | Protocol (logical reference only); path is private | Yes (private) | Yes (file location) |
| `OS keyring / secret store` | Reference implementation | No | Yes (platform) |
| `existing CLI authenticated session` | Reference implementation | No | Yes (provider CLI) |
| `connector` | Protocol (connector id) | No | Yes (host binding) |
| `external credential broker` | Protocol (broker id) | No | Yes (broker protocol) |

`.machine-tokens` is a **reference** storage convention, **never** a protocol requirement. Portable resolvers must not assume
`%USERPROFILE%\.machine-tokens\`; a file reference is always a logical reference string, never a filesystem path.

---

## 12. Runtime Neutrality

A Python/Node/Rust/Go implementation must implement, with identical semantics:

1. Public `Resolve Request` and `Resolver Outcome` shapes (runtime-neutral JSON).
2. `ResolverDescriptor` / capability matching (pure function).
3. `CredentialReference`-authority rules (never second-select).
4. A private `CredentialMaterial` with bounded lifetime + disposal.
5. A process-scoped injection primitive that only sets child environment, never mutates parent/global state.
6. The failure / `RESOLVER_ERROR` semantics.

PowerShell `[scriptblock]` and `scripts/core/execution.ps1` are **reference bindings** for the PowerShell runtime only; they are **not**
the protocol. No contract text depends on `[scriptblock]` or `$env:` semantics.

---

## 13. Compatibility (preserved exactly)

- `v0.2` Diagnosis Result semantics (`0.2.0`) unchanged.
- `v0.3` CredentialReference / Credential Context semantics (`0.3.0`) unchanged.
- `v0.4` ExecutionPlan and gate semantics (`0.4.0`) unchanged.
- Plan-only default (`broker.ps1` without `-Execute`) unchanged.
- Explicit execution opt-in (`-Execute`) unchanged and still required.
- No automatic reauthentication; `INTERACTIVE_AUTH` / `reauthRequired` remain decision markers only.

---

## 14. Security Invariants

- Raw material lifetime is bounded to the single operation and expires / is cleared.
- Zero public serialization of material (never in a public JSON result).
- Zero logging of material (never in logs).
- Zero persistence/caching by Core.
- Sanitized failure output only (no raw, no exception text, no path).
- Cleanup/disposal: resolver disposes its backing resource; execution runtime clears child env and discards the local copy on
  success/failure/timeout.
- Child-process exposure limited to the single injected target (env var/handle), never wider.
- Resolver trust boundary: a resolver is trusted to resolve material for the exact reference, but never trusted to select, mutate
  global auth, or log. Core treats resolver output as data, never as authority beyond the selected reference.

---

## 15. Implementation Sequence (smallest v0.5 proposal)

1. Resolver public schema (`schema/credential-resolver.schema.json`, `contractVersion 0.5.0`).
2. Resolver Core / capability matcher (pure function, e.g. `scripts/core/resolver.ps1`).
3. Runtime-private PowerShell resolver reference interface (typed parameter object, not a bare `[scriptblock]`).
4. Fixtures + validator (`fixtures/v0.5/...` + `scripts/validate-resolver.ps1`).
5. Integration with `scripts/core/broker-execution.ps1` (replace the ad-hoc `[scriptblock]` seam).
6. Permanent tests (add to the permanent suite).

No broad refactor; the above is additive and preserves all prior contracts.
