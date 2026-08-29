# RFC v0.3 — Agent Credential Layer: Credential Context (Reference → Profile → Context)

- Status: Draft for implementation
- Contract version: `0.3.0` (context layer); the v0.2 diagnosis contract remains `0.2.0` and is unchanged
- Scope: v0.3 core = credential-reference model + profile selection + context resolution + project binding + process-scoped execution boundary (contract only)
- Repository: `agent-credentials-skill`
- Target lifecycle: `Discover -> Diagnose -> Resolve -> Execute -> Verify -> Recover` (v0.3 adds the credential-context layer between Resolve and Execute; Execute is designed, not implemented in this milestone)

---

## 1. Problem Statement

v0.2 answers "what is wrong with the credential in this context?" (Discover → Diagnose → Resolve). v0.3 answers a different question: "which credential context should this operation use, and how is it referenced, selected, and used without mutating global auth state?"

An agent on one machine may hold multiple valid credentials: GitHub personal and work accounts, PyPI, npm, enterprise hosts. Without a stable context model, the agent:

- has no stable way to reference a credential without embedding its value (global `GH_TOKEN` set, `gh auth switch`, ad-hoc file reads);
- cannot deterministically select the right account/profile for a given repository or operation;
- may silently pick the wrong account/profile when several references are available (ambiguity);
- has no project-level binding ("this repository always uses the work account");
- mutates global auth state as the default mechanism (`gh auth switch`, persistent env), which is exactly the failure mode v0.1/v0.2 tried to eliminate.

Two facts must stay separate in v0.3 as well:

- **Reference vs value**: contracts, configuration, project bindings, and LLM-facing context carry references (`credential:<id>`, `env:GH_TOKEN`, `file:<path>`), never raw secrets.
- **Selection vs execution**: deciding *which* reference to use (resolver) is separate from *materializing and injecting* the raw value into a child process (execution boundary). v0.3 defines the contract for both, but only implements selection/resolution; execution is a future seam.

---

## 2. Design Principles

1. **Credentials by reference, never by value.** The context model, project bindings, and public outputs carry safe references/ids only. Raw values are materialized only inside a bounded, process-scoped execution step (future).
2. **`account != profile != host`.** Identity semantics from the v0.2 provider-adapter contract are preserved: `account` owns the credential, `profile` is a named selection/binding (personal vs work), `host` is the endpoint the credential targets.
3. **A profile selects references; it contains no secrets.** A profile is a stable logical name plus expected account/host and a list of reference ids.
4. **Deterministic selection; ambiguity fails closed.** Resolution must be reproducible from the same inputs, and when multiple references could match and no rule decides, it must not silently choose the wrong account/profile — it returns an explicit ambiguity outcome for the skill/policy layer.
5. **Process-scoped effects by default; no global auth mutation.** The default mechanism never runs `gh auth switch`, never persists a global token, and never changes the user's global auth state. Injection happens in a child-process scope and the parent/global state is restored.
6. **Project binding is optional and backward compatible.** A repository may declare a provider/profile binding; absence of a binding keeps current v0.1/v0.2 behavior unchanged.
7. **Layered on diagnosis, not a replacement.** The v0.3 context model consumes v0.2 diagnosis output (which references are usable/authorized) as one input to resolution. The v0.2 Diagnosis Result schema is unchanged.
8. **Runtime/language neutral.** The v0.3 context contract — model, schema, resolution semantics, execution-boundary contract — is runtime neutral. PowerShell remains an initial reference implementation/adapter path only.
9. **No raw secret in public Diagnosis Result or LLM-facing context.** Anything that crosses the agent context boundary carries references and safe evidence only.

---

## 3. Core Model

### 3.1 CredentialReference

A `CredentialReference` identifies one credential by reference, never by value:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Stable safe reference/id within the machine (for example `github:work:token-file`) |
| `provider` | string | yes | Provider namespace (`github`, `pypi`, `npm`, ...) |
| `sourceType` | enum | yes | Where the value lives: `env`, `file`, `keyring`, `connector`, `cli` |
| `account` | string | no | The account that owns the credential |
| `profile` | string | no | Logical profile this reference belongs to (`personal`, `work`) |
| `host` | string | no | Target endpoint/host (`github.com`, enterprise host) |
| `metadata` | object | no | Safe non-secret metadata (label, source path reference, precedence) |

Invariant: **no field ever holds a raw credential value.** A `file` source may carry a *path reference*, never the file content.

Example:

```json
{
  "id": "github:work:token-file",
  "provider": "github",
  "sourceType": "file",
  "account": "work-user",
  "profile": "work",
  "host": "github.com",
  "metadata": { "label": "work token file" }
}
```

### 3.2 CredentialProfile

A `CredentialProfile` is a stable logical selection:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Stable logical name (`personal`, `work`) |
| `provider` | string | yes | Provider namespace |
| `account` | string | no | Expected account for this profile |
| `host` | string | no | Expected host for this profile |
| `references` | string[] | yes | Ordered reference ids this profile selects (by reference, not by value) |

Rules:

- `account != profile != host` (v0.2 identity semantics).
- A profile selects references; it does **not** contain secrets.
- A reference may belong to several profiles; a profile has a deterministic reference order (first usable wins after diagnosis).

### 3.3 CredentialContext

A `CredentialContext` is the resolved answer for one operation:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `provider` | string | yes | Provider namespace |
| `operation` | string | yes | Operation being performed (`push`, `api`, `release`, `publish`, `auth-check`, ...) |
| `requestedProfile` | string | no | Profile requested by caller/project binding |
| `selectedProfile` | string | no | Profile selected by the resolver |
| `expectedAccount` | string | no | Account the operation expects |
| `expectedHost` | string | no | Host the operation expects |
| `availableReferences` | array | yes | CredentialReference objects (references only) |
| `selectedReference` | object | no | The chosen CredentialReference (reference only) |
| `executionContext` | object | yes | Reused v0.2 execution-context facts (keyring accessibility, env propagation, network reachability, tool availability) |
| `ambiguity` | boolean | no | True when resolution could not deterministically select and failed closed |

Invariant: **the context object never contains a raw credential value.** It carries ids, references, profiles, and safe facts.

---

## 4. Resolution Semantics

The resolver (future implementation step) maps `(provider, operation, requested profile, expected account/host, v0.2 diagnosis result, available references) -> CredentialContext`.

Ordering rules, in priority order:

1. **Explicit project/repository binding** for `provider` wins (see §5).
2. **Explicitly requested profile/account/host** from the caller wins over defaults.
3. **Choose an already-authorized usable reference where possible**: use v0.2 diagnosis evidence to prefer references whose validity is confirmed over unknown or unverified ones.
4. **Deterministic tie-break** on remaining candidates: fixed reference order within the profile, then profile order; the same inputs always produce the same selection.
5. **Ambiguity must not silently choose the wrong account/profile**: if two references are equally authorized and no rule distinguishes them, resolution marks `ambiguity: true` and returns no selected reference (fail closed) for the skill/policy layer to escalate.

Additional constraints:

- Credentials are selected **by reference**, never by value.
- No global `gh auth switch` as the default mechanism; switching, if ever needed, is an explicit policy-selected resolution (`SELECT_ACCOUNT` / `SELECT_PROFILE`), never an adapter default.
- Prefer process-scoped effects (see §6).

---

## 5. Project Binding

An optional, per-repository (or per-project) declaration maps a repository to a provider/profile:

```json
{
  "version": "0.3.0",
  "bindings": [
    { "repository": "SIMON-WORLD/agent-credentials-skill", "provider": "github", "profile": "personal" }
  ]
}
```

Rules:

- Configuration stores **logical references only** (repository → provider/profile); it never stores tokens or secrets.
- The binding file location is deterministic and documented in the implementation step (for example a repository-local file and/or a machine-level context file), and both must be excluded from any secret scan.
- **Absence of a binding remains backward compatible**: no binding → current v0.1/v0.2 behavior (default profile, existing file/env sources) unchanged.
- A binding may pin an expected `account`/`host` so the resolver can verify the selected reference matches the repository's intent.

---

## 6. Future Execution Boundary

v0.3 defines the **contract** for a process-scoped execution boundary; it does **not** implement execution in this milestone.

Conceptual interface:

```text
exec(profile-or-reference, command)
  -> resolve raw credential value ONLY at execution time
  -> inject ONLY into the child process scope (environment)
  -> run command
  -> restore / never mutate parent or global auth state
```

Guarantees:

- Raw credential is resolved at execution time, not before.
- Injection is child-process-scoped only; the parent/global auth state is untouched and restored.
- No global `gh auth switch`, no persistent environment mutation.
- Raw secrets never enter the public Diagnosis Result, configuration, project bindings, or LLM-facing context.
- The boundary is provider-neutral and runtime-neutral; PowerShell is only a reference implementation.

**Explicit scope note: execution is NOT implemented in this task.** This RFC only fixes the contract so later milestones can implement it without renegotiating semantics.

---

## 7. Compatibility

- The v0.2 Diagnosis Result schema (`schema/diagnosis-result.schema.json`, `0.2.0`) is **unchanged**.
- v0.2 doctor, validator, and fixtures remain valid and must keep passing.
- v0.1 `install` / `check` / `refresh` scripts remain supported.
- The v0.3 context model **layers on top of** diagnosis rather than replacing it: v0.2 outputs become inputs to the v0.3 resolver.
- Existing identity semantics (`account != profile != host`) and resolution codes (`SELECT_ACCOUNT` / `SELECT_PROFILE` / `CORRECT_HOST`) stay authoritative.

---

## 8. Non-Goals (this milestone)

- Full secrets vault.
- Encryption / keychain backend.
- Token rotation.
- Plugin packaging / skill-market distribution.
- GUI.
- Global account switching.
- Broad provider implementation (only a GitHub multi-account reference implementation plus a compatibility check with the existing npm reference adapter).

---

## 9. Implementation Sequence

After this RFC is accepted, the following bounded milestones follow (each with its own contract/test step):

1. Machine-readable context schema (new schema files; v0.2 schema untouched).
2. Context validator + conformance fixtures.
3. Resolver (diagnosis + available references + request -> CredentialContext; ambiguity fails closed).
4. Process-scoped execution boundary (contract + reference implementation; no global mutation).
5. GitHub multi-account/profile adapter (reference implementation).
6. Project binding (configuration, loading, absence fallback).
7. Second-provider compatibility (npm reference adapter stays coherent with the context model).
8. Docs, tests, release (`v0.3.0`).

---

## 10. Security Invariants

- No raw secrets in configuration, project bindings, contracts, public Diagnosis Result, or LLM-facing context.
- No global auth mutation by default; process-scoped effects only.
- Deterministic selection; ambiguity fails closed and never silently chooses the wrong account/profile.
- Backward compatible when no binding/reference exists.
- PowerShell remains only a reference implementation; the contract itself is runtime/language neutral.
