# AGENTS.md - Jido Chat WhatsApp Development Guide

`jido_chat_whatsapp` is the WhatsApp linked-device adapter for `Jido.Chat`.

## Commands

- `mix setup` - Fetch dependencies.
- `mix test` - Run the default non-live test suite.
- `mix test --include live` - Run explicitly enabled live WhatsApp tests.
- `mix quality` - Run the Jido package quality gate.
- `mix coveralls` - Run coverage.
- `mix install_hooks` - Explicitly install local git hooks.

## Rules

- Keep live WhatsApp tests excluded by default with the `:live` tag.
- Do not commit `.env`, credentials, QR strings, pairing codes, or Amarula profile storage.
- Prefer `Jido.Chat.Adapter` callbacks for shared behavior.
- Preserve the adapter boundary; supervised runtime concerns belong in `jido_messaging`.
- Keep the Amarula dependency behind `Jido.Chat.WhatsApp.Transport` so another WhatsApp transport can be added later.

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
