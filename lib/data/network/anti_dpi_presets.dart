/// Anti-DPI presets and parameter checks (specs/001-warp-doh-anti-dpi/data-model.md).
class AntiDpiPreset {
  const AntiDpiPreset(this.id, this.name, this.args, this.description);
  final String id, name, args, description;
}

const defaultAntiDpiArgs = '--split 1 --disorder 1 --auto=torst';

const antiDpiPresets = <AntiDpiPreset>[
  AntiDpiPreset('split_disorder', 'Split & Disorder', defaultAntiDpiArgs, 'Recommended for all networks and CDNs'),
  AntiDpiPreset('disorder', 'Disorder only', '--disorder 1 --auto=torst', 'Reorders the first byte to bypass SNI inspection'),
  AntiDpiPreset('split', 'Split only', '--split 1', 'Splits the TLS handshake into 2 segments'),
  AntiDpiPreset('fake_oob', 'Fake packet (OOB)', '-s 1 -q 1 -Y', 'Aggressive bypass for strict firewalls'),
];

/// The id of the preset used when the saved one is unknown.
const defaultAntiDpiPresetId = 'split_disorder';

AntiDpiPreset antiDpiPresetById(String id) => antiDpiPresets.firstWhere((p) => p.id == id, orElse: () => antiDpiPresets.first);

/// The parameters to run with: the hand-edited ones when there are any, else the preset's.
String antiDpiArgsFor(String presetId, String custom) => custom.trim().isNotEmpty ? custom.trim() : antiDpiPresetById(presetId).args;

/// Why [args] can't be used, or null when they can: printable ASCII only, at most 512 characters, and nothing that sets the listen
/// address or port (the app supplies those). Empty is fine (the preset's parameters are used).
String? validateAntiDpiArgs(String args) {
  final s = args.trim();
  if (s.length > 512) return 'Too long (512 characters at most)';
  if (s.codeUnits.any((c) => c < 0x20 || c > 0x7e)) return 'Use plain letters, digits and symbols only';
  for (final t in s.split(RegExp(r'\s+'))) {
    if (t == '-i' ||
        t == '-p' ||
        t == '-I' ||
        t == '--ip' ||
        t == '--port' ||
        t == '--conn-ip' ||
        RegExp(r'^--(ip|port|conn-ip)=').hasMatch(t) ||
        RegExp(r'^-[ipI].+').hasMatch(t) && !t.startsWith('--')) {
      return "The address and port are set by the app: remove ${t.split('=').first}";
    }
  }
  return null;
}
