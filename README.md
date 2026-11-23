# Jido Chat WhatsApp

`jido_chat_whatsapp` connects a WhatsApp linked device to Jido Chat V3. It
uses Amarula for the provider connection. The package supplies:

- a stateless `Jido.Chat.Adapter` for outbound requests;
- a push `Jido.Chat.Sensor.Source` for inbound Signals;
- a supervised linked-device worker;
- owner-scoped pairing and explicit logout;
- opaque, client-scoped media references.

The package does not own rooms, agents, routing, or message history. Jido Chat
owns those functions.

## Development setup

Mix fetches the pinned Jido Chat V3 source. Get dependencies and run the offline suite:

```bash
mix deps.get
mix test
mix quality
```

Live tests are excluded by default.

## Create a client

Every connection has an explicit profile. Do not use an application-wide
default profile.

```elixir
alias Jido.Chat.Client
alias Jido.Chat.WhatsApp

client =
  Client.new!(WhatsApp.adapter(),
    id: "support-whatsapp",
    config: [profile: "support"],
    transport: Jido.Chat.WhatsApp.Transport.AmarulaClient
  )
```

Use Jido Chat functions for outbound work:

```elixir
{:ok, sent} =
  Jido.Chat.send_text(client, "15551234567@s.whatsapp.net", "Hello",
    options: [profile: "support"]
  )

message_id = sent.data["result"]["id"]

{:ok, _} =
  Jido.Chat.add_reaction(
    client,
    "15551234567@s.whatsapp.net",
    message_id,
    "👍",
    options: [profile: "support"]
  )
```

The native operations are message send, finite stream send, file send, edit,
delete, typing, metadata, thread lookup, user lookup, media download, reaction
add or remove, and direct-message lookup. All other operations return an
explicit unsupported result without provider I/O.

## Start inbound delivery

Use the WhatsApp Source with a Jido Chat Sensor. The Sensor owns admission to
the host Signal path. The Source starts one linked-device worker for the
selected client and profile.

```elixir
children = [
  {Jido.Chat.Sensor,
   client: client,
   source: WhatsApp.source(),
   emit: "jido.chat.**",
   options: [
     profile: "support",
     config: %{
       profile: "support",
       sync_history: false,
       sync_full_history: false
     }
   ],
   dispatch: {:pid, target: self()}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Inbound provider values become validated message, edit, delete, reaction, or
normalization-failure Signals. Credentials, QR data, provider structs, storage
handles, process identifiers, media keys, and download URLs do not enter a
Signal.

## Pair a linked device

The terminal pairing task is for local operator setup:

```bash
mix jido_chat_whatsapp.pair support
```

An application can use `Jido.Chat.WhatsApp.authenticate/3` for an owner-scoped
pairing session. The host supplies its DynamicSupervisor, attempt identifier,
opaque context, and private persistence callback. The host must authorize each
request. A confirmation is valid only for the same owner and displayed account.

Pairing state is temporary. Successful confirmation transfers the selected
records to the host callback before the normal linked-device worker starts.

## Storage and cleanup

Amarula storage is explicit in the connection configuration. A host can use a
custom Amarula storage module or the package split store. The split store keeps
volatile protocol namespaces in Mnesia and sends durable requests to a private
host callback.

Clear one selected profile without opening a connection:

```elixir
Jido.Chat.WhatsApp.cleanup_connection(nil,
  profile: "support",
  storage: {MyStorage, state: state}
)
```

For an opaque host binding, also supply the authorized `:sink_mfa` callback.
Cleanup has a bounded timeout and does not report success after an uncertain
timeout.

## Media security

Inbound media uses an authenticated, encrypted reference. The reference is
scoped to one client profile and the linked device identity. Jido Chat Signals
contain only the opaque reference. `Jido.Chat.download_file/3` resolves it
through the selected connection and returns Base64 content.

## Live validation

Live validation is optional and can change a real account. Read
`docs/preview_validation.md` before use. The default test command does not make
provider calls.

## License

Apache-2.0. See `LICENSE`.
