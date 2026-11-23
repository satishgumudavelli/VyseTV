# Contract: Settings → Network section

Location: a new `_Section(title: 'Network')` on the settings page (`profile_page.dart`), widgets in `lib/screens/profile/network_section.dart`. Order of rows: WARP Mode, Secure DNS, Anti-DPI Mode.
Every row is a D-pad focus target using the page's existing focus widgets; the focused row is highlighted; activating a row toggles or opens its detail.

## WARP Mode (row)
- Title `WARP Mode`; subtitle `Bypass ISP restrictions with Cloudflare WARP`; trailing switch.
- State word under the subtitle: `Off` · `Connecting…` · `Active` · `Failed: <reason>`.
- On: sets the setting, turns Anti-DPI off first if it was on (message: `Anti-DPI turned off: it can't run together with WARP`), shows `Connecting to Cloudflare WARP…`, then `WARP connected`. On failure: `WARP error: <reason>`, switch back to Off.
- Off: `WARP disconnected`.
- Note line under the row (always): `Traffic is carried by Cloudflare's WARP service.`

## Secure DNS (row, opens a list)
- Title `Secure DNS`; subtitle `Encrypt DNS queries with a secure resolver`; trailing label with the current choice (`Off`, `Cloudflare (1.1.1.1)`, `Google (8.8.8.8)`, `AdGuard`, `Custom`).
- While WARP is active the subtitle becomes `Managed by Cloudflare WARP (resolved remotely)` and the list stays openable (the choice is kept, with a note that it applies when WARP is off).
- While Anti-DPI is active the subtitle may add `Works together with Anti-DPI`.
- List: Cloudflare, Google, AdGuard, Custom, Off; a selected item is marked by a check and the word `Selected`.
- Custom: a text field (placeholder `https://dns.example/dns-query`) and a `Use this resolver` button. Invalid → `Enter a full https:// address` and nothing changes; valid → `Custom DNS applied`.

## Anti-DPI Mode (row, expands)
- Title `Anti-DPI Mode`; subtitle `Get past connection inspection that blocks sites`; trailing switch; state words as WARP.
- On: turns WARP off first if it was on (`WARP turned off: it can't run together with Anti-DPI`), shows `Starting Anti-DPI…`, then `Anti-DPI active`; failure `Anti-DPI error: <reason>`, switch back to Off.
- Expanded: the four presets as a list (name + one-line description, selected one marked); picking one applies it and, if active, says `Anti-DPI restarted with the new settings`.
- `Advanced parameters` toggle: a text field with the current parameters, `Save` (validates; success `Parameters saved`, restarts if active) and `Reset to recommended`.
- Note line: `Works on connections this app makes; it can't help where a network blocks by address alone: use WARP for that.`

## Unavailable platform / device
- A mode that cannot run on this device shows its row with the switch disabled and the state word `Not available on this device` (no working-looking switch).

## Accessibility
- Every state is a word, not only a colour or icon; the whole section works with directional keys and the confirm key; text entry uses the platform keyboard.
