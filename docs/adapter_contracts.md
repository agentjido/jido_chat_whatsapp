# Linked-device adapter contracts

## Ownership and flows

### Media references

Linked-device media ingress emits a normalized `EventEnvelope` containing an
`Incoming` with public attachment metadata and an opaque
`whatsapp://media/v1/...` reference in `media.url` and `media.metadata.file_id`.
Private download descriptors are removed from media metadata. Both `Incoming.raw`
and `EventEnvelope.raw` contain exactly the allowlisted conversation facts
`%{channel_jid: external_room_id, from_jid: external_user_id, timestamp: timestamp}`,
projected from normalized attributes rather than copied from the provider payload.
This replaces the previous empty media `raw` maps. Room and sender use normalized
JIDs (including connection-scoped sender canonicalization on listener ingress).
Missing senders remain `nil`; timestamps are Unix seconds, with numeric strings
normalized to integers and missing or malformed raw timestamps represented as
`nil`. No unit conversion or receive-time substitution occurs. Hosts must still
verify that `channel_jid` matches the expected room and validate its conversation
type; these facts do not grant authorization. Non-media and legacy no-options
normalization retain their existing behavior. Hosts preserve the reference
unchanged and call
`Adapter.fetch_media(reference, profile: profile)` using the originating
configuration, just as they supply the originating Telegram bot token.
Hosts must still enforce authorization before fetching; reference possession
does not replace application access checks.

The default transport seals the descriptor with AES-256-GCM, a random nonce and
a domain-separated key derived from the persisted signed identity private key
and profile. It resolves and validates the descriptor before downloading and
decrypting WhatsApp's CDN bytes. No extra host secret, attachment mapping store,
or per-attachment credential write is needed. Keys never enter public media
metadata. The reference is confidential but should still be treated as opaque,
not parsed or edited by consumers.

References survive runtime restarts when the same profile and credentials are
restored. Fetching requires that profile's connection to be loaded, though its
socket need not be connected. Another profile or replacement credentials cannot
resolve the reference. Logout/re-pairing, profile renaming, credential loss, or
WhatsApp CDN expiry can make old attachments unavailable. Version 1 references
are limited to 24,000 bytes, with a maximum 16,384-byte private descriptor.

Incoming push names are trimmed before they enter the canonical author and
display-name fields. Blank and `~` placeholders become `nil`; push names never
establish external user identity. Phone enrichment remains connection-scoped
through `Adapter.get_user/2`.

Before emitting messages or reactions, the linked-device listener calls optional
`Transport.canonical_user_id/2` for the sender. Amarula resolves a PN to its LID
using only the originating connection's stored mapping. An existing LID is kept;
missing mappings, unavailable lookups, or transports without this callback retain
the original sender ID. No profile-phone inference or network discovery occurs.
Room IDs and reaction target IDs are unchanged. Manual normalization without a
listener does not resolve mappings. This does not migrate previously stored host
identities or recover reactions that were already discarded.

For manual ingress, use `Adapter.transform_incoming(payload, opts)` or
`Adapter.parse_event(request, opts)` with `:profile`, `:conn`, or `:connection`
to obtain opaque references. The legacy no-options normalization and structured
descriptor fetch API remain available to trusted direct callers and contain
sensitive download information. Custom transports implement `media_reference/2`
and `resolve_media_reference/2` for opaque media support; missing support or
sealing failure never falls back to emitting private descriptors. Listener
normalization failures emit the sanitized lifecycle event
`:ingress_normalization_failed` and skip that message.

### Runtime boundaries

`Adapter.listener_child_specs/2` builds the existing `ConnectionWorker` child.
The host (`jido_messaging`) owns listener supervision and restart policy. The
package OTP application owns shared transport infrastructure, starting it without
opening profiles. The worker owns ingress translation and its connection
lease; Amarula owns sockets, protocol reconnects, decoding and protocol state.
`Transport` is the only boundary for protocol access. `Message` is a pure
normalizer; `Pairing` interprets pairing progress, and the host owns UI/policy.
No agent invocation decisions belong here.

The Amarula transport supervises its shared tree together with a generation
sentinel using `:one_for_all`. Losing a registry or the connections supervisor
invalidates the generation and rebuilds all shared infrastructure. The optional
`Transport.connection_processes/1` callback returns the generation and connection
owner PIDs monitored by the listener relay. Their loss terminates the listener;
its host restart policy determines recovery. Protocol children may still restart
transparently behind the same connection handle. Custom transports that omit the
callback retain their existing behavior.

Connections wait up to five seconds for a ready generation during startup or
recovery. `connect/2` does not restart a stopped application. The interactive
pairing entry point uses `ensure_started/1` to start the package application, never
a caller-owned shared supervisor. Storage and duplicate-profile contracts remain
unchanged. A listener stop affects only its own instance and preserves credentials.

Legacy hosts may set `config :jido_chat_whatsapp, start_runtime: false` before
boot and retain ownership of Amarula infrastructure and its recovery. In that mode
listeners monitor the host's shared root and their connection owner. Automatic
package ownership and host ownership must not be enabled together; there is no
adoption or linking of an existing host tree. Remove the legacy child and the
setting together when completing migration.

Flow: transport event → worker → message sink. Text uses plain payloads that
the host normalizes with `Adapter.transform_incoming/1`; media and reactions
use normalized event envelopes. Account aliases come from the
connection's transport, never an application-wide account lookup. A missing
recipient does not imply a mention. Phone and LID aliases identify the receiving
account; device suffixes do not change identity. Unsupported broadcast/newsletter
rooms return an error rather than masquerading as DMs.

Reactions follow transport event → worker → `Adapter.parse_event/2` →
`EventEnvelope` (`event_type: :reaction`) → message sink. Amarula's direct
`{chat, id, from_me}` and group `{chat, id, from_me, participant}` references
identify the target message; the reaction's own ID is never a target fallback.
Missing or unsupported target references are rejected before sink delivery.

## Public lifecycle contract (work-fqt)

One `sink_mfa: {module, function, args}` receives `args ++ [payload, opts]`.
Ordinary text payloads and normalized media/reaction envelopes retain their paths.
Lifecycle is exclusively an `EventEnvelope` with `event_type: :action`,
`adapter_name: :whatsapp`, empty `raw` and empty envelope `metadata`. Its payload is:

```elixir
%Jido.Chat.ActionEvent{
  adapter: Jido.Chat.WhatsApp.Adapter,
  adapter_name: :whatsapp,
  action_id: "connection_update",
  value: "qr_available", # Atom.to_string(metadata.event)
  raw: %{},
  metadata: %{
    category: :connection_lifecycle,
    source: worker_pid,
    profile: "setup-session",
    attempt_id: attempt_ref,
    event: :qr_available,
    status: :pairing,
    qr: qr_string,
    identity: nil,
    identity_status: :unavailable,
    identity_error: :not_connected
  }
}
```

Envelope IDs are generated by Jido; retries retain the same envelope ID.
Thread/channel/message/user context is absent. Metadata is an allowlist of
adapter-owned state, never provider records. QR occurs only in `metadata.qr`,
only while pairing; clearing/expiry transitions set it to nil. Pairing codes,
credentials, storage records and raw provider errors are never delivered.
QR and account identity remain confidential: hosts must restrict display/access,
redact logs/traces and avoid generic chat persistence or agent invocation.

Transitions (`metadata.event`) are `:qr_available`, `:qr_expired`,
`:connection_update`, `:pairing_success`, `:pairing_failure`, `:error`,
`:connecting`, `:logged_out`, `:identity_pending`, `:identity_updated`,
`:ingress_normalization_failed`, `:storage_unavailable` and
`:storage_or_connection_failed`. Failures have fixed categories, no provider error
payload. Pairing success means `:authenticating`; only socket open is `:connected`.
Ingress normalization failure retains the current lifecycle status.

`source` is the originating worker PID, never the dispatcher or host callback PID.
It lasts for that worker's lifetime; a replacement worker has a different source,
even for the same profile. `attempt_id` is an opaque BEAM reference rotated on
explicit reconnect and storage recovery; protocol socket reconnects retain it.
This is an in-VM contract: generic wire/JSON serialization is not supported for
PID/reference correlation. Hosts must preserve and validate source/profile/attempt,
reject retired sources/attempts, and not relabel delayed events as a current source.
`ConnectionWorker.status/1` remains the existing plain map with `event: :status`;
it does not return an envelope or include category/source.

Lifecycle callbacks execute serially in a worker-owned linked dispatcher, outside
worker initialization and calls. Order is preserved within one worker, including
attempt transitions; no global ordering across workers or ordering relative to
chat ingress is promised. Chat callbacks still execute on their existing path.
A lifecycle callback may synchronously query worker status or request identity
refresh. Its snapshot may be older than current status, including an expired QR.
Hosts must reconcile current status before displaying delayed QR notifications.
Stopping the worker stops the dispatcher and drops queued notifications.

Return `{:error, :runtime_not_ready}` only before applying any host update to
retry the same envelope every 100 ms, holding subsequent lifecycle notifications.
This covers early notifications before host registration without blocking worker
startup/status queries. Register handlers and source ownership before accepting
notifications; readiness handling must not reenter listener startup. Other return
values (including errors), exceptions, throws and exits discard that notification
without raw logging or retry. There is no durable delivery, timeout or queue bound:
hosts must keep callbacks short and bound startup readiness. A blocked callback
blocks later lifecycle delivery, not worker status/expiry processing.

The existing `sink_mfa` receives lifecycle action envelopes alongside chat
payloads. Hosts must handle the lifecycle metadata described above before
switching dependencies.

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

## Authenticated account identity (work-jut)

`Transport.account_identity(conn)` is an optional callback returning
`{:ok, %{phone_number: string_or_nil, display_name: string_or_nil,
account_jids: normalized_jids}}` or `{:error, :unavailable | :timeout}`.
`AccountIdentity.normalize/1` allowlists these three fields and shares alias
normalization with `Message`. The worker normalizes custom transport results too.
Only the supplied authenticated connection may provide these facts; inbound
pushnames, sender JIDs and global account defaults are never identity sources.
Raw credentials, keys, storage records and provider errors stay behind Transport.

A phone number is `+` followed by the digits of the authenticated PN JID with its
device suffix removed. This is a provider identifier, not independent validation
of an E.164 number. A LID is opaque and never supplies a phone number. Alias lists
are deduplicated and contain only normalized PN/LID JIDs. An identity with only a
LID is available with `phone_number: nil`; no valid aliases means unavailable.
Names are trimmed; missing, non-string, blank and `~` names become nil. A missing
name does not make an otherwise known identity unavailable.

Socket open publishes `status: :connected` independently of identity availability
and starts an asynchronous lookup. `ConnectionWorker.status/1` reads cached state
without querying the transport. Lifecycle action metadata (excluding category/source) and status snapshots have
the same fields (here `attempt` is the current opaque reference):

```elixir
%{profile: "setup-session", attempt_id: attempt,
  event: :connection_update, status: :connected, qr: nil,
  identity: nil, identity_status: :pending, identity_error: nil}

%{profile: "setup-session", attempt_id: attempt,
  event: :identity_updated, status: :connected, qr: nil,
  identity: %{phone_number: "+15551234567", display_name: nil,
              account_jids: ["15551234567@s.whatsapp.net", "987654@lid"]},
  identity_status: :available, identity_error: nil}

# A subsequent status/1 query returns the same identity, with event: :status.
```

`identity_status` is `:pending`, `:available` or `:unavailable`. Pending and
available have `identity_error: nil`; unavailable has `identity: nil` and a fixed
error: `:not_connected`, `:unsupported`, `:unavailable`, `:timeout` or `:failed`.
Transport errors/exceptions/exits never turn a healthy connection into a failed
connection or expose raw error terms. A missing callback reports `:unsupported`.

`ConnectionWorker.refresh_identity(worker)` returns `:ok` immediately while
connected, or `{:error, :not_connected}` otherwise. It clears the previous cached
identity, publishes `:identity_pending` when a new lookup starts, and eventually
publishes `:identity_updated`. Concurrent requests coalesce. Unsupported transports
remain unavailable without starting a lookup. Each socket-open event retries;
there is no automatic polling between opens. Hosts may explicitly refresh for a
late name or previously unavailable identity. Both history flags remain unchanged.
Amarula 0.5.10 may only learn the account name from history, so refresh cannot
guarantee a name when history is disabled. Hosts must support an absent name.

Each lookup has a worker deadline of 2,500 ms by default; pass
`identity_timeout_ms: milliseconds` at the top level of `listener_child_specs/2`
options to use 1..5,000 ms. Amarula's individual state/credential calls each have
a 1,000 ms timeout. Expired queries are terminated. Results are guarded by both
attempt and request tokens. Pairing, authentication progress, QR expiry,
disconnection, failure, explicit reconnect and logout invalidate cached and
pending identity. Even an unsuccessful logout clears the cached identity;
refresh or reconnect is required to recover it. Persisted authenticated sessions
recover identity on open without another scan. Another profile or an old query
cannot replace the current identity, including within a protocol reconnect that
retains the attempt ID.

Lifecycle callbacks now run asynchronously in order in a worker-owned linked
process, so callbacks may call `status/1` or `refresh_identity/1` without a
reentrant deadlock. A callback's snapshot can be older than a fresh status query.
Except for explicit `:runtime_not_ready`, callback errors are discarded without
raw logging or retries; hosts should keep
callbacks short and own durable delivery if needed. Shutdown stops this process
and any pending lookup. No runtime supervisor is introduced. The chat sink's
existing behavior is unchanged.

For managed QR-first setup, `PairingSession` owns the isolated profile, bounded
temporary storage, expiry, owner monitor and confirmation handoff. It requires a
fresh displayed identity/attempt before confirmation. The host authorizes each
command and owns UI, connector creation and encrypted persistence through trusted
callbacks. Low-level listeners remain available for hosts with their own pairing
orchestration. See [managed storage and pairing](#managed-storage-and-pairing).

## Managed storage and pairing

Start managed storage explicitly once per BEAM node, before preparing storage,
confirming pairing or starting managed listeners:

```elixir
children = [
  {Jido.Chat.WhatsApp.Storage.Runtime,
   require_ram_schema: true,
   max_value_bytes: 1_048_576,
   max_scope_bytes: 16_777_216},
  {DynamicSupervisor, name: MyHost.Connections, strategy: :one_for_one}
]
```

These validated init options are immutable. Restart infrastructure to change them.
The Mnesia OTP dependency starts with the application, but package tables are
created only by this explicit child. It is separate from automatic Amarula
transport ownership and works with `start_runtime: false`. File, DETS and custom
backend consumers need not start managed storage. Duplicate starts fail normally.
No global host configuration is overwritten. `require_ram_schema: true` rejects
a disk schema; the default allows a host disk schema while keeping this package's
table strictly local RAM. This is not a replicated/quorum store.

`Storage.Mnesia.ready/0` returns `{:ok, {owner_pid, generation}}` or
`{:error, :storage_unavailable}`. Startup is separate from readiness: unavailable
tables are reconciled, operations fail closed, and old handles cannot recover by
silently attaching to a new generation. Managed listeners are notified/monitored
and pause connections on storage loss. Workers remain responsive and retry
readiness every 100 ms, including when started during an outage, without consuming
the host supervisor restart budget. Recovery creates a fresh connection and storage
handle; stale attempts cannot deliver messages. Backend replacement preserves live
tables and does not restart unrelated listeners.
Mnesia/node restart loses RAM records. Shutdown never stops shared Mnesia or
deletes its tables. Pairing credentials should remain in host durable storage.

Use the backend directly as `storage: {Storage.Mnesia, scope: tenant_key}` or
compose it with an authorized host document callback:

```elixir
storage_opts = [
  profile: "support",
  scope: {tenant_id, credential_id},
  context: binding,
  sink_mfa: {MyHost.Ingress, :emit, []},
  volatile_namespaces: ["session", "sender_key"]
]

storage = {Jido.Chat.WhatsApp.Storage.Split, storage_opts}
```

The sink receives a private `Storage.Request` struct with `binding` and `request`
fields, followed by callback options. Requests use `:get`, `:put`, `:delete`,
`:clear`, `:list_keys` and `:delete_namespace`, with string namespaces and
Base64-encoded uncompressed Erlang term keys/values. The host must authorize every
request and provide encryption and transactional durability. A `:list_keys`
request for `"__binding_check__"` returns `{:ok, []}` only when the binding is current;
the backend checks this before RAM operations. Use `:error` only for missing
records; failures return `{:error, reason}`. `Split.prepare/1` removes obsolete
durable volatile namespaces. `Split.seed/2` authorizes and seeds RAM records once.
Host scope must distinguish credential generations and tenants.

For managed onboarding, call `PairingSession.execute(request, owner_id, opts)`
only after host authorization. Begin request is `%{op: :begin, owner: browser_pid}`;
later requests are `%{op: :status | :retry | :cancel | :confirm, session: pid}`.
Begin options require `:supervisor`, stable binary `:attempt_id`, `:context`, and
`:sink_mfa`. Optional `:ttl_ms` defaults to 180,000 (maximum 600,000); `:adapter`,
`:transport` and `:connect_opts` support transport injection. Owner ID must be
non-nil and match on subsequent calls. Owner process loss or expiry discards
temporary state. The host must reauthorize every command.

The sink receives a redacted `Pairing.Request` struct containing the configured
`context` and a `request` map, followed by callback options. For `execute/3`,
persistence carries `%{op: :persist, attempt_id: id, identity: identity,
records: durable_snapshot}`. The host saves atomically and idempotently by attempt
ID, returning `{:ok, %{receipt: public_receipt, storage: split_storage_opts,
runtime: opaque_runtime_context}}`. Split options use the same trusted sink.
The package stops protocol writes before freezing and retains the snapshot after
a failed save. After one-time RAM seeding, the sink receives
`%{op: :start, runtime: opaque_runtime_context}` and returns `:ok` or an error.
A saved receipt includes `runtime_pending: true` if seeding or activation fails.
Duplicate confirmation returns the same saved receipt without repeating the save.

Pairing requests run in bounded tasks (at most ten seconds and the remaining
session lifetime). A timeout may leave an uncertain durable commit: explicit
retries must reuse the attempt ID. Context, credentials and callback errors are
redacted. The package does not know the host's users, SQL schema or encryption.
QR/status is for trusted display only. Both authentication entry points use the
same sink; private requests never pass through public event routing or serialized
message State.

For rollout, stop existing/provisional connections before switching store ownership.
Do not copy live volatile sessions or run parallel old/new writers. Retain host
encrypted pairing; fresh RAM sessions may temporarily prevent decryption until
the protocol re-establishes keys. Rollback follows the same stopped-runtime rule.

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

Jido.Chat 1.2.1 has `get_user/2` for a supplied user ID, but no authenticated
self-account callback; the optional Transport callback fills that gap. No
upstream change blocks this identity API. Guaranteed account names with history
disabled would require an upstream authenticated name source in Amarula; this
implementation deliberately promises only an optional name.

The host must route lifecycle actions through its existing sink and provide a bounded
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
  sink_mfa: {MyApp.Ingress, :emit, []})
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
optional `account_identity/1`, `account_jids/1`, health and logout callbacks.
Without `account_identity/1`, authenticated identity is explicitly unavailable;
`account_jids/1` still independently supports self/mention detection. Without
`account_jids/1`, alias-based self mentions cannot be identified. Without health,
persistence guarantees belong to that transport. `account_jids/1` now normalizes
and deduplicates Amarula device aliases; its tuple/list contract is unchanged.
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

## ZAQ migration handoff (work-fqt)

Register a handler before accepting listener notifications. Minimal standalone
routing example (the adapter registry supplies `action.adapter` during routing):

```elixir
alias Jido.Chat
alias Jido.Chat.{ActionEvent, EventEnvelope}
alias Jido.Chat.WhatsApp.Adapter

chat =
  Chat.new(adapters: %{whatsapp: Adapter})
  |> Chat.on_action("connection_update", fn
    chat, %ActionEvent{
      adapter: Adapter, adapter_name: :whatsapp,
      metadata: %{category: :connection_lifecycle} = lifecycle
    } ->
      # After host validation of current profile/source/attempt ownership:
      %{chat | metadata: Map.put(chat.metadata, :whatsapp_status, lifecycle)}

    chat, _unrelated_action -> chat
  end)

# In the existing sink's envelope branch (never transform_incoming/1):
%EventEnvelope{event_type: :action, adapter_name: :whatsapp} = envelope
{:ok, result} = Chat.route_event(chat, :whatsapp, envelope)
updated_chat = result.chat
```

The example's metadata is in-memory state, not permission to persist QR data.
Production consumers must validate the envelope's adapter name before selecting
the router adapter, and the action ID/category and registered adapter identity.
Jido enriches the action's adapter from its registry; it is not an authenticity
check on untrusted input. Listener callbacks are trusted internal boundaries.

ZAQ currently registers no lifecycle action handler and its synchronous envelope
`State.handle_call` discards the routed Chat state. It is **not compatible yet**.
Before switching the dependency, ZAQ must:

1. Route typed envelopes through the existing `sink_mfa`; leave plain chat
   normalization on its existing path.
2. Register `on_action("connection_update", ...)` with adapter/category guards.
   Preserve `result.chat` and apply status/QR/identity to the owning State before
   replying to `process_listener_payload`'s `GenServer.call`. Do not call that same
   State GenServer from inside its synchronous action handler.
3. Preserve originating `metadata.source`, `profile` and `attempt_id` through
   every hop. Compare them with current ownership, reject retired workers and
   attempts, and clear old QR/identity on every adapter clearing transition.
   Do not infer source from callback `self()` or replace it with the current worker.
4. Establish handler/source registration before accepting events. Return
   `{:error, :runtime_not_ready}` without side effects while registration is
   incomplete; complete registration outside the action handler, without
   reentering listener startup. Reconcile status for delayed QR display.
5. Keep QR confidential, keep Pairing orchestration/confirmation authorization,
   and preserve synchronous status visibility to callers. Add consumer tests for
   early delivery, retired sources/attempts, QR clearing, and saved runtime pending.

Keep this library change isolated until that consumer migration is ready. No ZAQ,
shared Jido core, dependency, storage policy, listener supervision or authentication
command changes are part of this epic. The previous upstream comparison and fork
extensions above remain applicable; this restores the shared action transport
while retaining the fork's sanitized lifecycle interpretation and isolation.

## Recovery during provisional pairing

The optional transport `recovery_status/1` returns only `:reconnecting` or
`:failed`. Amarula classifies its disconnected/connecting state as recovering
and its exhausted/closed or unavailable connection as failed. Worker errors and
disconnected updates use this evidence; custom transports without it retain
terminal error behavior. Raw error data never enters lifecycle metadata.

A recoverable error clears QR/identity and emits `status: :reconnecting` through
the same lifecycle action sink. `PairingSession` projects this as pending, so
hosts must keep polling within the existing session lifetime. Socket open still
controls connected status; device pairing success alone does not confirm login.

Provisional `:retry` preserves the session, profile, temporary credentials and
original expiry. It waits during authentication/recovery, returns confirmation
for an already connected account, refreshes missing identity without reconnecting,
and reconnects only a stopped/failed/expired connection. Hosts must not implement
Retry by cancelling and beginning a new session. Only an expired session or an
explicit start-over should create another pairing session.

## Shared connection presentation

`Pairing.presentation/1` owns the safe connection-state projection and human-readable
summary. `PairingSession` reuses it, adding only onboarding-specific confirmation
and identity states. Lifecycle ActionEvent metadata carries the same projection
in `:presentation`: phase, status, summary, mode, QR, attempt ID and expiry.
Raw lifecycle status/profile/source/attempt metadata is unchanged; worker `status/1`
remains a plain snapshot. Hosts consume the supplied presentation and retain
their own source fencing and runtime-loss handling rather than remapping provider
states or duplicating provider messages. QR appears only during pairing.

## Shared authentication capability (work-9ya)

The optional `:authenticate` capability uses `Jido.Chat.Adapter.authenticate/4`.
See the core `guides/authentication.md` for the provider-neutral schema. WhatsApp
implements it through the existing `PairingSession`; `execute/3` retains its
`identity/records`, `storage/runtime`, PID handles and status shapes.
The shared path opts into translation, not another session runtime.

Begin trusted options are `:supervisor`, `:owner` (monitored PID), `:attempt_id`,
`:context`, and `:sink_mfa`. Transport/connect options and bounded `:ttl_ms`
retain their existing meaning. The same sink receives private `Pairing.Request`
and `Storage.Request` structs with distinct operation contracts.

For shared authentication, the pairing persistence request contains
`%{op: :persist, attempt_id: id, account: normalized_account,
credentials: encoded_credentials}`. The host returns
`{:ok, %{receipt: public_receipt, binding: opaque_binding, runtime: opaque_runtime}}`.
The binding must be stable and non-nil. The package derives the profile and RAM
scope, prepares Split storage options with the same sink, and authorizes RAM seeding.
Hosts use `Adapter.connection_options(binding, sink_mfa: trusted_sink)` for saved
startup; generic host pairing code does not construct Split options or encode records.

The activation request contains `%{op: :start, runtime: %{runtime: opaque_runtime,
binding: binding, connection_options: options}}`. A receipt is retained even if
binding validation, seeding or activation fails. Only allowlisted receipt fields
reach shared status. The `execute/3` entry point retains its identity/records and
storage/runtime payload shapes inside the same typed requests. Lifecycle delivery
continues through the configured sink using `connection_update` ActionEvents.

### Host activation example

```elixir
# In the trusted sink handling a Pairing.Request with op: :start:
# payload = %{binding: binding, runtime: saved_config, connection_options: options}
ingress = Map.merge(payload.connection_options, %{mode: :linked_device})
# Feed ingress into the host's existing saved-listener startup/sync operation.
# Adapter.listener_child_specs(saved_id, ingress: ingress, sink_mfa: existing_sink)
```

The options' `profile` and `storage` belong at the ingress top level. Preserve
both unchanged. The opaque binding must remain stable across host restarts (use
persistent tenant/configuration/credential IDs, not process IDs or transient
actor context). `connection_options/2` deterministically reconstructs the same
profile and scope. The sink must reject revoked or mismatched
bindings; a non-nil binding alone is not authorization. Encoded credentials retain
the existing tuple-keyed map format for BEAM dispatch; they are not JSON records.

Seeding's host binding check is also bounded to ten seconds and remaining session
lifetime. No new callback starts after that lifetime has elapsed. A shared confirm
call permits up to forty seconds for the bounded persistence, seed and activation
stages to finish and return the durable receipt. If the whole session expires
after an uncertain save, the host must reconcile the original attempt ID through
its durable idempotency record before starting another onboarding attempt.


## Private synchronous storage requests

Hosts provide `sink_mfa` for saved connection options and shared authentication.
`Adapter.prepare_connection/1` requests an opaque binding with `op: :bind`, derives the existing stable profile,
and prepares split storage before listener registration. The configured sink
receives a private `Storage.Request` struct and options, and returns the existing
`:ok`, `:error`, `{:ok, value}`, or `{:error, reason}` result after host persistence
commits. `:error` means an absent record; unavailable or unauthorized storage is
an error tuple. Request inspection excludes bindings and record data.

Hosts must route these requests before their serialized message State and must
never accept them from public webhooks, chat action handlers, or lifecycle queues.
Only trusted host initialization configures this sink. A request/binding is not
itself authority to read a credential. Every access, including RAM authorization,
must revalidate the binding and provider. Encryption and transactions remain host
responsibilities. The package invokes no host persistence modules directly.

Requests run in a bounded Task, with a seven-second deadline outside the host's
shorter persistence deadline. Exceptions and invalid callback responses become
`:storage_unavailable` without retaining sensitive details. An ambiguous timeout
must not trigger an automatic retry or overwrite of state. Hosts should make
writes idempotent and acknowledge only after commit. Task termination does not
undo a transaction already committed remotely.

Pairing confirmation and saved runtime storage use the same configured sink.
`storage_runtime_spec/1` lets hosts supply deployment policy while the package
owns runtime implementation. Pairing requests use their separate ten-second
session deadline; storage requests retain the seven-second deadline above.

## Explicit logout

`Jido.Chat.WhatsApp.Adapter.logout(listener)` is an optional adapter extension,
not a shared `Jido.Chat.Adapter` behaviour callback or capability. It delegates
unchanged to `ConnectionWorker.logout/1`. The host supplies the exact running
listener as a `GenServer.server()` reference after authorization and runtime
selection. No configured logout MFA is required. `sink_mfa` continues to carry
messages, lifecycle notifications and private storage requests.

Results are `:ok`, `{:error, :logout_failed}` for transport logout failure,
`{:error, :storage_unavailable}` during pending storage recovery, and
`{:error, :unsupported}` if the transport has no logout callback. Standard
`GenServer.call/2` exits, including missing listeners and timeouts, propagate;
callers must treat an uncertain result as failure and reconcile before retrying.

Success retains the transport's existing best-effort provider unlink and local
credential/session clearing semantics for that profile, and emits `:logged_out`
through the existing lifecycle sink. A sibling profile is unaffected. The worker
remains alive with logged-out status; the host owns its supervision and removal.
Ordinary listener stop/shutdown preserves saved credentials and is distinct from
explicit logout. Provider acknowledgement while disconnected is not guaranteed.

For the ZAQ follow-up, resolve the configured adapter and detect its optional
`logout/1` export. Preserve actor authorization, exact listener selection,
fail-closed explicit logout, Disable confirmation, disable-before-delete ordering
and retry handling. Delete preparation remains a no-op for adapters without this
extension. Remove the consumer's logout MFA configuration and fixtures when it
adopts the library revision exposing this API.
