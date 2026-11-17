# WhatsApp V3 capability record

## Completed package boundary

- Stateless Jido Chat Adapter with explicit native and unsupported operations.
- Explicit Client configuration and selected Amarula transport.
- Push Source for Jido Chat Sensor admission.
- Provider-owned linked-device worker and shared Amarula infrastructure.
- Deterministic message, edit, delete, reaction, and failure normalization.
- Owner-scoped pairing with bounded private callbacks.
- Explicit storage, logout, and offline cleanup.
- Authenticated client-scoped media references.
- Offline Adapter, Source, runtime, storage, pairing, identity, and media tests.

## Native operations

- Send text and finite rendered streams.
- Send images and documents from Base64 input.
- Edit and delete messages.
- Add and remove reactions.
- Send typing state.
- Read local conversation, thread, and user projections.
- Resolve a direct-message address.
- Download media through an opaque resource reference.

## Required invariants

- The package does not own Jido Chat rooms, bridges, agents, or history.
- A profile is explicit. There is no global connection fallback.
- Unsupported operations do not make provider calls.
- Private provider values do not enter public Signals.
- Pairing and storage callbacks require host authorization.
- Normal stop preserves storage. Logout clears only the selected profile.
- Live tests stay disabled unless a user authorizes them.
