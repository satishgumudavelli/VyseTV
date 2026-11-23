---
description: "Task list for Network Modes (WARP, Secure DNS, Anti-DPI)"
---

# Tasks: Network Modes (WARP, Secure DNS, Anti-DPI)

**Input**: Design documents from `/specs/001-warp-doh-anti-dpi/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (settings-ui, native-channel, local-gateway), quickstart.md

**Tests**: Included. The plan lists a test file per component and the repo keeps tests for every new behaviour. Test tasks come before the code they cover in each phase.

**Organization**: Grouped by user story so each can be built and checked on its own. Paths are relative to the repository root (`/var/www/html/vysetv`). Format Dart with `dart format -l 160`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 WARP (P1) · US2 Secure DNS (P2) · US3 Anti-DPI (P3) · US4 TV remote use (P2)

---

## Phase 1: Setup (the two native programs)

**Purpose**: Get usque and ByeDPI built, pinned and packaged. Nothing else can be tested on a device without them.

- [X] T001 [P] Write `scripts/build_usque.sh`: check out a pinned usque commit (take it from `/var/www/html/vega-app/scripts/build-usque.ps1`), verify the commit and a clean tree, fetch the pinned Go toolchain (the machine has Go 1.18; usque needs a newer one via `GOTOOLCHAIN`), cross-compile `libusque.so` for `arm64-v8a` (plain Go) and `armeabi-v7a` (NDK clang as external linker, NDK at `~/Documents/Android/Sdk/ndk/*`), with the 16 KB page-size link flags; output into `android/app/src/main/jniLibs/<abi>/`
- [X] T002 [P] Write `scripts/build_byedpi.sh`: check out the pinned ByeDPI commit (from `/var/www/html/vega-app/scripts/build-byedpi.ps1`), verify it, compile `libciadpi.so` for both ABIs with NDK clang (`-fPIE -pie`, 16 KB page-size flags, sources `packets.c main.c conev.c proxy.c desync.c mpool.c extend.c`); output into `android/app/src/main/jniLibs/<abi>/`
- [X] T003 Run both scripts, put the four binaries in `android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/`, check each is an executable for its ABI (`file`), and record sizes and the licences of usque and ByeDPI in `specs/001-warp-doh-anti-dpi/research.md` (closes D9 items 1 and 3)
- [X] T004 Check `android/app/build.gradle.kts` packages the new `jniLibs` folders unpacked (`useLegacyPackaging = true` already set) and that `unzip -l` of a release APK lists `lib/armeabi-v7a/libusque.so` and `libciadpi.so`; change nothing if it already does

**Checkpoint**: binaries exist, are pinned and reproducible, and ship in the APK.

---

## Phase 2: Foundational (blocks all user stories)

**Purpose**: Settings, route/DNS code, the controller, the Android plugin skeleton and the channel, with Dart traffic already following the route.

### Tests first

- [X] T005 [P] Write `test/network_settings_test.dart`: the six `net.*` keys exist with the defaults in `data-model.md`, are part of the settings backup list, and a restored backup with both `net.warp` and `net.antidpi` true keeps WARP and stores Anti-DPI false
- [X] T006 [P] Write `test/network_route_test.dart`: against loopback fake servers, the HTTP `CONNECT` dialer (success, `407`/`502` refused) and the SOCKS5 dialer (success by address, refused, malformed reply) return a usable socket or a clear error; TLS-upgrade keeps the real host name
- [X] T007 [P] Write `test/dns_providers_test.dart`: provider list and URLs; custom URL validation (https only, host required, no user info or fragment, 2048 limit, bare IP host allowed); DoH JSON answer parsing; sinkhole answers (0.0.0.0, loopback) are dropped; failed lookups are not cached; a failing resolver falls back to the system lookup
- [X] T008 [P] Write `test/network_modes_test.dart` with a fake channel: state machine (`off → starting → active(port) | failed`), exclusion of WARP and Anti-DPI, last choice wins when switched quickly, start timeout, failure returns the setting to off and the route to direct, restore at start (and a restore failure never throws)

### Implementation

- [X] T009 [P] Add the six `Setting`s (`net.warp`, `net.doh`, `net.dohUrl`, `net.antidpi`, `net.antidpiPreset`, `net.antidpiArgs`) to `lib/data/app_settings.dart` and to its `_all` list on a separate line from the existing entries
- [X] T010 [P] Create `lib/data/network/network_route.dart`: `NetworkRoute` (`direct`, `httpProxy(port)`, `socks5(port)`), and `dialThrough(route, address, host, port, secure)` implementing HTTP `CONNECT` and SOCKS5 handshakes in-repo, then the TLS upgrade with the real host name (move/adapt `_dial` from `lib/data/net.dart`)
- [X] T011 [P] Create `lib/data/network/dns_providers.dart`: provider list (Cloudflare, Google, AdGuard, Custom, Off with labels), `validateCustomDohUrl`, and the DoH lookup with per-session cache and system fallback (move/adapt `_doh`, `_system`, `_sinkhole`, `_dohCache` out of `lib/data/net.dart`, behaviour unchanged for the default Cloudflare fallback)
- [X] T012 Create `lib/data/network/network_modes.dart`: the controller from `data-model.md` (settings, `ModeState` for WARP and Anti-DPI, exclusion, derived route and DNS choice, `restore()` at start, timeouts) with the channel behind an interface so tests can fake it (depends on T009, T010, T011)
- [X] T013 Change `lib/data/net.dart`: `_connect` asks `NetworkModes` for the route and DNS choice (keep today's behaviour when the route is direct and DNS is Off: system first, Cloudflare DoH fallback), and add `HttpOverrides.global` support so every `HttpClient` follows it (depends on T012)
- [X] T014 Wire `lib/main.dart`: install the global override after `AppSettings.initialize()` and call `NetworkModes.restore()` without awaiting it, so a slow or failing restore never delays or blocks start (depends on T012, T013)
- [X] T015 [P] Create `android/app/src/main/kotlin/com/vyse/vyse_tv/network/NetworkModesPlugin.kt`: channel `vyse/network`, `capabilities` (binary present for this ABI), `status`, `setProxy`, process helpers (start from `nativeLibraryDir`, wait-for-listening with timeout, kill leftovers at start, kill on app exit, `onModeEvent` when a process dies) per `contracts/native-channel.md`; register it in `android/app/src/main/kotlin/com/vyse/vyse_tv/MainActivity.kt`
- [X] T016 [P] Create `lib/data/network/network_channel.dart`: the Dart side of `vyse/network` (typed calls, error codes to messages, `onModeEvent` stream, "unavailable" when the channel is missing) behind the interface used in T012
- [X] T017 Run `flutter analyze` and the four foundational tests; fix until green (depends on T005–T016)

**Checkpoint**: Dart traffic follows the route and DNS choice; the controller and channel exist; nothing in the UI yet.

---

## Phase 3: User Story 1 - WARP Mode (Priority: P1) 🎯 MVP

**Goal**: One switch sends all the app's traffic, images, source lookups and video streams, through Cloudflare WARP, with clear states and a safe failure.

**Independent Test**: quickstart Q1, Q2, Q3, Q8, Q10, Q11 (a blocked source loads with WARP on; failure returns the switch to off; restart restores it; a 4K stream plays; TorrServer and casting still work).

### Tests for User Story 1

- [X] T018 [P] [US1] Write `test/local_gateway_test.dart`: through the gateway, `CONNECT` to a loopback fake TLS server and a plain absolute-URI `GET` (with `Range`) are relayed unchanged; loopback and private destinations get `403`; upstream failure gives `502`; more than 64 connections get `503`; idle connections close
- [X] T019 [P] [US1] Extend `test/network_modes_test.dart` with WARP cases: `startWarp` success sets route `httpProxy(port)`, failure code shows its sentence, an `onModeEvent` exit sets failed, off restores direct

### Implementation for User Story 1

- [X] T020 [P] [US1] Create `lib/data/network/local_gateway.dart`: the loopback HTTP/CONNECT proxy per `contracts/local-gateway.md`, running in a background isolate, binding `127.0.0.1:<ephemeral>` only while the route is not direct, using `dialThrough` and the DNS choice, refusing LAN/loopback targets, logging counts only
- [X] T021 [US1] Implement WARP in `NetworkModesPlugin.kt`: first-run anonymous registration with Cloudflare (as `WarpModule.registerCloudflare` in the Vega app), `config.json` in the app's private files folder, `startWarp` launching `libusque.so -c <config> http-proxy -b 127.0.0.1 -p <port> -d 1.1.1.1 -d 8.8.8.8`, HTTP/3 then HTTP/2 only (no `--insecure` fallback), error codes `WARP_*`, `stopWarp` (depends on T015)
- [X] T022 [US1] Implement the WARP flow in `lib/data/network/network_modes.dart`: switch on → turn Anti-DPI off with a message → `starting` → `startWarp` → route `httpProxy(port)` and start the gateway → `active`; failure → setting off, route direct, message; off → stop gateway and WARP; `restore()` starts WARP again when saved on (depends on T012, T016, T020, T021)
- [X] T023 [P] [US1] Point ExoPlayer at the gateway while a mode is on in `android/app/src/main/kotlin/com/vyse/player/exoplayer/ExoPlayerCore.kt`: skip Cronet and use `DefaultHttpDataSource` when a proxy is set, leave behaviour unchanged otherwise; implement `setProxy` in the plugin with a `ProxySelector` that returns `DIRECT` for loopback and private addresses (depends on T015)
- [X] T024 [P] [US1] Point mpv at the gateway while a mode is on: set its HTTP proxy through `stream-lavf-o` next to the existing `network-timeout` call in `lib/screens/player/player_page.dart` (around line 3004), and clear it when the mode is off (depends on T020)
- [X] T025 [US1] Create `lib/screens/profile/network_section.dart` with the **WARP Mode** row per `contracts/settings-ui.md` (title, subtitle, switch, state words, messages `Connecting to Cloudflare WARP…`, `WARP connected`, `WARP disconnected`, `WARP error: <reason>`, the Cloudflare note) and add `_Section(title: 'Network')` using it to `lib/screens/profile/profile_page.dart` (depends on T022)
- [ ] T026 [US1] Build, install on the Mi TV and run quickstart Q1, Q2, Q3, Q8, Q10, Q11; record results and Q8 throughput in `specs/001-warp-doh-anti-dpi/research.md` D5/D9 (closes D9 items 4, 5, 6); if the Dart gateway cannot sustain 4K, move the same logic into `NetworkModesPlugin.kt` (contract unchanged)

**Checkpoint**: WARP works end to end including video; this alone is a shippable first version.

---

## Phase 4: User Story 2 - Secure DNS (Priority: P2)

**Goal**: The viewer picks a DNS-over-HTTPS provider (or Custom, or Off) and the app's lookups use it, including video streams.

**Independent Test**: quickstart Q4, Q5 (a tampered-DNS site resolves with a provider chosen; invalid custom address refused; Off restores the old behaviour).

### Tests for User Story 2

- [X] T027 [P] [US2] Extend `test/network_modes_test.dart` with DNS cases: choice saved and applied to the next connection without restart; custom invalid keeps the previous value; with WARP active the saved choice is kept but not applied and applies again after WARP off; unreachable resolver falls back to system lookup
- [X] T028 [P] [US2] Extend `test/local_gateway_test.dart`: a `CONNECT` to a name that the system resolver sinkholes succeeds through the DoH choice (fake DoH answers), and with route `httpProxy` the name is passed unresolved

### Implementation for User Story 2

- [X] T029 [US2] Apply the DNS choice in `lib/data/network/network_modes.dart` and `lib/data/net.dart`: DoH provider URL used for lookups when not `off` (and route is not `httpProxy`), custom URL persisted only after validation, choice re-applied at start (depends on T011, T012)
- [X] T030 [US2] Add the **Secure DNS** row to `lib/screens/profile/network_section.dart`: provider list with check and `Selected`, Custom field with `Use this resolver`, messages `Enter a full https:// address` and `Custom DNS applied`, WARP/Anti-DPI subtitles (`Managed by Cloudflare WARP (resolved remotely)`, `Works together with Anti-DPI`) (depends on T025, T029)
- [ ] T031 [US2] Run quickstart Q4 and Q5 on the TV and on Linux; note the result in `research.md`

**Checkpoint**: Secure DNS works alone and together with WARP and (once built) Anti-DPI.

---

## Phase 5: User Story 3 - Anti-DPI Mode (Priority: P3)

**Goal**: A switch plus presets and an advanced editor defeat connection inspection.

**Independent Test**: quickstart Q6, Q7, Q9 (a reset host loads with the recommended preset; presets switch and restart; bad parameters are refused; WARP and Anti-DPI exclude each other).

### Tests for User Story 3

- [X] T032 [P] [US3] Write `test/anti_dpi_presets_test.dart`: the four presets and their descriptions, the default, validation (refuses `-i/--ip`, `-p/--port`, `-I/--conn-ip`, over 512 characters, non-printable characters; empty means the preset), `custom` preset id when edited
- [X] T033 [P] [US3] Extend `test/network_modes_test.dart` with Anti-DPI cases: start with the saved or recommended parameters, changing preset or parameters while active restarts it, bad parameters give an error and leave it off, switching it on turns WARP off with a message and vice versa

### Implementation for User Story 3

- [X] T034 [P] [US3] Create `lib/data/network/anti_dpi_presets.dart`: presets (`split_disorder` default, `disorder`, `split`, `fake_oob`) with names and descriptions from `data-model.md`, default parameters `--split 1 --disorder 1 --auto=torst`, and `validateAntiDpiArgs`
- [X] T035 [US3] Implement Anti-DPI in `NetworkModesPlugin.kt`: `startAntiDpi(args)` launching `libciadpi.so -i 127.0.0.1 -p <free port> <args>` after refusing address/port arguments (`DPI_BAD_ARGS`), wait for the port to accept (5 s, `DPI_TIMEOUT`), `stopAntiDpi`, restart on different arguments (depends on T015)
- [X] T036 [US3] Implement the Anti-DPI flow in `lib/data/network/network_modes.dart`: switch on → turn WARP off with a message → `starting` → `startAntiDpi` → route `socks5(port)` and gateway → `active`; preset/parameter change restarts; failure → setting off, route direct, message (depends on T022, T034, T035)
- [X] T037 [US3] Add the **Anti-DPI Mode** row to `lib/screens/profile/network_section.dart`: switch and state words, the four presets as a list with a mark on the selected one, `Advanced parameters` editor with `Save` and `Reset to recommended`, messages from `contracts/settings-ui.md`, and the explanatory note (depends on T025, T034, T036)
- [ ] T038 [US3] Run quickstart Q6, Q7 and Q9 on the TV and note the result in `research.md`

**Checkpoint**: all three modes work, alone and in their allowed combinations.

---

## Phase 6: User Story 4 - TV remote use and unavailable devices (Priority: P2)

**Goal**: Everything in the section works with a remote only, states are words, and a mode a device cannot run is shown as unavailable.

**Independent Test**: quickstart Q12, Q13.

### Tests for User Story 4

- [ ] T039 [P] [US4] Write a D-pad test for the Network section in the existing harness pattern (`test/dpad/`, see `test/dpad/harness.dart` and `look_phase2_test.dart`): every control reachable and activatable with direction keys and confirm, the focused row highlighted, state words present for off, connecting, active and failed
- [ ] T040 [P] [US4] Extend `test/network_settings_test.dart`: a backup restored on a device whose `capabilities` say no WARP or Anti-DPI keeps the saved choices and the section shows `Not available on this device` with the switch disabled

### Implementation for User Story 4

- [ ] T041 [US4] Make `lib/screens/profile/network_section.dart` fully focus-navigable: each row, the DNS list, the preset list and the editor use the page's existing focus widgets, logical focus order, visible highlight, and state shown in words (depends on T025, T030, T037)
- [X] T042 [US4] Show unavailable modes: query `capabilities` once when the section builds, disable the switch and show `Not available on this device` for a mode the device cannot run (and on platforms without the channel), without removing the saved choice (depends on T016, T041)
- [ ] T043 [US4] Run quickstart Q12 and Q13 (remote-only run on the TV; backup restored on the x86_64 emulator)

**Checkpoint**: the whole section is usable from a remote and honest on unsupported devices.

---

## Phase 7: Polish & cross-cutting

- [X] T044 [P] Add the usque and ByeDPI licence notices to the app's licence/about screen (find it under `lib/screens/profile/`), using the licences recorded in T003
- [X] T045 [P] Add a short "Network modes" section to `README.md` (what the three modes do, that WARP traffic is carried by Cloudflare, Android only for now) and link `specs/001-warp-doh-anti-dpi/quickstart.md`
- [ ] T046 [P] Update `specs/001-warp-doh-anti-dpi/research.md` D9 with each verified item's result and any decision changed during build
- [ ] T047 Run `dart format -l 160` on every changed Dart file, `flutter analyze` (only the known unrelated info allowed) and the whole `flutter test` suite
- [ ] T048 Walk the full quickstart (Q1–Q13) on the Mi TV and on a phone, and write the results (with Q8 throughput numbers) in the PR description
- [ ] T049 Build the release APKs for both ABIs, check their size growth against the estimate in `plan.md`, and note it in `research.md`

---

## Dependencies & execution order

- **Phase 1 → Phase 2 → stories.** T003 needs T001, T002; T004 needs T003. Phase 2 tests (T005–T008) are written before T009–T016; T012 needs T009–T011; T013 and T014 need T012; T017 needs everything in Phase 2.
- **US1 (P1)** needs Phase 2 only. It also builds the gateway (T020), which US2 and US3 reuse for video.
- **US2 (P2)** needs Phase 2; its effect on *video* needs the gateway from US1 (T020, T023, T024). The Dart-side DNS (T029) can be built and tested before US1 is finished.
- **US3 (P3)** needs Phase 2 and the gateway and WARP flow from US1 (T022) because of the mutual exclusion; otherwise independent of US2.
- **US4 (P2)** needs the rows from US1–US3 (T025, T030, T037) to make focus and availability complete; its tests (T039, T040) can be written earlier against the WARP row.
- **Polish** last.

## Parallel opportunities

- Phase 1: T001 ∥ T002.
- Phase 2 tests: T005 ∥ T006 ∥ T007 ∥ T008. Phase 2 code: T009 ∥ T010 ∥ T011 (then T012), T015 ∥ T016.
- US1: T018 ∥ T019, then T020 ∥ T021 ∥ T023 ∥ T024 (different files).
- US2: T027 ∥ T028. US3: T032 ∥ T033 ∥ T034. US4: T039 ∥ T040.
- Polish: T044 ∥ T045 ∥ T046.
- Different people: after Phase 2, one takes US1 (needs the Android work), another US2's Dart/UI part, another US3's presets and editor.

### Parallel example: User Story 1

```text
Write together:  T018 test/local_gateway_test.dart   T019 test/network_modes_test.dart (WARP cases)
Build together:  T020 lib/data/network/local_gateway.dart
                 T021 NetworkModesPlugin.kt (WARP)
                 T023 ExoPlayerCore.kt + proxy selector
                 T024 lib/screens/player/player_page.dart (mpv proxy)
Then, in order:  T022 controller WARP flow → T025 WARP row in the UI → T026 device run
```

## Implementation strategy

- **MVP = Phase 1 + Phase 2 + US1 (T001–T026).** WARP alone is the most effective remedy and exercises every shared piece (binaries, controller, route, gateway, players, UI). Stop there, install on the TV, and decide whether to continue.
- **Then US2 (Secure DNS)**, cheap because most of it already exists in `net.dart`; **then US4** so the TV experience is complete; **then US3 (Anti-DPI)**, which needs the most tuning.
- Verify the open items from `research.md` D9 as the tasks that close them come up (T003, T026), not at the end.
- Commit after each task or logical group; keep each phase's checkpoint green (`flutter analyze`, its tests) before starting the next.


---

## Phase 8: Linux (added after the first device test)

**Goal**: WARP, Anti-DPI and Secure DNS work in the Linux app too, with the same controller, gateway and settings page.

- [X] T050 [P] Write `test/desktop_network_platform_test.dart` against fake programs (registration once, start on a loopback port, tunnel check, HTTP/3 then HTTP/2, errors with the program's own words, a program dying by itself, Anti-DPI argument refusal and restart, leftovers from a crashed run)
- [X] T051 Create `lib/data/network/desktop_network_platform.dart` (usque registered with its own `register --accept-tos`, started as `http-proxy` on 127.0.0.1, verified through Cloudflare's trace; ByeDPI started on a free loopback port; pid files for leftovers) and choose it in `defaultNetworkPlatform()` on Linux
- [X] T052 Extend `scripts/build_usque.sh` and `scripts/build_byedpi.sh` to also build the Linux x86-64 programs into `linux/network/`, install them from `linux/CMakeLists.txt` into the bundle's `lib/`, git-ignore `linux/network/`, and keep them in `scripts/install_linux_local.sh`
- [X] T053 Run the Linux app: Settings -> Network shows the modes available; WARP Mode reaches Cloudflare's trace with `warp=on`; Anti-DPI starts; quickstart Q1, Q2, Q4, Q6, Q7, Q9 on Linux (user confirmed on Linux 2026-11-23: "working"; Anti-DPI and the full Q-list not individually recorded)
