# LLM Usage Rules for Jido Chat WhatsApp

`jido_chat_whatsapp` adapts WhatsApp linked-device behavior to the `Jido.Chat.Adapter` contract.

## Working Rules

- Keep shared chat behavior in `Jido.Chat.Adapter` callbacks.
- Keep live API tests tagged `:live` and excluded by default.
- Do not commit `.env`, credentials, QR strings, pairing codes, or Amarula profile storage.
- Treat WhatsApp JIDs as channel targets unless core adapter APIs explicitly add a richer abstraction.
- Preserve the adapter boundary; runtime supervision belongs in `jido_messaging`.
- Run `mix test`, `mix quality`, and `mix coveralls` before release work.
