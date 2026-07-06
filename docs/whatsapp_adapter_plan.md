# jido_chat_whatsapp Implementation Plan

This plan tracks the first WhatsApp linked-device adapter package for `Jido.Chat`.
The selected client is `amarula`, a pure Elixir WhatsApp Web client available on Hex.

## Epic 1: Repository and Package Foundation

- [x] Scaffold `jido_chat_whatsapp` as a sibling Mix package.
- [x] Align Mix metadata, docs, package metadata, formatter, Credo, and CI files with `jido_chat_telegram` and `jido_chat_discord`.
- [x] Add `jido_chat ~> 1.0` and `amarula ~> 0.4.4` as published Hex dependencies.
- [x] Add local `.env.example` for live integration testing without committing credentials.
- [x] Prepare to create the GitHub repository under `agentjido`:

```bash
gh repo create agentjido/jido_chat_whatsapp \
  --public \
  --description "WhatsApp linked-device adapter package for Jido.Chat" \
  --source . \
  --remote origin \
  --push
```

## Epic 2: Adapter Contract

- [x] Implement `Jido.Chat.WhatsApp.Adapter` using `Jido.Chat.Adapter`.
- [x] Declare a capability matrix matching WhatsApp linked-device reality.
- [x] Normalize inbound Amarula messages into `Jido.Chat.Incoming`.
- [x] Normalize reaction payloads into `Jido.Chat.ReactionEvent`.
- [x] Emit connection, QR, pairing-code, pairing-success, and error updates as action events.
- [x] Keep unsupported surfaces explicit: fetch history, channel history, threads, modals, and ephemeral posts.

## Epic 3: Transport Boundary

- [x] Add `Jido.Chat.WhatsApp.Transport` behavior.
- [x] Add `Jido.Chat.WhatsApp.Transport.AmarulaClient` as the default implementation.
- [x] Resolve outbound connections by explicit `:conn` or configured `:profile`.
- [x] Support text sends, media sends, edits, revokes, reactions, chat state, and pairing-code requests.
- [x] Keep Amarula behind the behavior so `baileys_ex` or another client can be evaluated later without changing the adapter surface.

## Epic 4: Listener Runtime

- [x] Add `Jido.Chat.WhatsApp.ConnectionWorker`.
- [x] Support `listener_child_specs/2` for `ingress.mode = "linked_device"` / `"amarula"`.
- [x] Start an Amarula connection using bridge-scoped profile config.
- [x] Forward `:messages_upsert` events to runtime ingress via `sink_mfa`.
- [x] Forward QR and connection lifecycle events as non-message action events.
- [ ] Verify QR rendering and pairing UX in a live app once a test WhatsApp bot/account is available.

## Epic 5: Test Coverage

- [x] Unit test adapter metadata and capabilities.
- [x] Unit test inbound text/media normalization.
- [x] Unit test outbound transport delegation.
- [x] Unit test listener child spec construction.
- [x] Unit test connection lifecycle event forwarding.
- [x] Add a skipped-by-default live integration test scaffold.
- [ ] Add live receive/send loop tests after the WhatsApp account is paired.

## Epic 6: Review and Release Readiness

- [x] Run dependency fetch, compilation, formatting, and tests locally.
- [x] Review public API and docs before repository creation.
- [x] Create the GitHub repo with `gh`.
- [x] Push `main` and let GitHub Actions validate the standalone package.
- [ ] After live testing, decide whether the first Hex release should be `0.1.0` preview or align directly to the Jido 1.x package line.
