<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Shared API access workflow

Load this reference before choosing Process or User scope, interpreting validator host state, classifying an HTTP failure, or preparing the completion report for a configure API access Skill.

## Process and User scope

Use Process scope by default. The configure helper writes every required setting to its current Process so immediate validation can use it. Use User scope only after explaining persistence and obtaining authorization; it adds persistence for non-secret settings, while persisting the token separately requires the helper's explicit `-PersistTokenToUser` switch. Without `-PersistTokenToUser`, the token remains Process-scoped even when non-secret settings are persisted. Process values apply only to the current process and future children; do not report Process-only settings as persisted. A User or Machine value does not update an already-running Agent host.

Treat Process scope as the only effective environment for connection validation. Inventory Process, User, Machine, approved secret-store injection, and unknown sources without exposing values:

Let `M` be the set of required Process values that are missing.
Evaluate the following states in order; the first state whose condition is true is the result:

1. `incomplete`: `M` is non-empty, and at least one value in `M` has no persisted candidate; do not send a request.
2. `reload-required`: `M` is non-empty, and every value in `M` has a persisted candidate in User or Machine scope; do not send a request.
3. `process-user-mismatch`: `M` is empty, and at least one persisted value differs from its Process value; the current Process may be tested, but report the mismatch and warn that a future host may inherit different values.
4. `process-ready`: `M` is empty, and no persisted value differs from its Process value.

For any input, exactly one state applies.

`HostReloadContract` version 1 is host-agnostic. `PersistedButNotInheritedSettings` lists every persisted candidate whose required Process value is missing. When `Required` is true, `RequiredAction = recreate-host-process`, `ParentProcessMutationSupported = false`, and the adapter must rerun the same validator after recreation. If the token was not persisted, `SecretInjectionRequired` is true and `SecretSourceRequired = approved-secret-store-or-hidden-input`; do not assume a restart alone will supply it. A child process must never attempt to repair its existing parent by setting `$env:*`. The Codex adapter must fully exit and relaunch Codex with the required secret injection from an environment that can see the intended User values; other hosts map the same action in their own adapter.

## Safe HTTP classification

Return only the HTTP status, failure category, and redacted remediation. Do not return a response body unless the user needs a specific non-sensitive field and its disclosure is justified; even then, return only that field, never the complete response body. Suppress authorization data, raw exception messages, private identifiers, and unrelated data.

- `200`: proves success only for authentication, the endpoint, and the permissions actually tested; separately verify the scopes or permissions required for the intended operation.
- `3xx`: reject the redirect without following it and fail closed as `redirect-rejected`.
- `400`: request or configuration error; validate construction without exposing inputs.
- `401`: authentication error; verify token type, account identity, expiration or revocation, and endpoint selection.
- `403`: authorization, product permission, scope, or resource-access restriction; do not claim which one without evidence.
- `404`: tenant, endpoint, path, or resource mismatch; verify identity without guessing.
- `429`: respect `Retry-After` when present; do not retry aggressively.
- `5xx`: service unavailability, separate from credential failure.
- Transport, network, proxy, DNS, certificate, or TLS failure: report separately from authentication.

Repeated authentication failures after safe configuration and endpoint checks stop the workflow. Do not change the environment's required connection method as a fallback.

## Completion report

Report in the user's language:

- each required setting's purpose, presence, source scope, and validation state, without its value;
- the redacted tenant or API-base consistency result;
- each read-only endpoint category tested and its HTTP status;
- the minimum permissions or scopes required for the intended operation;
- whether access is ready for that operation;
- `HostEnvironmentState`, `PersistedButNotInheritedSettings`, conflicting setting names, and the required `HostReloadContract` action;
- remaining token expiration, rotation, scope, or policy actions.

Never include real credential values, authorization headers, complete API response bodies, private account or tenant identifiers, or unrelated external-system data.
