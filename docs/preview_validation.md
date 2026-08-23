# WhatsApp Preview Validation

This adapter uses the WhatsApp linked-device protocol through Amarula. It is a
preview. The local tests prove the adapter boundary. They do not prove that a
WhatsApp account can pair, reconnect, receive, or send at release time.

## Automated Checks

These checks do not use a WhatsApp account or the network:

```bash
mix test test/jido/chat/whatsapp/preview_integration_test.exs
mix test test/jido/chat/whatsapp/connection_worker_test.exs
mix test test/jido/chat/whatsapp/adapter_test.exs
mix test test/jido/chat/whatsapp/message_test.exs
mix test test/jido/chat/whatsapp/transport/amarula_client_test.exs
```

The preview integration test uses local transports and a local sink. It proves
this chain:

1. `ConnectionWorker` receives an Amarula `:messages_upsert` event.
2. The worker makes a plain payload and calls the configured sink.
3. The sink normalizes the payload to `Jido.Chat.Incoming`.
4. The sink sends a quoted reply through `Adapter.send_message/3`.

This test does not start `jido_messaging`. The adapter package must not own the
supervised runtime. A live receive-to-reply test through `jido_messaging` is a
release gate.

## Pairing and Stored-Session Check

Use a dedicated test account. Keep the Amarula storage directory outside the
repository. Give the directory access only to the service account.

```bash
export AMARULA_DATA_DIR="/var/lib/my_app/amarula"
mkdir -p "$AMARULA_DATA_DIR"
chmod 700 "$AMARULA_DATA_DIR"

mix jido_chat_whatsapp.pair agent_primary --timeout 180
```

Use the adapter task, not `mix amarula.pair`. Amarula 0.5.7 can log the raw QR
text if its terminal renderer fails. The adapter task redacts the QR and renderer
error data on this failure path. A non-live regression test uses a secret
sentinel to enforce this rule.

The adapter task is QR-only. Do not use phone-code pairing with Amarula 0.5.7.
That release logs the raw phone pairing code. Phone-code mode can return only
after an Amarula release provides verified safe redaction.

Do not save the QR text or pairing code in logs, screenshots, issue comments, or
test output. Record only the profile name, package versions, test date, and final
connection state.

Use this procedure:

1. Confirm that the QR image is clear and that a new QR replaces an expired QR.
2. Pair the device and wait for `connection: :open`.
3. Stop the BEAM process. Do not delete or move the profile storage.
4. Start the listener with the same profile name and storage root.
5. Confirm that it reaches `connection: :open` without a new QR.
6. Send one inbound test message. Confirm one normalized inbound event.
7. Let the real `jido_messaging` bridge make one reply. Confirm one delivered
   outbound message in the same chat.

## `401` Reconnect Limit

Amarula handles a `515` stream error as a required reconnect after pairing. This
is expected. A `401` stream error is different. It means that WhatsApp rejected
the stored login state.

The adapter does not add a reconnect loop. Amarula owns reconnect attempts and
uses `max_retries`. Its default is 5. For release validation, set the value to 0:

```bash
RUN_LIVE_WHATSAPP_TESTS=true \
WHATSAPP_PROFILE=agent_primary \
WHATSAPP_TEST_JID=15551234567@s.whatsapp.net \
WHATSAPP_STORAGE_ROOT="$AMARULA_DATA_DIR" \
WHATSAPP_MAX_RETRIES=0 \
mix test test/jido/chat/whatsapp/live_integration_test.exs \
  --include live --only whatsapp_live_connectivity
```

With this value, Amarula does not schedule an automatic retry. The live suite
has one explicit reconnect budget for its full run. It fails before a second
call to `Amarula.reconnect/1`. A deterministic non-live test enforces this
budget.

Use this safe rejected-session procedure:

1. Create a new disposable profile with the safe adapter pairing task. Do not
   use a production account or production profile.
2. Stop and start the disposable profile. Confirm that the stored session opens
   without a new pairing prompt.
3. Start the command below. While it waits, use WhatsApp on the phone to unlink
   only this disposable linked device. This invalidates the stored session
   without editing credential files.

   ```bash
   RUN_LIVE_WHATSAPP_TESTS=true \
   RUN_LIVE_WHATSAPP_401_TEST=true \
   WHATSAPP_PROFILE=agent_disposable_401 \
   WHATSAPP_TEST_JID=15551234567@s.whatsapp.net \
   WHATSAPP_STORAGE_ROOT="$AMARULA_DATA_DIR" \
   WHATSAPP_MAX_RETRIES=0 \
   mix test test/jido/chat/whatsapp/live_integration_test.exs \
     --include live --only whatsapp_live_rejected_session
   ```

4. The test must see this sequence: one `{:stream_error, 401, _}` error, then
   one `connection_update: :closed` event, then no `:connecting` event during
   the 30-second observation window.
5. If unlinking does not produce the exact `401` sequence, do not damage or edit
   stored credentials to force it. Record the gate as `not run`, not passed.
6. If the test sees another `401` or any reconnect after the first `401`, mark
   the gate as failed.

Keep the disposable profile storage for diagnosis. If you must pair again, use
a new profile name. Do not add an unbounded supervisor restart loop around the
connection worker.

For a preview deployment, set an explicit finite `max_retries` value in the
listener Amarula configuration. Monitor `:error` and
`connection_update: :closed` events. A repeated `401` needs operator action. It
must not cause a permanent retry loop.

## Security Boundary

Linked-device ingress is not webhook ingress. There is no inbound HTTP request
and there is no provider webhook signature to verify.

`Adapter.verify_webhook/2` is a compatibility no-op from the shared adapter
contract. It does not authenticate linked-device events. Do not expose it as the
security check for a public HTTP endpoint.

The trust boundary is the local BEAM node and the Amarula connection process.
Only trusted code must be able to send messages to the connection worker or call
the configured sink. Do not accept copied `{:amarula, ...}` tuples from an
untrusted network source.

Treat these values as credentials:

- Amarula profile storage
- QR text and QR images
- phone pairing codes
- linked-device session data

Keep them out of Git, logs, test fixtures, crash reports, and issue comments.
Restrict the storage path with operating-system permissions.

## Release Gates

Automated checks are necessary, but they are not sufficient for release. The
preview can be released only after all applicable live gates have a dated result:

- QR display, QR refresh, and successful pairing
- process restart with the stored profile and no new pairing prompt
- bounded `401` behavior with no retry loop
- one inbound message through the real `jido_messaging` bridge
- one agent reply delivered to the source chat
- one throttled outbound text smoke test

If a live gate cannot run, report it as not run. Do not report the adapter as
live-validated.
