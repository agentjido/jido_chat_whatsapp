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
```

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
mix amarula.pair agent_primary
mix amarula.pair agent_primary --phone 15551234567
```

Use the same profile name with `config :jido_chat_whatsapp, :profile` or with
per-call/listener `:profile` options.

## Live Integration Test

There is a live test module at:

- `test/jido/chat/whatsapp/live_integration_test.exs`

It is skipped by default. To run it after pairing a WhatsApp linked device:

```bash
cp .env.example .env
mix test test/jido/chat/whatsapp/live_integration_test.exs --include live
```

Current live coverage is intentionally small until a test WhatsApp account is
available:

- send text through an already paired Amarula profile

Planned live coverage:

- QR pairing lifecycle
- inbound message receive
- receive-to-reply loop through `jido_messaging`
- media send
- reactions, edits, revokes, and typing state
