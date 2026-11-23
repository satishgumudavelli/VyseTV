# Implementation Plan: Network Modes (WARP, Secure DNS, Anti-DPI)

**Branch**: `001-warp-doh-anti-dpi` | **Date**: 2026-11-23 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-warp-doh-anti-dpi/spec.md`

## Summary

Add a **Network** section to Settings with three controls: **WARP Mode**, **Secure DNS (DNS over HTTPS)** and **Anti-DPI Mode**, modelled on the
Vega app (`/var/www/html/vega-app`). Technical approach (details in [research.md](research.md)):

- Two small native programs, built per ABI and shipped in the APK's native-library folder exactly like the existing TorrServer binary, are
  started and stopped by a new Android plugin: **usque** (a Cloudflare WARP client that exposes a local HTTP proxy) and **ByeDPI** (a local
  SOCKS5 proxy that rewrites how a TLS connection starts).
- A new Dart **network-modes controller** owns the settings, the state of each mode and the upstream route (direct, WARP proxy, ByeDPI proxy)
  plus the DNS choice. It generalises the existing `lib/data/net.dart` connection factory (today: system DNS with a Cloudflare DoH
  fallback) and is installed as the global `HttpOverrides`, so images, the `http` package, `netClient`, plugins and the updater all follow it.
- **Players and native code** (ExoPlayer, mpv) cannot use Dart sockets, so the controller also runs a **local gateway** (a loopback HTTP/CONNECT
  proxy in a background isolate) that applies the same route and DNS; ExoPlayer is pointed at it with a JVM proxy selector (Cronet off while a
  mode is on) and mpv through its HTTP-proxy option. TorrServer and casting bypass it (loopback and LAN are never proxied).
- Settings are `AppSettings` entries (so they join backup/restore) and are re-applied at app start; the UI is a new `_Section` in the settings
  page, built with the existing D-pad focus widgets.

## Technical Context

**Language/Version**: Dart 3.13 / Flutter 3.47 (app, settings, controller, gateway); Kotlin (Android plugin, process management); C and Go only
as *built third-party sources* (ByeDPI, usque), not new code.

**Primary Dependencies**: existing: `http`, `cached_network_image`, `shared_preferences`, `path_provider`; no new Dart package (SOCKS5 and HTTP
CONNECT clients are small and written in-repo, see research D4). Third-party binaries: usque (Go, built with the NDK clang for 32-bit), ByeDPI v0.17.x
(C). Licences and Cloudflare WARP terms to be confirmed before shipping (research D9).

**Storage**: `AppSettings` (`SharedPreferences`) for choices; WARP's account/config file in the app's private files folder (created on first
start by registering an anonymous WARP client; never in backups).

**Testing**: `flutter test` unit tests for the controller, settings, DoH parsing/providers, SOCKS5 and CONNECT dialers and the gateway, using
loopback fake servers; a Kotlin-free approach for process management (the Dart side is tested with a fake channel); on-device manual validation
via [quickstart.md](quickstart.md) (Android TV and phone). Existing tests must keep passing.

**Target Platform**: Android phones and Android TV (armeabi-v7a and arm64-v8a; Android x86_64 gets no binaries and shows the modes unavailable) and, added later,
Linux x86-64 (`lib/data/network/desktop_network_platform.dart` runs the same programs directly; they sit in the bundle's `lib/` folder). Windows and Apple: section
visible, modes unavailable (spec FR-019).

**Project Type**: mobile/TV Flutter app (single project) with an Android native module.

**Performance Goals**: mode switch to "active" in under 15 s (SC-001); no added step in the playback path above one local hop; gateway must carry a
4K stream (about 25 Mbit/s) without stalls on a Mi TV-class device; switching a mode never interrupts playback for more than a brief rebuffer (SC-009).

**Constraints**: loopback-only listeners (127.0.0.1, ephemeral ports); never proxy loopback/LAN destinations (FR-017); every failure falls back to the
normal route and says so (SC-006); no new permissions beyond INTERNET; the binaries must run from the native-library folder (already unpacked:
`useLegacyPackaging = true`); APK growth kept small (two static binaries per ABI, about 15 MB combined estimate to verify).

**Scale/Scope**: one settings section, one controller, one gateway, one Android plugin, two bundled binaries, about 10 source files and 6 test files.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified principles to gate on. Working rules taken from the
repository itself and applied here instead:

| Rule (source) | Status |
|---|---|
| Format with `dart format -l 160`; analyzer clean apart from the known unrelated info | Will hold |
| New behaviour has tests; existing tests untouched | Will hold (tests listed above) |
| No domain/policy logic inside generic engines (earlier decision: dynamic data lives outside the app) | Holds: only mechanisms (proxy, DNS) are in the app; no site lists |
| Nothing secret or personal in logs (project privacy rule) | Hold: WARP keys never logged |

Re-evaluated after Phase 1 design: no violations; Complexity Tracking not needed.

## Project Structure

### Documentation (this feature)

```text
specs/001-warp-doh-anti-dpi/
├── plan.md              # This file
├── research.md          # Phase 0: decisions and alternatives
├── data-model.md        # Phase 1: settings, states, presets, providers
├── quickstart.md        # Phase 1: how to validate end to end
├── contracts/
│   ├── settings-ui.md           # what the Network section shows and does
│   ├── native-channel.md        # Dart <-> Android method channel
│   └── local-gateway.md         # the loopback proxy native players use
└── tasks.md             # Phase 2 (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
lib/
├── data/
│   ├── net.dart                         # CHANGED: connection factory asks NetworkModes for route + DNS
│   ├── app_settings.dart                # CHANGED: the new Setting entries (+ in _all for backup)
│   └── network/                         # NEW
│       ├── network_modes.dart           # controller: settings, state, start/stop, mutual exclusion, restore at start
│       ├── network_route.dart           # route model + dial through direct / HTTP-CONNECT proxy / SOCKS5
│       ├── dns_providers.dart           # provider list, custom URL validation, DoH query + cache + fallback
│       ├── anti_dpi_presets.dart        # preset list and default parameters, parameter validation
│       ├── local_gateway.dart           # loopback HTTP/CONNECT proxy for native players (background isolate)
│       └── network_channel.dart         # Dart side of the Android method channel
├── screens/profile/
│   ├── profile_page.dart                # CHANGED: adds the Network _Section
│   └── network_section.dart             # NEW: the section's widgets (rows, DNS picker, preset list, editor)
└── main.dart                            # CHANGED: HttpOverrides.global + NetworkModes.restore() at start

android/app/
├── build.gradle.kts                     # CHANGED: add the two binaries' folders to jniLibs
└── src/main/
    ├── kotlin/com/vyse/vyse_tv/
    │   ├── MainActivity.kt              # CHANGED: registers the NetworkModes plugin
    │   └── network/NetworkModesPlugin.kt  # NEW: WARP registration + process control, ByeDPI process control, proxy selector, state events
    └── jniLibs/{arm64-v8a,armeabi-v7a}/{libusque.so,libciadpi.so}   # NEW (built, see scripts)

android/app/src/main/kotlin/com/vyse/player/exoplayer/ExoPlayerCore.kt   # CHANGED: no Cronet while a mode is on; proxy selector applies
lib/mpv/player/...                       # CHANGED: pass the gateway as mpv's HTTP proxy while a mode is on
scripts/
├── build_usque.sh                       # NEW: reproducible build (pinned commit and Go version)
└── build_byedpi.sh                      # NEW: reproducible build (pinned commit, NDK clang)

test/
├── network_modes_test.dart              # controller: states, exclusion, restore, fallback on failure
├── network_route_test.dart              # CONNECT and SOCKS5 dialers against loopback fakes
├── dns_providers_test.dart              # providers, custom validation, DoH answer parsing, system fallback
├── anti_dpi_presets_test.dart           # presets, parameter validation
├── local_gateway_test.dart              # CONNECT and plain HTTP through the gateway, LAN refused
└── network_settings_test.dart           # settings keys, backup inclusion, defaults
```

**Structure Decision**: single Flutter project; new Dart code lives in `lib/data/network/` next to the existing `net.dart` it extends, UI in its
own file under `lib/screens/profile/`, and one Android Kotlin class for everything that needs a process or the JVM. Binary builds are scripts
under `scripts/`, matching the existing `fetch_linux_libmpv.py` and release scripts.

## Complexity Tracking

No constitution violations. The one structural cost worth recording is the **local gateway**: it adds a component that Vega does not need
(Vega's native HTTP stack accepts a proxy and a DNS resolver directly). It is justified because VyseTV's players are ExoPlayer on Cronet
and mpv, neither of which accepts a custom resolver; the simpler alternative of only setting a proxy would leave Secure DNS without effect
on video streams (see research D5).
