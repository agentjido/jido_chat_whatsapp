# Jido Chat WhatsApp

[![Hex.pm](https://img.shields.io/hexpm/v/jido_chat_whatsapp.svg)](https://hex.pm/packages/jido_chat_whatsapp)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_chat_whatsapp/)
[![CI](https://github.com/agentjido/jido_chat_whatsapp/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_chat_whatsapp/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_chat_whatsapp.svg)](https://github.com/agentjido/jido_chat_whatsapp/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

`jido_chat_whatsapp` is the WhatsApp linked-device adapter package for `jido_chat`.

## Release Status

This package is a preview adapter for the Jido 1.x chat package release line.
It uses [`Amarula`](https://hex.pm/packages/amarula) as the WhatsApp Web client.

`Jido.Chat.WhatsApp.Adapter` is the canonical adapter module.

## Installation

```elixir
def deps do
  [
    {:jido_chat_whatsapp, "~> 0.1.0"}
  ]
end
```

## Usage

Transform an Amarula-shaped payload:

```elixir
alias Jido.Chat.WhatsApp.Adapter

{:ok, incoming} =
  Adapter.transform_incoming(%{
    id: "msg-1",
    channel_jid: "15551234567@s.whatsapp.net",
    from_jid: "15557654321@s.whatsapp.net",
    type: :text,
    text: "hello"
  })
```

Send a message through an already running Amarula profile:

```elixir
{:ok, sent} =
  Adapter.send_message(
    "15551234567@s.whatsapp.net",
    "hi",
    profile: System.fetch_env!("WHATSAPP_PROFILE")
  )
```

For tests or supervised runtime code, pass `:conn` directly or inject a custom
`Jido.Chat.WhatsApp.Transport`.

## Linked-Device Listener

The adapter supports an Amarula-backed listener via `listener_child_specs/2`.
This is the expected mode for `jido_messaging` bridges.

```elixir
{:ok, specs} =
  Jido.Chat.WhatsApp.Adapter.listener_child_specs("bridge_wa",
    ingress: %{
      mode: "linked_device",
      profile: "agent_primary"
    },
    sink_mfa: {Jido.Messaging.IngressSink, :emit, [MyApp.Messaging, "bridge_wa"]},
    lifecycle_sink_mfa: {MyApp.WhatsAppStatus, :emit, ["agent_primary"]}
  )

children = specs
```

The `:jido_chat_whatsapp` OTP application starts the shared transport infrastructure
automatically. Hosts add only the generated listener specs to their supervision
tree. Application startup opens no profiles or network connections, including on
nodes without WhatsApp listeners.

When migrating a host that already supervises Amarula, remove that child before
using the default package-owned runtime. For a staged transition, set
`config :jido_chat_whatsapp, start_runtime: false` before application startup and
retain the host's existing infrastructure supervision/recovery. Remove that setting
when the host wiring is removed. The package never adopts an existing supervisor
or starts a second owner. This option is a boot-time setting.

The message sink receives chat payloads for `Adapter.transform_incoming/1`.
Pairing, QR and connection updates go only to the optional `lifecycle_sink_mfa`.
Both callbacks receive their configured arguments followed by `(payload, opts)`.
Lifecycle maps carry `profile`, `attempt_id`, `event`, `status`, `qr`, `identity`,
`identity_status` and `identity_error`; treat
that sink as a trusted credential display boundary. With no lifecycle sink,
these updates are discarded. This replaces the preview's mixed action/chat sink.
Only socket open reports `:connected`; pairing success reports `:authenticating`.
QR expiry reports `status: :expired` and `qr: nil`, retained in subsequent
`ConnectionWorker.status/1` snapshots. This differs from transport
`:disconnected`. A replacement QR restores `:pairing`; connection, reconnect and
logout replace expiry with their respective lifecycle statuses.

Authenticated account identity is fetched asynchronously on socket open. A
`:identity_updated` lifecycle event and `ConnectionWorker.status/1` expose only
`%{phone_number: "+15551234567", display_name: nil, account_jids: [...]}`.
Phone comes only from a PN alias; LID-only accounts have no inferred phone.
Unknown names remain nil. `:connected` is independent of `identity_status`
(`:pending`, `:available`, `:unavailable`). To fetch a late name or retry an
unavailable identity, call `ConnectionWorker.refresh_identity(worker)`; this
returns immediately and never enables history. A name is not guaranteed with
history disabled. Lifecycle callbacks run in order outside the worker and may
query status. The host owns confirmation, temporary profiles and channel creation.
See the [identity contract](docs/adapter_contracts.md#authenticated-account-identity-work-jut)
for deadlines, fixed errors, examples and clearing semantics.

The canonical incoming message includes `author.is_me`, `mentions`,
`was_mentioned`, `reply_context`, and accurate DM/group facts. Phone/LID aliases
come from the receiving connection through `Transport.account_jids/1`; no
recipient or timestamp heuristics are used. Broadcast/newsletter rooms are
unsupported. Group invocation policy remains with the host.

See [adapter contracts](docs/adapter_contracts.md) for lifecycle, storage,
compatibility, history delivery and host supervision requirements.

Linked-device events are local Amarula process messages. They are not HTTP
webhooks. `verify_webhook/2` is a compatibility no-op and is not an
authentication check. Do not expose it as the security check for a public HTTP
endpoint. See the [preview validation and security runbook](docs/preview_validation.md).

## Config

You can pass a profile per call:

```elixir
Adapter.send_message("15551234567@s.whatsapp.net", "hi", profile: "agent_primary")
```

Or configure a default profile:

```elixir
config :jido_chat_whatsapp, :profile, "agent_primary"
```

Bridge listener settings can include:

```elixir
%{
  ingress: %{
    mode: "linked_device",
    profile: "agent_primary",
    storage_root: "/var/lib/my_app/amarula",
    sync_history: false,
    sync_full_history: false
  }
}
```

## Host-provided storage and lifecycle

For package-managed RAM messaging state and QR-first onboarding, explicitly start
`{Jido.Chat.WhatsApp.Storage.Runtime, require_ram_schema: true}` before consumers.
`Storage.Split` combines authorized host persistence with the package Mnesia
backend. `PairingSession` owns temporary storage, identity confirmation and
handoff through host callbacks. See the [managed storage and pairing contract](docs/adapter_contracts.md#managed-storage-and-pairing).

For custom persistence, pass `storage: {MyApp.WhatsAppStorage, options}` in
`ingress`. The backend implements Amarula's profile-scoped storage callbacks;
custom storage takes precedence over `storage_root`. No fallback to file storage
occurs on callback failure. Encryption, atomic writes and durable storage are
host responsibilities. See the [callback contract](docs/adapter_contracts.md).

`ConnectionWorker.status/1` returns the current status. Use
`ConnectionWorker.reconnect/1` to stop and start with the same configuration and a
new attempt ID. Host supervisor shutdown stops the connection while retaining
session storage. `ConnectionWorker.logout/1` explicitly unlinks and clears the
profile; errors are returned. Duplicate live profile ownership is rejected.
Protocol reconnect and process restart are handled by Amarula; the host owns
bounded restart policy for the listener.
Shared infrastructure failure rebuilds the package transport tree and terminates
affected listeners so that policy can restart them with fresh attempt identities.
Startup waits at most five seconds for transport readiness. Stopping a listener
does not stop the shared runtime or other profiles. Stopping the package application
stops all its transport connections; stop host listeners first during planned shutdown.

Both history options default to `true`. `sync_history: false` suppresses history
imports, while `sync_full_history: false` requests a recent window when history
is enabled. Ordinary queued messages still arrive. Enabled imported messages
have `incoming.metadata.history == true`; the host must deduplicate by message
ID if history and live delivery overlap.

## Pairing

This adapter ships a QR-only pairing task that creates the Amarula profile:

```bash
export AMARULA_DATA_DIR="$PWD/amarula_data"

mix jido_chat_whatsapp.pair agent_primary
```

Phone-code pairing is disabled in this task. Amarula 0.5.7 logs the raw phone
pairing code. Keep the task QR-only until an Amarula release provides verified
safe redaction.

Use the same profile name with `config :jido_chat_whatsapp, :profile` or with
per-call/listener `:profile` options.

Use the [preview validation runbook](docs/preview_validation.md) to check QR
pairing, stored-session reconnect, bounded `401` handling, and the live release
gates. Keep QR text and Amarula profile storage out of Git and logs.

The linked device will usually appear in WhatsApp as `Google Chrome (macOS)`.
That is expected: Amarula connects through the WhatsApp Web linked-device
protocol and presents a browser identity by default. QR pairing and phone-code
pairing are linked-device operations, but this task permits QR pairing only.

## Live Integration Test

There is a live test module at:

- `test/jido/chat/whatsapp/live_integration_test.exs`

It is skipped by default. To run it after pairing a WhatsApp linked device:

```bash
cp .env.example .env
mix test test/jido/chat/whatsapp/live_integration_test.exs --include live
```

Set `RUN_LIVE_WHATSAPP_TESTS=true`, `WHATSAPP_PROFILE` to the paired Amarula
profile, and `WHATSAPP_TEST_JID` to the recipient chat JID. If you paired with a
non-default storage location, set `WHATSAPP_STORAGE_ROOT` to the same directory.

To include the interactive receive test, set `WHATSAPP_WAIT_FOR_REPLY=true` and
reply from the recipient WhatsApp account while the test is waiting:

```bash
RUN_LIVE_WHATSAPP_TESTS=true WHATSAPP_WAIT_FOR_REPLY=true \
  mix test test/jido/chat/whatsapp/live_integration_test.exs --include live
```

Fresh or restricted WhatsApp accounts may authenticate successfully but reject
outbound sends with server ack errors such as `{:send_rejected, "463"}`. To
verify linked-device connectivity without sending messages:

```bash
RUN_LIVE_WHATSAPP_TESTS=true \
  mix test test/jido/chat/whatsapp/live_integration_test.exs \
    --include live --exclude whatsapp_live_outbound
```

To test a single throttled outbound text message:

```bash
RUN_LIVE_WHATSAPP_TESTS=true WHATSAPP_LIVE_SEND_DELAY_MS=60000 \
  mix test test/jido/chat/whatsapp/live_integration_test.exs \
    --include live --only whatsapp_live_outbound_smoke
```

The send-heavy live tests are tagged `:whatsapp_live_destructive` and wait
`WHATSAPP_LIVE_SEND_DELAY_MS` plus optional `WHATSAPP_LIVE_SEND_JITTER_MS`
before each outbound test. Keep those tests opt-in for accounts with enough
WhatsApp reputation to tolerate edit/delete/reaction/media coverage.

Current live coverage:

- start one already paired Amarula profile for the suite
- linked-device connectivity and metadata checks
- single throttled outbound text smoke test
- send, edit, and delete text messages
- typing, metadata, and DM JID normalization
- stream fallback through core `Jido.Chat.Adapter.stream/4`
- lightweight quoted replies
- reaction add/remove
- local file uploads from disk paths and in-memory byte payloads
- canonical text and single-file posts through core `post_message/4`
- optional manual receive normalization when `WHATSAPP_WAIT_FOR_REPLY=true`
- unsupported-core contract checks

Current local preview coverage also includes a deterministic receive, normalize,
and quoted-reply chain through local fake transports. It does not start
`jido_messaging` and does not make a live-account claim.

Planned live coverage:

- QR pairing lifecycle
- receive-to-reply loop through `jido_messaging`
- execution of the stored-session and bounded `401` release gates
- image/video/audio-specific media sends
