# WhatsApp validation guide

## Offline validation

Run the complete default suite:

```bash
mix test
```

The suite uses offline Amarula connections and test transports. It checks:

- all native V3 operations;
- explicit unsupported operations;
- message, edit, delete, and reaction normalization;
- Sensor admission and Sensor-worker shutdown;
- pairing ownership and persistence safety;
- storage failure and runtime recovery;
- opaque media reference sealing and download;
- profile isolation and explicit logout.

Run the package gates:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix doctor --raise
mix docs
```

## Terminal pairing check

This check opens a real linked-device pairing flow. Use it only with explicit
authority and a disposable or approved profile.

```bash
mix jido_chat_whatsapp.pair support
```

Confirm these results:

1. The terminal shows a QR code.
2. The operator can cancel without saved credentials.
3. A successful scan persists only the selected profile.
4. Logs do not contain QR data, credentials, or media keys.
5. The task stops its temporary connection after success or timeout.

## Live V3 operation check

The live test file is excluded by default. It can send, edit, react to, and
delete real messages.

Required values:

```bash
export RUN_LIVE_WHATSAPP_TESTS=true
export WHATSAPP_PROFILE=support
export WHATSAPP_TEST_JID=15551234567@s.whatsapp.net
```

Run only the live file:

```bash
mix test --include live test/jido/chat/whatsapp/live_integration_test.exs
```

Set `WHATSAPP_WAIT_FOR_REPLY=true` only when an operator is ready to reply to
the test prompt. You can change the open and reply timeouts with
`WHATSAPP_OPEN_TIMEOUT_MS` and `WHATSAPP_REPLY_TIMEOUT_MS`.

## Acceptance record

Record the exact commands, the account class, the profile, and whether the run
changed provider state. Do not store phone numbers, QR values, credentials,
media keys, or raw provider payloads in the record.
