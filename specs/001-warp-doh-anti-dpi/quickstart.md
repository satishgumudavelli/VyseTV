# Quickstart: validating Network Modes

Prerequisites: the Android TV used for testing (Mi TV, armeabi-v7a, `adb connect <ip>:5555`), a phone (arm64-v8a), a network where at least one film source or image host is
unreachable (or reproduce it: a DNS server that returns `0.0.0.0` for a test name, and a router rule that resets TLS to a test host), and the built binaries.

## 1. Build the binaries (once per pinned version)

```
scripts/build_usque.sh <usque-checkout>      # needs the pinned Go toolchain and the NDK; writes android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/libusque.so
scripts/build_byedpi.sh <byedpi-checkout>    # NDK clang; writes .../libciadpi.so
```

## 2. Build and install

```
flutter build apk --release --target-platform android-arm --split-per-abi   # the TV
adb -s <tv>:5555 install -r build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
```
Check the binaries are in the APK: `unzip -l <apk> | grep -E 'libusque|libciadpi'` (both present, `lib/armeabi-v7a/`).

## 3. Automated checks (no device)

```
flutter test test/network_modes_test.dart test/network_route_test.dart test/dns_providers_test.dart \
             test/anti_dpi_presets_test.dart test/local_gateway_test.dart test/network_settings_test.dart
flutter analyze
```

## 4. Scenarios on the device (map to the spec)

| # | Do | Expect | Spec |
|---|---|---|---|
| Q1 | Settings → Network → switch WARP Mode on | `Connecting…` then `Active` in under 15 s; posters/streams of a blocked source now load | US1, FR-002/004, SC-001/002 |
| Q2 | Switch WARP off | `WARP disconnected`; the blocked source is unreachable again | US1 sc.3 |
| Q3 | Turn airplane mode on, then switch WARP on | `WARP error: …`, switch returns to Off, app still usable | FR-005, SC-006 |
| Q4 | Pick Cloudflare under Secure DNS; open a source whose DNS is tampered | it resolves and loads; choose Off: back to the old result | US2, SC-003/004 |
| Q5 | Custom DNS: enter `abc`, then a valid DoH address | first refused with the message; second `Custom DNS applied` | FR-007 |
| Q6 | Switch Anti-DPI on (recommended preset) on a network that resets TLS to a test host | the host loads; try another preset: `restarted` message | US3, SC-005 |
| Q7 | Advanced parameters: save `-p 1` | refused (`DPI_BAD_ARGS` shown as a sentence); `Reset to recommended` restores | FR-012/013 |
| Q8 | With WARP on, play a 4K stream for 10 minutes; also with Anti-DPI on | no stalls beyond brief rebuffering; switch the mode mid-playback: under 10 s interruption | SC-009, D5 risk |
| Q9 | With WARP on, switch Anti-DPI on | WARP turns off with the message; only Anti-DPI active | FR-014 |
| Q10 | Force-stop the app with a mode on, reopen | the mode is active again within 20 s | FR-015, SC-007 |
| Q11 | With a mode on, use TorrServer (a torrent) and cast to a LAN device | both still work | FR-017 |
| Q12 | Remote only: do Q1, Q4, Q6 without touching the screen | every control reachable and visibly focused; states in words | US4, FR-018, SC-008 |
| Q13 | Back up settings, restore on a device without binaries (x86_64 emulator) | choices kept; modes shown `Not available on this device` | FR-016/019 |

Record results and the Q8 throughput numbers in the PR description.
