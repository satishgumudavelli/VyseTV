# Data Model: Network Modes

## Saved settings (device-local, included in backup)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `net.warp` | bool | `false` | WARP Mode switched on |
| `net.doh` | string | `'off'` | `off`, `cloudflare`, `google`, `adguard` or `custom` |
| `net.dohUrl` | string | `''` | the custom resolver address (only used when `net.doh == 'custom'`) |
| `net.antidpi` | bool | `false` | Anti-DPI Mode switched on |
| `net.antidpiPreset` | string | `'split_disorder'` | id of the chosen preset, or `'custom'` when parameters were edited |
| `net.antidpiArgs` | string | `''` | the parameters in use; empty means "the preset's parameters" |

Validation:
- `net.dohUrl`: must be an `https://` URL with a host, no user info, no fragment; rejected (previous value kept) otherwise. A bare IPv4/IPv6 address host is allowed
  (some resolvers are reached by address). Max 2048 characters.
- `net.antidpiArgs`: must not set the listen address or port (`-i/--ip`, `-p/--port`, `-I/--conn-ip` are refused), must not be longer than 512 characters, only
  printable ASCII; an empty value means "use the preset".
- Mutual exclusion is enforced by the controller, not by the stored values: if both `net.warp` and `net.antidpi` are true in a restored backup, WARP wins and
  Anti-DPI is stored as `false` (the viewer is told).

## Live state (not saved)

`ModeState` for each of WARP and Anti-DPI:

```
off ──start──> starting ──ok──> active(port)
                   │                │
                   └─fail──> failed(reason) ──(setting returns to off, route = direct)
active ──stop / process exits──> off | failed(reason)
```

Rules: `starting` has a timeout (WARP 15 s, Anti-DPI 5 s) after which it becomes `failed("timed out")`; a new request while `starting` cancels the previous
one (the last choice wins); `failed` is shown until the viewer acts again or the app restarts.

## Derived values

- **Route** (what the Dart connection factory and the gateway dial through): `direct` | `httpProxy(127.0.0.1, port)` (WARP active) | `socks5(127.0.0.1, port)` (Anti-DPI active).
  Never both (exclusion).
- **DNS choice**: `system` (Off) | `doh(provider URL)`. With route `httpProxy` the DNS choice is *not applied* (WARP resolves remotely) but stays saved.
- **Gateway**: `stopped` | `listening(port)`; listening exactly while the route is not `direct`.

## Anti-DPI preset

| Field | Meaning |
|---|---|
| `id` | `split_disorder` (default), `disorder`, `split`, `fake_oob` |
| `name` | shown name |
| `description` | one line shown under it |
| `args` | the parameters it stands for |

Initial presets (from the reference; may be tuned after testing): `split_disorder` "Recommended for all networks and CDNs"; `disorder` "Reorders the first byte to
bypass SNI inspection"; `split` "Splits the TLS handshake into 2 segments"; `fake_oob` "Aggressive bypass for strict firewalls".

## DNS provider

| Field | Meaning |
|---|---|
| `id` | `cloudflare`, `google`, `adguard`, `custom`, `off` |
| `label` | shown name (e.g. "Cloudflare (1.1.1.1)") |
| `url` | DoH endpoint (custom: the viewer's) |

Answers are cached per host for the session (existing behaviour in `net.dart`), and a failed lookup is not cached.
