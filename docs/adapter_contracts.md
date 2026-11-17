# WhatsApp V3 adapter contracts

## Boundary

The package has four public integration points:

1. `Jido.Chat.WhatsApp.adapter/0` returns the stateless Adapter.
2. `Jido.Chat.WhatsApp.source/0` returns the receive-only push Source.
3. `Jido.Chat.WhatsApp.authenticate/3` manages owner-scoped pairing.
4. `Jido.Chat.WhatsApp.cleanup_connection/2` clears one selected profile.

Jido Chat core owns clients, request and result Signals, Sensors, rooms,
bridges, routing, agents, durable messages, and authorization. This package
owns the Amarula transport and the linked-device session processes.

## Client selection

A Client identifies the Adapter, its stable client ID, and its transport.
Connection configuration is private and explicit. At minimum, it contains one
non-empty profile. A caller can give `:conn` or `:connection` in operation
options when it already owns a selected connection.

The package does not select a global profile. It does not use inbound sender
data as authenticated account identity.

## Outbound operations

The following operations are native:

- `stream_text`
- `send_message`
- `send_file`
- `edit_message`
- `delete_message`
- `start_typing`
- `fetch_metadata`
- `fetch_thread`
- `get_user`
- `download_file`
- `add_reaction`
- `remove_reaction`
- `open_dm`

Every other Jido Chat operation is `:unsupported`. Unsupported requests do not
make transport calls.

Operations accept checked request Signals and return checked canonical result
maps. Provider errors remain errors. The Adapter does not convert a transport
selection error into a successful result.

`stream_text` is finite. It renders the supplied stream and sends one final
WhatsApp message. WhatsApp does not expose partial token streaming.

File input uses a Base64 source map with a filename. The Adapter decodes it
before it calls the transport. Empty or invalid data returns an error.

## Inbound Source

`Jido.Chat.WhatsApp.Source` implements `Jido.Chat.Sensor.Source` in push mode.
Its key is derived from the transport and profile. The key prevents two
different Client configurations from sharing the wrong worker.

The Source starts `ConnectionWorker` with the Client, Sensor process, explicit
profile configuration, and selected transport. The worker monitors the Sensor.
When the Sensor stops, the worker stops and releases its connection.

Each worker has a child ID based on the Client ID. A supervisor can run more
than one profile at the same time.

## Normalization

The Normalizer accepts one provider value or a list. It returns one validated
`Jido.Chat.Delivery` with ordered Signals.

Supported input becomes:

- `jido.chat.message.received`
- `jido.chat.message.updated`
- `jido.chat.message.deleted`
- `jido.chat.reaction.added`
- `jido.chat.reaction.removed`

Unknown or invalid input becomes a deterministic
`jido.chat.normalization.failed` fact. A stable provider input produces stable
delivery and item identities.

Signals contain portable conversation and sender facts only. They do not
contain Amarula structs, credentials, QR values, process identifiers, storage
handles, media keys, or private download URLs.

## Identity

After a connection opens, the worker reads account identity asynchronously.
The query is bounded. It uses only the selected connection. The public status
contains an optional phone number, display name, and canonical account IDs.

Identity availability is separate from connection status. Failure to read a
name does not close a healthy connection. Refresh requests coalesce. A
reconnect, pairing event, error, logout, or timeout invalidates an old identity
result.

## Private lifecycle callback

A host can supply `:lifecycle_mfa` for sanitized connection state. This
callback is not a Signal admission path. It receives status, phase,
presentation, attempt identity, and safe account identity. Provider exceptions
and credentials are reduced to fixed failure categories.

The callback runs outside the worker. It can read worker status without a
deadlock. Callback failure does not put private data into chat Signals.

## Pairing

`authenticate/3` creates or commands one temporary `PairingSession`. The host
supplies:

- an owner process and opaque owner ID;
- a DynamicSupervisor;
- a stable attempt ID;
- opaque host context;
- a private persistence callback;
- optional transport and connection options.

Only the same owner can read, retry, confirm, or cancel the session. The user
must first see the selected account identity. Confirmation fails if the account
changes. Callback deadlines are bounded by the remaining pairing lifetime.

Temporary profile and Client identifiers are SHA-256 scopes of the attempt ID.
They are bounded and do not expose the attempt value to process names.

On confirmation, the session freezes temporary storage, calls the authorized
host persistence callback, seeds the selected durable runtime, and discards the
temporary copy. A repeated confirmation returns the same receipt.

## Storage

The default Amarula path can use a package-managed runtime, custom storage, or
an explicit split store.

The split store keeps volatile session namespaces in Mnesia. Durable requests
go to the private host callback with the opaque binding and context. Every
request requires host authorization. Read, write, delete, clear, seed, and
startup failure remain visible to the caller.

Logout clears only the selected profile. Normal worker stop preserves its
records. Offline cleanup validates the profile or binding, transport, callback,
and timeout before it starts work.

## Media references

The transport seals each media descriptor with AES-256-GCM. The key is derived
from the selected linked-device identity key and profile. The token has a fixed
version prefix and bounded plaintext and ciphertext sizes.

Open authenticates the token before safe term decoding. It rejects compressed,
trailing, malformed, over-size, wrong-profile, and wrong-key values.

The public Signal contains a `Jido.Chat.ResourceRef` with the Client ID, kind,
and opaque token. Download checks the Client ID and token bounds, resolves the
descriptor through the selected connection, downloads and decrypts the bytes,
and returns Base64 content.

## Runtime ownership

The application starts shared Amarula infrastructure but does not open a
profile. Source workers open profiles under the host supervision path. Loss of
the shared runtime generation stops affected workers so their supervisors can
restart them with the same explicit configuration.

Normal protocol child restarts remain behind the stable transport handle. A
stale handle cannot stop a newer owner of the same profile.

## Verification

The default suite is provider-free. It includes Adapter Test Kit checks,
property tests, runtime restart tests, storage failure tests, pairing safety,
identity isolation, and media security. Live tests are tagged and excluded by
default.
