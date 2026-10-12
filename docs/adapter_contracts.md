# Linked-device adapter contracts

## Ownership and flows

`Adapter.listener_child_specs/2` builds the existing `ConnectionWorker` child.
The host (`jido_messaging`) owns its supervisor, restart policy and shared
Amarula supervisor. The worker owns ingress translation and its connection
lease; Amarula owns sockets, protocol reconnects, decoding and protocol state.
`Transport` is the only boundary for protocol access. `Message` is a pure
normalizer; `Pairing` interprets pairing progress, and the host owns UI/policy.
No agent invocation decisions belong here.

Flow: transport event → worker → plain payload → message sink →
`Adapter.transform_incoming/1` → `Incoming`. Account aliases come from the
connection's transport, never an application-wide account lookup. A missing
recipient does not imply a mention. Phone and LID aliases identify the receiving
account; device suffixes do not change identity. Unsupported broadcast/newsletter
rooms return an error rather than masquerading as DMs.

## Public contract (work-5rb)

Existing message sink `{module, function, args}` receives `args ++ [payload, opts]`.
An optional `lifecycle_sink_mfa` uses the same invocation shape and receives a
plain map with `profile`, `attempt_id`, `event`, `status`, and `qr`. QR data is
only sent to this explicitly configured trusted sink. Without it lifecycle
updates are discarded, never sent to chat ingress. This intentionally changes
the preview's mixed action/message sink behavior. Pairing success is progress;
only socket open means connected. Failures contain fixed categories, no raw
provider errors. QR expiry and completion clear QR; stale attempt events and
old expiry timers are ignored.

QR expiry sets `status: :expired` and `qr: nil` in both the `:qr_expired`
notification and subsequent `ConnectionWorker.status/1` snapshots (`event:
:status`). Expiry describes the QR, not a transport disconnection; only a closed
connection update sets `:disconnected`. The expired status persists until another
lifecycle transition: a replacement QR sets `:pairing`, pairing success sets
`:authenticating`, socket open sets `:connected`, reconnect starts a new attempt
with `:connecting`, and successful logout sets `:logged_out`. Each transition
clears the old QR, except replacement, which supplies the new QR. Consumers must
handle the new `:expired` status without retaining earlier notifications.

Each listener uses an explicit profile, or the existing deterministic
`jido_chat_whatsapp_<bridge_id>` compatibility default. Outbound per-call profile
and conn options remain supported; application defaults are outbound-only.
A connection belongs to one listener. Duplicate ownership fails; arbitrary
live connections are never silently stolen. Reconnect preserves configuration
and storage and rotates attempt correlation. Stop preserves storage; logout is
an explicit separate operation and must surface failures.

Custom storage uses `{module, opts}` and profile-scoped callbacks. The adapter
consumes these callbacks; encryption, transactions and durable storage are host
responsibilities. A guarded transport wrapper rejects callback failures,
never fall back to files, and prevent persistence failure from becoming pairing
success. Missing state and unreadable/corrupt state must be distinguishable.
`storage_root` is the file-store convenience, and must not override custom storage.

Both `sync_history` and `sync_full_history` default to Amarula's true. The former
gates historical import delivery, the latter requests full versus recent history.
Neither gates ordinary `messages_upsert`, including queued messages. No timestamp
heuristics. Enabled history is delivered with explicit history metadata.

## Failure matrix and validation map

| Condition | Contract | Regression evidence required |
| --- | --- | --- |
| Own/other mention, PN/LID/device suffix | canonical mentions and author.is_me | Message and listener tests |
| Missing recipient or unknown identity | no inferred self mention | pure normalization tests |
| Quoted message | shallow ReplyContext and reply ID | normalization tests |
| QR refresh/expiry, pairing then open | correlated lifecycle only | real worker + fake transport |
| Old attempt or QR timer | ignored | worker reconnect tests |
| Duplicate profile | reject without touching owner | transport tests |
| Partial startup | release only newly created resources | transport tests |
| Stop/restart | retain and restore profile-scoped state | isolated storage tests |
| Storage read/write/corruption | fail closed, sanitized error | guarded storage tests |
| Decoder/connection crash | protocol tree restores; host owns retry policy | offline protocol tests |
| History disabled | suppress imports, retain queued chat | worker + transport option tests |

## Dependency evidence and prerequisites

The lockfile resolves `jido_chat` 1.2.1 (Author.is_me, Mention.is_self,
ReplyContext, listener callback) and Amarula 0.5.10. The latter has profile
registries, `set_parent/2`, per-instance rest-for-one supervision and both history
flags. There is no separate decoder process in this version. Its `update_creds`
ignores storage write return values and its default file adapter treats corrupt
reads as misses. Custom strict storage needs a transport-side guard (implemented here); upstream
should propagate typed storage failures throughout protocol operations.

The host must consume the new lifecycle sink separately and provide a bounded
restart policy. Generic dynamic profile supervision and host integration tests
remain a `jido_messaging` prerequisite, outside this package. No supervisor
hierarchy will be copied here. Live pairing/reconnect/delivery remain opt-in
release gates, not claims made by deterministic tests.

## Storage callback example

```elixir
{:ok, specs} = Jido.Chat.WhatsApp.Adapter.listener_child_specs("support",
  ingress: %{
    mode: :linked_device,
    profile: "support-account",
    storage: {MyApp.SessionStorage, tenant: "support-account"},
    sync_history: false,
    sync_full_history: false
  },
  sink_mfa: {MyApp.Ingress, :emit, []},
  lifecycle_sink_mfa: {MyApp.PairingStatus, :emit, []})
```

The custom storage module implements `new(opts) -> state`,
`get(state, profile, namespace, key) -> {:ok, term} | :error | {:error, reason}`,
`put(state, profile, namespace, key, value) -> :ok | {:error, reason}` and
`delete(state, profile, namespace, key) -> :ok | {:error, reason}`.
Use `:error` only for an absent entry. Return `{:error, reason}` for corrupt or
unreadable data (the adapter extends Amarula's read contract to fail closed).
Optional `clear(state, profile)` enables logout; `list_keys(state, profile,
namespace)` and `list_profiles(state)` support protocol enumeration. Callbacks
must be concurrency safe and isolate every profile; successful writes must be
durable before returning. Callback state must outlive an individual connection.
The adapter does not implement encryption or a persistence schema.

A failed callback latches the connection's health as failed; the worker discards
further events, stops the connection and emits a sanitized failure. Read errors
fail startup rather than generating a fresh identity. A corrupt value returned
as a successful map cannot be fully validated here: the backend must validate
its serialized state before returning it. Default file storage retains Amarula's
corruption-as-miss behavior; strict failure guarantees require custom storage.

## Compatibility and remaining limitations

The supported dependency floor is Amarula 0.5.10 and Jido.Chat 1.2.1.
Existing raw message normalization, outbound calls, bridge-derived profile names
and file storage roots remain available. Custom transports may omit the new
optional identity/health/logout callbacks; without identity, self mentions cannot
be identified; without health, persistence guarantees belong to that transport.
Custom transports must send `{:amarula, event, data}` to the supplied `:parent`,
not directly to the worker; each receiver belongs to one attempt. The receiver
monitors its worker for cleanup, and the worker monitors the receiver. The host
must bound worker restart attempts, especially after authentication failures.

The transport uses Amarula's `Connection.make_socket/2` and `Connection.connect/1`
separately to clean up a partially established connection, and `get_conn/1` to
inspect guarded storage health. These protocol internals are confined to the
transport and covered by offline tests; an upstream atomic connect/health API
would remove that coupling. Arbitrary running connections are not adopted;
protocol restarts of the owned connection resolve through the stable instance
handle. The transport's logout is a best-effort server unlink plus local clear;
server acknowledgement cannot be guaranteed during disconnection.

Attempt IDs identify explicit listener connection attempts. Amarula's in-process
socket reconnects retain that attempt ID and protocol configuration. QR expiry
uses Amarula's current first/refreshed timeout convention (60 seconds or configured
`qr_timeout`, then 20 seconds). Lifecycle status is local adapter knowledge, not
a remote delivery guarantee. Live release gates and host migration remain open
outside this epic.

Profile names must be nonempty and cannot be `.`/`..` or contain path separators
or NUL. This prevents file-store cleanup from escaping its profile scope. Custom
storage still owns tenant validation and access control. Owned transport handles
identify an Amarula instance, so delayed cleanup cannot stop a later instance
using the same profile, even during a protocol child restart.
