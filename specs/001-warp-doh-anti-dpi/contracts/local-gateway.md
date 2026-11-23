# Contract: the local gateway (loopback proxy for native players)

Owner: `lib/data/network/local_gateway.dart` (runs in a background isolate). Consumers: ExoPlayer (through `setProxy`) and mpv (its HTTP-proxy option).

## Listener
- Binds `127.0.0.1` only, on an ephemeral port, only while the route is not `direct`; the port is published to the controller, which hands it to `setProxy` and to mpv.
- Accepts at most 64 simultaneous client connections; extra ones are refused with `503`.

## Supported requests
| Request | Behaviour |
|---|---|
| `CONNECT host:port HTTP/1.1` | Resolves `host` with the current DNS choice, dials through the current route, answers `200 Connection Established`, then relays bytes both ways until either side closes. No TLS is terminated: end-to-end TLS is untouched. |
| `GET/HEAD/POST … http://host/path HTTP/1.1` (absolute URI) | Dials the same way and forwards the request, relaying the response (including `Range` requests and chunked bodies) unchanged. |
| anything else | `405` |

## Rules
- **Never reaches the local network**: destinations that are loopback, link-local, multicast or in private ranges (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7) are refused with `403`.
  (The proxy selector already sends those `DIRECT`; this is the second line of defence.)
- Route selection: `httpProxy(port)` → `CONNECT` to WARP's proxy, then the client's target through it; `socks5(port)` → SOCKS5 `CONNECT` to the target address (resolved with the DNS choice) then relays.
- DNS: with `socks5`/`direct` the target name is resolved by the DNS choice (DoH when set, system otherwise); with `httpProxy` the name is passed to WARP unresolved.
- Failure of the upstream (cannot dial, handshake refused) answers `502` to the client; it never falls back silently to a different route (the controller changes the route, not the gateway).
- Timeouts: 15 s to connect upstream; idle relay connections closed after 120 s of no bytes.
- Logs: counts and error kinds only; never URLs with query strings, headers or bodies.
