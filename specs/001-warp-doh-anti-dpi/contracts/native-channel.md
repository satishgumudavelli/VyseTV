# Contract: Dart ↔ Android method channel `vyse/network`

Owner: `NetworkModesPlugin.kt` (Android). Client: `lib/data/network/network_channel.dart`. All calls are asynchronous; none may block the UI thread. On any other
platform the channel does not exist and the Dart side reports every mode as `unavailable`.

## Methods (Dart → Android)

| Method | Arguments | Success result | Errors (`code`: meaning) |
|---|---|---|---|
| `capabilities` | none | `{warp: bool, antiDpi: bool}`: whether this device has a binary for its ABI | none |
| `startWarp` | none | `{port: int}`: WARP is up and its HTTP proxy listens on `127.0.0.1:port` | `WARP_NO_BINARY`, `WARP_REGISTRATION_FAILED`, `WARP_START_FAILED`, `WARP_TIMEOUT` |
| `stopWarp` | none | `{}` (idempotent) | none |
| `startAntiDpi` | `{args: String}` | `{port: int}`: ByeDPI's SOCKS5 proxy listens on `127.0.0.1:port` | `DPI_NO_BINARY`, `DPI_BAD_ARGS`, `DPI_START_FAILED`, `DPI_TIMEOUT` |
| `stopAntiDpi` | none | `{}` (idempotent) | none |
| `status` | none | `{warp: {running, port?}, antiDpi: {running, port?}}` | none |
| `setProxy` | `{host: String?, port: int?, kind: 'http'|'socks'|null}` | `{}`: points the JVM's default proxy selector at the gateway (or clears it with `null`); loopback and private addresses always go `DIRECT` | none |

`error.message` is a sentence fit to show the viewer; `error.details` may carry a log tail (no keys, tokens or account ids).

## Events (Android → Dart), method `onModeEvent` on the same channel

`{mode: 'warp'|'antiDpi', state: 'exited', reason: String}` when a running process dies on its own. Dart then sets the mode to `failed(reason)`, the setting to off
and the route to direct. No other events.

## Behaviour guarantees

- `startWarp` registers an anonymous WARP client on first use and stores its config in the app's private files folder; later starts reuse it. It tries HTTP/3, then HTTP/2.
  It never falls back to a mode that turns off certificate pinning.
- `startAntiDpi` rejects `args` that set the listen address or port (`-i/--ip`, `-p/--port`, `-I/--conn-ip`) with `DPI_BAD_ARGS`, and always supplies `-i 127.0.0.1 -p <free port>` itself.
- At most one process per mode; a second `start` for a running mode with the same arguments returns the running port; with different arguments it restarts.
- A process left over from a crashed earlier run is stopped before a new one starts; all processes are stopped when the app exits.
- Start timeouts: WARP 15 s, Anti-DPI 5 s (then `*_TIMEOUT`, process killed).
