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
    sink_mfa: {Jido.Messaging.IngressSink, :emit, [MyApp.Messaging, "bridge_wa"]}
  )

children = [Amarula.Supervisor | specs]
```

Start the shared `Amarula.Supervisor` before the generated connection workers.
Only one shared Amarula supervisor is needed in the host application's supervision tree.

On first pairing Amarula emits QR and pairing lifecycle updates. The worker
forwards those as non-message action events. Chat messages from
`:messages_upsert` are normalized into `Jido.Chat.Incoming`.

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
    storage_root: "/var/lib/my_app/amarula"
  }
}
```

## Pairing

Amarula ships a pairing task that can create the profile consumed by this adapter:

```bash
export AMARULA_DATA_DIR="$PWD/amarula_data"

mix amarula.pair agent_primary
mix amarula.pair agent_primary --phone 15551234567
```

Use the same profile name with `config :jido_chat_whatsapp, :profile` or with
per-call/listener `:profile` options.

The linked device will usually appear in WhatsApp as `Google Chrome (macOS)`.
That is expected: Amarula connects through the WhatsApp Web linked-device
protocol and presents a browser identity by default. QR pairing and phone-code
pairing both create the same kind of linked device.

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

Planned live coverage:

- QR pairing lifecycle
- receive-to-reply loop through `jido_messaging`
- image/video/audio-specific media sends
