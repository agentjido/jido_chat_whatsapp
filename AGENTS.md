# Repository guidance

This package is a Jido Chat V3 provider adapter.

- Keep the Adapter stateless.
- Use an explicit `Jido.Chat.Client` for every request.
- Put inbound chat data through `Jido.Chat.WhatsApp.Source` and
  `Jido.Chat.Sensor`.
- Keep rooms, routing, agents, and history in Jido Chat core.
- Keep Amarula connection and session processes inside this package.
- Keep pairing, lifecycle, and storage callbacks private.
- Never put credentials, QR data, media keys, provider structs, or process
  identifiers in public Signals.
- Do not read profile or credential selection from application environment.
- Test provider behavior with offline transports. Do not make live provider
  calls unless the user gives explicit authority.
- Run `mix test` and `mix quality` before delivery.
