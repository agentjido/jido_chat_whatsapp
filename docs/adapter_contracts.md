# Linked-device adapter contracts

## Ownership and flows

### Media references

Linked-device media ingress emits a normalized `EventEnvelope` containing an
`Incoming` with public attachment metadata and an opaque
`whatsapp://media/v1/...` reference in `media.url` and `media.metadata.file_id`.
Private download descriptors are removed from media metadata and both `raw`
maps are empty. Hosts preserve the reference unchanged and call
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

## Public contract (work-5rb)

Existing message sink `{module, function, args}` receives `args ++ [payload, opts]`.
An optional `lifecycle_sink_mfa` uses the same invocation shape and receives a
plain map with `profile`, `attempt_id`, `event`, `status`, `qr`, `identity`,
`identity_status` and `identity_error`. QR data is
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
without querying the transport. Lifecycle events and status snapshots have the
same shape (here `attempt` is the current opaque reference):

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
Callback errors are discarded without raw logging or retries; hosts should keep
callbacks short and own durable delivery if needed. Shutdown stops this process
and any pending lookup. No runtime supervisor is introduced. The chat sink's
existing behavior is unchanged.

For QR-first setup, the host owns a temporary isolated profile and storage,
consumes the dedicated lifecycle sink, and uses a fresh status snapshot before
confirmation. Require the expected profile/attempt, `status: :connected` and
`identity_status: :available`; tolerate nil phone/name as product policy permits.
The adapter never creates a channel or confirms a user decision. Temporary
sessions, UI, channel creation and encrypted session transfer remain host work.

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
