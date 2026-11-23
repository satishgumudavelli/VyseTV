# Research: Network Modes (WARP, Secure DNS, Anti-DPI)

Sources: the Vega app (`/var/www/html/vega-app`: `WarpModule.kt`, `ByeDpiModule.kt`, `DohOkHttpFactory.kt`, `warpService.ts`,
`byeDpiService.ts`, `dohService.ts`, `DnsPreference.tsx`, `scripts/build-usque.ps1`, `scripts/build-byedpi.ps1`) and VyseTV
(`lib/data/net.dart`, `ExoPlayerCore.kt`, `build.gradle.kts`, `packages/torrserver_flutter`, `AppSettings`, `profile_page.dart`).
Nothing in the plan is left as "NEEDS CLARIFICATION"; items I could not verify offline are marked **to verify** and are listed in D9.

## What the reference does

- **WARP**: a Go program, *usque* (Cloudflare WARP over MASQUE, HTTP/3), shipped as `libusque.so` in the native-library folder and started as a
  child process. The app first registers an anonymous WARP client with Cloudflare's API and stores `config.json` in its private folder. It starts
  `usque -c config.json http-proxy -b 127.0.0.1 -p <port> -d 1.1.1.1 -d 8.8.8.8`, waits for "listening on", and sends the app's OkHttp traffic through
  that HTTP proxy. It tries three tunnel modes in order: HTTP/3, HTTP/2 (`--http2`, for networks that block UDP 443), and HTTP/3 without certificate
  pinning (`--insecure`). It uses `http-proxy`, not the layer-4 mode, so site names are resolved inside the tunnel (an ISP that poisons DNS cannot
  steer the lookup). Turning WARP on turns Anti-DPI off.
- **Anti-DPI**: *ByeDPI* v0.17.x (C), shipped as `libciadpi.so`, run as a child process: `ciadpi -i 127.0.0.1 -p <port> <args>`; it is a SOCKS5 proxy
  that splits/reorders/fakes the first packets of a TLS connection. Default args `--split 1 --disorder 1 --auto=torst`; four presets (split+disorder,
  disorder only, split only, fake packet OOB). The app refuses user arguments that set the listen address or port. Editing parameters restarts it.
- **Secure DNS**: an OkHttp `Dns` implementation using DNS-over-HTTPS with providers Cloudflare, Google, AdGuard, Custom, Off; with Anti-DPI on,
  DoH answers are used for the destination address; with WARP on, DNS is "managed by WARP (resolved remotely)".
- **State and UX**: toggles show "Active :<port>", toasts for connecting/connected/failed; a mode failing to start returns its switch to off;
  settings re-applied at launch (`syncWarpSettings`, `syncDohSettings`).

## Decisions

### D1 — Ship the two native programs the way TorrServer is shipped
**Decision**: Build usque and ByeDPI per ABI (arm64-v8a, armeabi-v7a) and place them as `libusque.so` and `libciadpi.so` in `android/app/src/main/jniLibs/<abi>/`.
Start them with `ProcessBuilder` from `applicationInfo.nativeLibraryDir`.
**Rationale**: VyseTV already does this for `libtorrserver.so`, and `build.gradle.kts` already sets `useLegacyPackaging = true` ("the torrent engine runs
as a program from the app's native-library folder"), so the files are unpacked and executable. Android 10+ blocks executing files from the app's *data*
folder, but not from the native-library folder; this is the same constraint Vega works within.
**Alternatives**: link usque/ByeDPI as JNI libraries (rewrites third-party code, two runtimes in one process); download binaries at first use (needs
code-signing/integrity handling and fails offline; Play-policy risk); use a system VpnService (a device-wide VPN: far more permissions and a consent
dialog, and spec Assumptions say no device-wide VPN).

### D2 — Reproducible builds, pinned versions
**Decision**: `scripts/build_usque.sh` and `scripts/build_byedpi.sh` check out a pinned commit, verify it, and cross-compile (Go with the NDK clang as
external linker for 32-bit; plain Go for arm64; NDK clang for ByeDPI), mirroring Vega's two PowerShell scripts; binaries are committed under `jniLibs`.
**Rationale**: same supply-chain posture as Vega; the machine has the NDK (`~/Documents/Android/Sdk/ndk`) but Go 1.18, and usque needs a newer Go: the script
must fetch the pinned toolchain (`GOTOOLCHAIN`). 16 KB page-size link flags are required for newer devices (as in Vega's script).
**Alternatives**: depend on prebuilt third-party release binaries (cannot audit; ABIs missing).

### D3 — One Dart controller owns settings, state and route
**Decision**: `NetworkModes` (a `ChangeNotifier`/`ValueNotifier` set) holds the three `Setting`s, the live state of WARP and Anti-DPI
(`off | starting | active(port) | failed(reason)`), enforces WARP/Anti-DPI exclusion, restores the saved mode at app start, and tells the rest of the app
the current *route* (`direct | httpProxy(port) | socks5(port)`) and *DNS* choice.
**Rationale**: a single source of truth makes the mutual exclusion, "last choice wins" and restore-failure behaviours (spec edge cases) testable without
the UI or the Android side.
**Alternatives**: keep state in the native plugin (hard to test, and the TV settings UI needs it in Dart anyway).

### D4 — Dart traffic follows the route through `HttpOverrides` and the existing connection factory
**Decision**: Generalise `lib/data/net.dart`: its `_connect` already receives every connection (`HttpClient.connectionFactory`), resolves names itself,
dials, and wraps TLS with the real host name. Extend it to (a) ask the controller for the DNS choice, (b) dial through the upstream route when a mode is
active: HTTP `CONNECT` for WARP, SOCKS5 for ByeDPI, then upgrade to TLS with the real host name, and (c) install it as `HttpOverrides.global` so images
(`cached_network_image`/`flutter_cache_manager`), `http.Client()` users and the updater follow too. Write the CONNECT and SOCKS5 handshakes in-repo
(about 100 lines).
**Rationale**: this is how VyseTV already survives blocked DNS (the file's own header comment), it is proven (the code is in production), and it keeps TLS
verification against the real host name. Dart has no built-in SOCKS support; a package for ~60 lines of protocol is not worth a new dependency.
**Alternatives**: a `findProxy` HTTP proxy only (cannot do SOCKS5 or DoH); a package such as `socks5_proxy` (new dependency, per-client setup).

### D5 — A local gateway for ExoPlayer and mpv
**Decision**: Run a loopback HTTP proxy (`CONNECT` for HTTPS, absolute-URI for HTTP) in a background isolate, listening on `127.0.0.1:<ephemeral>`. For each
request it dials with the same route/DNS code as D4. While a mode is on: ExoPlayer is pointed at it with `ProxySelector.setDefault` and uses
`DefaultHttpDataSource` instead of Cronet; mpv gets it as its HTTP proxy. Loopback and LAN destinations are refused by the gateway and never sent to it
(FR-017): the proxy selector returns `DIRECT` for them.
**Rationale**: Cronet (HTTP/2, QUIC) and mpv's network layer have no pluggable resolver; only a proxy reaches both. Without the gateway, Secure DNS would not
affect video streams, which is where DNS blocks hurt most. One implementation of route + DNS serves Dart and native code. Cronet is turned off only while a mode is
on, so default behaviour (and HTTP/2 multiplexing) is unchanged.
**Alternatives**: proxy only, no gateway (DoH ineffective on streams); an OkHttp data source (new dependency and only covers ExoPlayer, not mpv); doing nothing for
native players (the modes would then not "apply to the whole app", contradicting the spec's Assumptions).
**Risk**: one extra local hop in the playback path; **to verify** by a 4K stream test on the Mi TV (quickstart Q8). Fallback if the Dart gateway cannot sustain the rate:
the same logic in Kotlin inside the plugin (the contract in `contracts/local-gateway.md` does not change).

### D6 — Process lifecycle and failure behaviour
**Decision**: The Kotlin plugin starts a process, waits up to a few seconds for its "listening" line (WARP) or for the port to accept (ByeDPI), then reports
`active(port)`. A process that exits is reported as `failed(reason)` and the Dart controller switches the setting off and the route to direct. Processes are
stopped on mode off, on app exit, and a stale one from a crashed run is killed at start. WARP tries HTTP/3, then HTTP/2; the **`--insecure` (no certificate
pinning) fallback is not shipped**: failing safe is preferred to silently dropping a security check (a deviation from Vega, recorded for review).
**Rationale**: spec FR-005/FR-013/SC-006 require the app to keep working on its normal route after any failure.

### D7 — Settings, backup and UI
**Decision**: Add `AppSettings` entries `net.warp` (bool), `net.doh` (`off|cloudflare|google|adguard|custom`), `net.dohUrl` (string), `net.antidpi` (bool),
`net.antidpiPreset` (string), `net.antidpiArgs` (string), all in `_all` so backup/restore picks them up (FR-016). Build the section with the existing `_Section`
and D-pad focus widgets used elsewhere on the page; show state words as well as colour (FR-018). The ports are internal and not shown (spec dropped them).
**Rationale**: matches how every other device setting is stored; the settings page is one file of `_Section`s, and TV focus already works in it.

### D8 — Platforms
**Decision**: Android only for WARP and Anti-DPI (matching the spec). The Secure DNS control is pure Dart and the gateway is pure Dart, so on
Linux the same controls could work for DoH at almost no cost; the spec says unavailable elsewhere, so the plan ships unavailable and flags this as a cheap follow-up
(an open point for `/speckit-clarify`, not a blocker).

### D9 — Items to verify before shipping (not blockers for design)
1. Licences of usque and ByeDPI (both believed permissive; confirm) and notices in the app's licence screen.
2. Cloudflare WARP consumer terms for a third-party client, and the registration API's current behaviour (Vega registers anonymously with a key pair, then patches the account).
3. Binary sizes per ABI and total APK growth; page-size alignment on Android 15+.
4. That `ProxySelector.setDefault` is honoured by `DefaultHttpDataSource` on Android 9 (the Mi TV) and by mpv's `http_proxy`/`stream-lavf-o` on the bundled build.
5. Gateway throughput on the Mi TV (D5 risk).
6. Whether usque's HTTP proxy accepts many parallel `CONNECT`s (HLS segment bursts) without stalls.

## Build results (T003, 2026-11-23)

- **Licences**: usque is MIT (`LICENSE.md`, commit 6aa03fc), ByeDPI is MIT (`LICENSE`, Copyright (c) 2024 hufrea, commit 7efde1b). Notices go in the licence screen (T044).
- **Sizes**: `libusque.so` 13.7 MB (arm64-v8a) and 13.0 MB (armeabi-v7a); `libciadpi.so` 64 KB and 58 KB. A per-ABI APK grows by about 13 MB; a universal APK by about 27 MB.
- **Checks passed by the scripts**: ELF class, machine, Android interpreter and PIE for usque; 16 KB-aligned LOAD segments, RELRO and interpreter for ByeDPI.
- **Build environment**: the pinned Go (1.26.3) is downloaded by the script into `build/` (the machine's Go 1.18 cannot read usque's `go.mod`); on this network `proxy.golang.org` resets connections, so `GOPROXY` falls through (`|`) to `goproxy.cn` and then the source hosts, and `go.sum` plus `-mod=readonly` pin every module (the checksum database is off).
- **Packaging**: the four binaries live under `android/app/src/main/jniLibs/` which is git-ignored, like the TorrServer binary; a fresh clone runs `scripts/build_usque.sh` and `scripts/build_byedpi.sh` (a build without them shows the modes as unavailable).

## Revisions made while implementing

- **D4 revised (routes are the gateway's job)**: Dart cannot run TLS over a socket it has already read a handshake from (`SecureSocket.secure` only accepts a socket nobody has listened to). So the app's own HTTP clients do not dial upstream proxies themselves: while a route is active they use the local gateway as an ordinary HTTP proxy (`findProxy`), and the gateway, where traffic is only relayed, does the HTTP `CONNECT` and SOCKS5 work. With no route the existing connection factory in `net.dart` keeps resolving names (now with the chosen DoH provider).
- **D7 revised (settings keys)**: the keys are `device.net.*`, not `net.*`. The app has no settings backup; its only carriers are account sync (which skips `device.*`) and *Reset*. A WARP choice synced from a phone would switch it on for a TV, so the choices stay device-local; *Reset* restores the defaults. Spec FR-016 ("backup and restore") is met by this: the choices are kept on the device and an unsupported mode shows as unavailable.
- **DoH uses the RFC 8484 wire format** (any resolver, including a custom one), not a provider's JSON API.
- **Known limit**: with Anti-DPI on, the DoH lookups themselves go out direct (their TLS to a large resolver, with a by-address fallback, is rarely the thing being inspected).

## First device result (2026-11-23)

Phone (arm64-v8a), user-tested: the first build broke every plugin (the Android channel object was created inside the plugin's background isolate); fixed by moving what the HTTP clients read into `NetState` (`lib/data/network/net_state.dart`) and handing it to the plugin isolate. After the fix the user reported it working (no further detail recorded). Still to run and record on the TV: quickstart Q1–Q13 (T026, T031, T038, T043, T048).
