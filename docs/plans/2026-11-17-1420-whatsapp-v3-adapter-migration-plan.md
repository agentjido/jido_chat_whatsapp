---
title: WhatsApp adapter Jido Chat V3 migration
type: implementation-plan
date: 2026-11-17
last_reviewed: 2026-11-17
artifact_contract: kata-plan/v1
artifact_readiness: completed
domain: software
execution: code
product_contract_source: approved-goal
---

# WhatsApp Adapter Jido Chat V3 Migration

## Goal Capsule

- Objective: Migrate the WhatsApp linked-device package to the current Jido
  Chat V3 Client, Signal, Adapter, and Sensor Source contracts. Remove the old
  chat API and the provisional Jido Chat fork.
- Means: Preserve Amarula pairing, connection recovery, bounded identity
  lookup, Mnesia-backed session protection, opaque media references, and
  offline protocol tests. Put chat input through one push Source and chat
  output through typed V3 operations.
- Authority: Local WhatsApp package and local Jido Chat checks. Dependency
  download is allowed. No live account use, branch change, commit, push,
  release, or remote update.
- Stop conditions: Stop before private session material enters a Signal, core
  gains a WhatsApp branch, live pairing starts, or an unapproved remote action.

## Starting Evidence

- The clean `main` branch is at `d542c5c` and matches `origin/main`.
- The locked earlier baseline passes 233 offline tests, including 13 property tests;
  13 live tests are excluded.
- The package selects the Git branch
  `jat10/jido_chat:feat/shared-pairing-capability`, declares direct Zoi 0.18,
  and uses removed event, webhook, incoming, response, and fallback contracts.
- The package owns provider-specific Amarula and session-storage processes.
  Those processes are not the retired room runtime.

## Product Contract

- **R1:** Select sibling `../jido_chat` and consolidated Jido V3 at
  `ec96da6015b4b1e5a1642d50651235d9d52808ec`. Remove the provisional fork and
  the direct Zoi dependency.
- **R2:** Keep one thin stateless Adapter with explicit
  `:native | :unsupported` operation statuses. Do not retain direct adapter
  calls, fallback statuses, event wrappers, or webhook values.
- **R3:** Use explicit Client configuration. Do not read a profile, credential,
  or transport choice from application environment. Provider runtime startup
  configuration stays separate from portable chat values.
- **R4:** Preserve native send, file, edit, delete, typing, metadata, user,
  thread, file download, reaction, direct-message, and finite-stream behavior
  where the V3 core has a matching operation and result.
- **R5:** Add a receive-only `Jido.Chat.Sensor.Source`. Its linked worker owns
  the Amarula connection, recovery, storage watch, and protocol lifecycle. It
  normalizes provider input and pushes only validated public facts to the host
  Sensor.
- **R6:** Normalize message, edit, revoke, and reaction input to deterministic
  V3 facts. Keep credentials, QR text, session data, raw Amarula structs,
  media keys, download URLs, storage handles, and process references out of
  public Signals.
- **R7:** Preserve opaque media references. They are scoped to one Client and
  profile. File download resolves them only through the selected connection
  and returns canonical base64 resource data.
- **R8:** Keep pairing and lifecycle control private. A host can use the
  owner-scoped authentication API and an optional private lifecycle callback, but
  lifecycle data does not become a chat fact or a public event envelope.
- **R9:** Keep the provider-specific OTP tree bounded and independent of Jido
  Chat room ownership. The Jido Chat runtime owns rooms and bridges; this
  package owns only Amarula transport and linked-device session processes.
- **R10:** Update tests and documents to describe the V3 boundary and remove
  every retired package and earlier chat API reference.
- **R11:** Offline tests cover the Adapter Test Kit, all native operations,
  normalization identity and failure behavior, Source admission, source-worker
  shutdown, storage recovery, pairing safety, and opaque media handling.
- **R12:** Tests, coverage, quality, docs, production compile, unused
  dependency, dependency tree, compile graph, source scan, diff check, and the
  Elixir design review pass.

## Implementation Units

1. Select local Jido Chat V3, remove the fork and direct Zoi dependency, and
   refresh the dependency graph.
2. Add V3 Operations and Normalizer modules around the existing transport,
   message formatter, address, and media helpers.
3. Add the push Source and change `ConnectionWorker` from old sink envelopes to
   Sensor admission plus an optional private lifecycle callback.
4. Replace the Adapter with the strict V3 contract. Remove obsolete
   translation and response paths.
5. Rewrite boundary tests and documents. Preserve provider runtime, storage,
   pairing, and transport tests that remain valid.
6. Run all offline gates and the Elixir design review, fix every supported
   finding, and repeat affected checks.

## Definition of Done

- R1 through R12 have current evidence.
- The 233-test earlier baseline behavior that belongs to provider transport,
  storage, pairing, and safety remains covered by V3 or provider-level tests.
- No live provider call, live pairing, branch change, commit, push, release, or
  remote update occurred.

## Completion Evidence

- `mix test`: 165 passed, including 11 property tests; 3 live tests excluded.
- `mix coveralls`: 80.9% total coverage and the configured threshold passed.
- `mix quality`: passed. Dialyzer reported zero errors and Doctor reported no
  failed modules, 98.7% documentation coverage, and 98.1% specification
  coverage.
- `mix credo --strict --all`: no issues.
- `mix docs --warnings-as-errors`: passed.
- `mix deps.unlock --check-unused`: passed.
- Production compile: passed. Any displayed warnings came from third-party
  dependencies; this package compiled without a warning.
- `mix xref graph --format cycles`: no cycles.
- The dependency tree selects sibling `../jido_chat` and consolidated Jido at
  `ec96da6015b4b1e5a1642d50651235d9d52808ec`.
- Source scans found no retired chat API, superseded pairing API, global
  application configuration, dynamic string-to-atom conversion, or retired
  package reference.
- `git diff --check`: passed.
- The Elixir design review found and fixed incomplete start-link types, an
  unreachable normalization clause, duplicate pairing contracts, optional
  runtime ownership, unbounded lifecycle retry, exception-based handoff, and
  avoidable atom conversion.
- No live provider call, pairing operation, commit, push, release, remote
  update, or branch change occurred.
