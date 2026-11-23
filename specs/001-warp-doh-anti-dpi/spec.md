# Feature Specification: Network Modes (WARP, Secure DNS, Anti-DPI)

**Feature Branch**: `001-warp-doh-anti-dpi`

**Created**: 2026-11-23

**Status**: Draft

**Input**: User description: "we need to add WARP Mode and DNS over HTTPS and Anti DPI Mode related to Network Section same like in this repo : /var/www/html/vega-app"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Get around a blocked connection with one switch (Priority: P1)

A viewer's internet provider blocks or throttles some of the sites VyseTV needs (film sources, plugin sites, image and stream hosts), so
pictures stay blank, sources find nothing, or videos refuse to start. In Settings → Network the viewer turns on **WARP Mode**
("Bypass ISP restrictions with Cloudflare WARP"). The app connects, shows that it is active, and from then on the app's network traffic
goes through the WARP service. The viewer does not create an account or configure anything.

**Why this priority**: It is the most effective and simplest remedy for a provider block, and the one that needs no tuning. It alone is a
usable first version of the feature.

**Independent Test**: With a site that is unreachable on the viewer's network, switch WARP Mode on, wait for "active", and check that
the site's content (a source's streams, a poster) now loads inside the app. Switch it off and check that the app goes back to its normal route.

**Acceptance Scenarios**:

1. **Given** WARP Mode is off, **When** the viewer switches it on, **Then** a "Connecting…" message appears, and within a short time the
   setting shows that WARP is active and a confirmation is given.
2. **Given** WARP Mode is active, **When** the viewer opens a film and plays it, **Then** posters, source lookups and the video stream all
   use the WARP route.
3. **Given** WARP Mode is active, **When** the viewer switches it off, **Then** the app says it is disconnected and traffic returns to the normal route.
4. **Given** WARP cannot connect (no internet, service unreachable), **When** the viewer switches it on, **Then** a clear message says it
   failed, the switch returns to off, and the app keeps working on its normal route.
5. **Given** WARP Mode was on when the app was closed, **When** the app starts again, **Then** WARP is started again automatically, and if
   that fails the viewer is told and the app still opens normally.

---

### User Story 2 - Encrypt DNS lookups with a resolver of my choice (Priority: P2)

Some providers block sites simply by lying about their address (DNS tampering). In Settings → Network the viewer picks a **Secure DNS (DNS over
HTTPS)** provider from a list (Cloudflare, Google, AdGuard, or a custom address, or Off). The app then looks up site names through that
encrypted resolver, so tampered answers no longer hide a site.

**Why this priority**: A second, lighter remedy for a common kind of block. It works alone and also helps together with Anti-DPI.

**Independent Test**: On a network that poisons DNS for a site, choose a provider and check that the site now resolves and loads in the app;
choose Off and check the old behaviour returns.

**Acceptance Scenarios**:

1. **Given** Secure DNS is Off, **When** the viewer chooses a listed provider, **Then** the choice is saved, takes effect for the app's next
   connections, and the setting shows the provider in use.
2. **Given** the viewer chooses Custom, **When** they enter a valid resolver address and confirm, **Then** "Custom DNS applied" is shown and
   that resolver is used.
3. **Given** the viewer enters an address that is not a valid secure resolver address, **When** they try to confirm, **Then** it is refused
   with a clear message and the previous setting stays.
4. **Given** the chosen resolver cannot be reached, **When** the app looks up a site, **Then** the app falls back to the system's normal
   lookup for that request rather than failing outright.
5. **Given** WARP Mode is active, **When** the viewer looks at Secure DNS, **Then** it says that lookups are handled by WARP, and the
   viewer's provider choice is kept but not applied while WARP is on.

---

### User Story 3 - Defeat deep-packet-inspection blocking (Priority: P3)

Some networks inspect the start of each secure connection and cut the ones going to blocked sites. In Settings → Network the viewer switches
on **Anti-DPI Mode**, which alters how the app's connections begin so that inspection no longer recognises the destination. The viewer can use
the recommended setting as is, pick another ready-made preset when it does not work on their network, or (advanced) edit the parameters by hand
and restore the default.

**Why this priority**: Needed only on some networks and takes more tuning than the other two, but it is the remedy when WARP is not wanted or
not reachable and DNS alone is not enough.

**Independent Test**: On a network that resets connections to a given site, switch Anti-DPI on with the recommended preset and check that
the site loads; try another preset and check that the app restarts the mode with it.

**Acceptance Scenarios**:

1. **Given** Anti-DPI Mode is off, **When** the viewer switches it on, **Then** "Starting…" is shown, then the setting shows it is active, using the
   recommended preset unless the viewer had saved other parameters.
2. **Given** Anti-DPI is active, **When** the viewer picks a different preset, **Then** it is applied, the mode restarts with it, and the viewer is told.
3. **Given** the viewer opens the advanced editor, **When** they change the parameters and save, **Then** they are stored, the mode restarts
   with them if it is active, and "saved" is confirmed; **When** they choose "reset", **Then** the recommended parameters come back.
4. **Given** the parameters are malformed so the mode cannot start, **When** the viewer saves or starts, **Then** a clear error is shown, Anti-DPI
   stays off, and the app keeps working normally.
5. **Given** Anti-DPI is active, **When** the viewer switches it off, **Then** the app says it stopped and connections start normally again.

---

### User Story 4 - Understand and control the network section from a TV remote (Priority: P2)

On an Android TV the viewer reaches Settings → Network with the remote only. Every control is reachable with the directional pad and
confirm button, shows which one is focused, and says in plain words what it does and its current state (off, connecting, active, error), so the
viewer can turn modes on and off and edit parameters without a touch screen or keyboard beyond text entry.

**Why this priority**: VyseTV is used mostly on TVs; without this the other stories are unusable there.

**Independent Test**: With only a remote, open Settings → Network, switch each mode on and off, choose a DNS provider and open the Anti-DPI preset list.

**Acceptance Scenarios**:

1. **Given** the viewer is on a TV, **When** they move through Settings → Network, **Then** every control can be focused and activated and the focused one is clearly highlighted.
2. **Given** a mode is connecting or active or failed, **When** the viewer looks at its row, **Then** its state is shown in words, not only by colour.

---

### Edge Cases

- WARP and Anti-DPI cannot both run: turning one on turns the other off, and the viewer is told which one was switched off.
- Secure DNS and Anti-DPI work together; Secure DNS and WARP do not (WARP handles lookups itself, see Story 2 scenario 5).
- The viewer switches modes quickly several times: the last choice wins, no mode is left half-started, and the displayed state matches the real one.
- The device has no connection at all, or the connection changes (Wi-Fi to cable, network lost and back) while a mode is active: the mode recovers on its own or reports that it is not working, and never leaves the app without any route.
- The app is closed or killed while a mode is active, then reopened: the saved choice is restored at start; a failure to restore is reported and does not block the app.
- A viewer's saved settings are restored from a backup made on another device: the choices are kept, but a mode that this device cannot run is shown as unavailable instead of failing.
- On a platform where a mode is not available (see Assumptions), the control is shown as unavailable with a reason, or hidden, never as a switch that does nothing.
- Local-network and device-internal traffic (the TorrServer on the same device, casting to a TV on the home network) must keep working while a mode is active.
- A mode that bypasses restrictions is on while the viewer is on a network where it is not needed: the app still works; at most playback is a little slower.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST have a **Network** section in Settings containing WARP Mode, Secure DNS (DNS over HTTPS) and Anti-DPI Mode, each with a name, a one-line description and a visible current state.
- **FR-002**: Viewers MUST be able to switch WARP Mode on and off. While it is on, the app's network traffic (catalogue and metadata, posters and images, source and plugin lookups, video streams) MUST go through the WARP service.
- **FR-003**: Turning WARP on MUST need no account, sign-in or configuration from the viewer.
- **FR-004**: WARP Mode MUST show distinct states: off, connecting, active, and failed (with a reason), and MUST tell the viewer when it connects, disconnects or fails.
- **FR-005**: If WARP fails to connect, the switch MUST return to off and the app MUST keep working on its normal route.
- **FR-006**: Viewers MUST be able to choose a Secure DNS provider from: Cloudflare, Google, AdGuard, Custom, or Off. Choosing a provider MUST apply it to the app's name lookups without restarting the app.
- **FR-007**: For Custom, the viewer MUST be able to enter a resolver address; the app MUST validate it, refuse an invalid one with a clear message, keep the previous setting, and confirm a valid one ("Custom DNS applied").
- **FR-008**: If the chosen Secure DNS resolver cannot be reached, the app MUST fall back to the system's normal lookup for that request instead of failing.
- **FR-009**: While WARP Mode is active, the Secure DNS control MUST state that lookups are handled by WARP; the saved provider choice MUST be kept and applied again when WARP is switched off.
- **FR-010**: Viewers MUST be able to switch Anti-DPI Mode on and off, with states: off, starting, active, failed (with a reason).
- **FR-011**: Anti-DPI Mode MUST offer ready-made presets (a recommended one used by default, and alternatives for stricter networks, each with a one-line description), and MUST let the viewer pick one.
- **FR-012**: Anti-DPI Mode MUST offer an advanced editor for its parameters, with save and "reset to recommended"; saving while the mode is active MUST restart it with the new parameters and say so.
- **FR-013**: Malformed Anti-DPI parameters MUST be reported as an error, MUST NOT leave the mode running with the old ones unnoticed, and MUST leave the app working.
- **FR-014**: WARP Mode and Anti-DPI Mode MUST be mutually exclusive: switching one on MUST switch the other off and tell the viewer. Secure DNS MUST be usable together with Anti-DPI.
- **FR-015**: The viewer's choices (WARP on/off, DNS provider and custom address, Anti-DPI on/off, selected preset and custom parameters) MUST be remembered on the device and re-applied automatically when the app starts. A failure to re-apply MUST be reported without blocking the app's start.
- **FR-016**: The viewer's choices MUST be included in the app's settings backup and restore, and a restored choice that this device cannot run MUST appear as unavailable rather than failing.
- **FR-017**: Traffic to the device itself and to the viewer's local network (including the on-device TorrServer and casting) MUST NOT be routed through WARP or altered by Anti-DPI.
- **FR-018**: Every control in the Network section MUST be operable with a TV remote (directional pad and confirm), show focus clearly, and show each state in words as well as by colour or icon.
- **FR-019**: On a platform where a mode cannot run, its control MUST be hidden or shown as unavailable with a reason; it MUST NOT appear as a working switch.
- **FR-020**: No mode may send the viewer's identity or viewing activity anywhere beyond what the chosen service needs to carry the traffic; the section MUST say plainly that traffic is carried by a third-party service (Cloudflare for WARP and for the Cloudflare resolver, the chosen resolver otherwise).

### Key Entities *(include if feature involves data)*

- **Network mode settings**: the viewer's saved choices on this device: WARP on/off; Secure DNS provider (Cloudflare, Google, AdGuard, Custom, Off) and custom address; Anti-DPI on/off, selected preset, custom parameters. Part of the settings backup.
- **Mode state**: the live condition of WARP and of Anti-DPI (off, connecting/starting, active, failed with reason). Not saved; shown in the Network section.
- **Anti-DPI preset**: a named, described set of parameters (name, description, parameters); one is the recommended default.
- **DNS provider**: a named secure resolver (Cloudflare, Google, AdGuard) or a viewer-supplied address.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A viewer can switch on WARP Mode and see it active in under 15 seconds on a working connection, with no more than 2 actions.
- **SC-002**: On a network that blocks a film source, at least 90% of the sources that were unreachable become reachable with WARP Mode on (measured against a fixed list of blocked sources).
- **SC-003**: A viewer can choose a Secure DNS provider (including entering a custom one) in under 30 seconds and the next lookups use it without restarting the app.
- **SC-004**: With Secure DNS set, name lookups for sites whose DNS is tampered with on the test network succeed in at least 95% of attempts.
- **SC-005**: With Anti-DPI on and a suitable preset, at least 80% of the sites that reset connections on the test network load (measured against a fixed list), and a viewer can switch presets in under 20 seconds.
- **SC-006**: In 100% of failure cases (WARP cannot connect, resolver unreachable, malformed parameters) the app stays usable on its normal route and shows a message that says what failed.
- **SC-007**: After a restart, a viewer's chosen modes are active again within 20 seconds of opening the app in at least 95% of starts, without the viewer doing anything.
- **SC-008**: A first-time TV viewer using only a remote can switch on each of the three modes, and off again, without help.
- **SC-009**: Turning any mode on or off never interrupts a video that is playing for longer than a brief re-buffering (under 10 seconds).

## Assumptions

- Reference behaviour is the network section of the Vega app in `/var/www/html/vega-app`: a WARP switch, a DNS-over-HTTPS provider list with Off and Custom, and an Anti-DPI switch with presets and an advanced parameter editor, WARP and Anti-DPI mutually exclusive.
- First delivery is for Android (phones and Android TV), as in the reference; **Linux was added afterwards** (same two programs built for Linux and shipped in the app's folder). On other platforms (Windows, Apple) the Network section is shown with these modes marked unavailable; supporting them is out of scope for this feature.
- The modes apply to the whole app's network traffic, not only to some screens; they do not change the device's other apps (no device-wide VPN is created for other apps).
- WARP uses Cloudflare's free, anonymous service; no viewer account is needed. Availability and speed depend on that service.
- Anti-DPI works for connections the app makes itself; it cannot help where a provider blocks by destination address alone, which is what WARP is for.
- The recommended Anti-DPI preset and the list of alternatives match the reference's four presets (recommended, reorder-only, split-only, aggressive) and may be adjusted after testing.
- Secure DNS applies when WARP is off; with WARP on, lookups are made remotely by WARP.
- Bypass services are for reaching content the viewer is entitled to see; the app does not promote use to break local law and says traffic is carried by a third party.
- Existing app behaviours (plugin sandbox that refuses local-network addresses, TorrServer on the device, casting) remain unchanged.
