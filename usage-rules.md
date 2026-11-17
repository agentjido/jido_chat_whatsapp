# Usage rules

- Create an explicit `Jido.Chat.Client` with the WhatsApp Adapter.
- Select the linked-device profile in the client or operation options.
- Use `Jido.Chat` functions for outbound requests.
- Use `Jido.Chat.WhatsApp.Source` with `Jido.Chat.Sensor` for inbound Signals.
- Treat pairing, lifecycle notifications, and storage requests as private host
  callbacks. They are not chat facts.
- Treat media references as opaque. Resolve them only with
  `Jido.Chat.download_file/3` and the selected client.
- Supervise each Sensor or worker under the host application.
- Stop the Sensor to stop its linked-device worker.
- Use explicit logout or cleanup only for the selected profile.
- Keep live tests disabled unless a user authorizes a real account test.
