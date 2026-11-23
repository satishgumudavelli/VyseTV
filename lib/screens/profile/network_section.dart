part of 'profile_page.dart';

/// Settings → Network: WARP Mode, Secure DNS and Anti-DPI Mode (specs/001-warp-doh-anti-dpi/contracts/settings-ui.md).
/// Every state is written in words, every control is a focusable Pressable, a mode this device can't run says so.
class _NetworkTab extends StatefulWidget {
  const _NetworkTab();

  @override
  State<_NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<_NetworkTab> {
  final _modes = NetworkModes.instance;
  late final _custom = TextEditingController(text: AppSettings.netDohUrl.value);
  late final _args = TextEditingController(text: antiDpiArgsFor(AppSettings.netAntiDpiPreset.value, AppSettings.netAntiDpiArgs.value));
  StreamSubscription<String>? _sub;
  String? _last, _dnsProblem, _argsProblem, _argsSaved;
  bool _showArgs = false;

  @override
  void initState() {
    super.initState();
    unawaited(_modes.refreshCapabilities());
    _sub = _modes.messages.listen((m) {
      if (mounted) setState(() => _last = m);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _custom.dispose();
    _args.dispose();
    super.dispose();
  }

  static const _green = Color(0xFF3DDC97);

  Widget _state(ModeState s, {required bool available, required String busy}) {
    final (text, color) = !available
        ? ('Not available on this device', VyseColors.textFaint)
        : switch (s.phase) {
            ModePhase.off => ('Off', VyseColors.textDim),
            ModePhase.starting => (busy, VyseColors.textDim),
            ModePhase.active => ('Active', _green),
            ModePhase.failed => ('Failed: ${s.reason}', _danger),
          };
    return Text(
      text,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color, height: 1.35),
    );
  }

  Widget _subtitle(String text, Widget state, [String? note]) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35)),
      const SizedBox(height: 4),
      state,
      if (note != null) ...[const SizedBox(height: 4), Text(note, style: const TextStyle(fontSize: 12, color: VyseColors.textFaint, height: 1.35))],
    ],
  );

  InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: VyseColors.textFaint),
    isDense: true,
    filled: true,
    fillColor: Colors.white.withValues(alpha: .05),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: VyseColors.stroke),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: VyseColors.stroke),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7)),
    ),
  );

  Widget _problem(String? text, {bool good = false}) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(good ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 16, color: good ? _green : _danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 13, color: good ? VyseColors.textDim : _danger, height: 1.35)),
              ),
            ],
          ),
        );

  // ── the rows ──

  Widget _warpRow(NetworkCapabilities? caps) {
    final available = caps?.warp ?? true;
    final s = _modes.warp.value;
    return _Row(
      title: 'WARP Mode',
      subtitleWidget: _subtitle(
        'Bypass ISP restrictions with Cloudflare WARP',
        _state(s, available: available, busy: 'Connecting…'),
        "Traffic is carried by Cloudflare's WARP service.",
      ),
      trailing: available
          ? _Switch(value: s.phase == ModePhase.active || s.phase == ModePhase.starting, onChanged: (on) => unawaited(_modes.setWarp(on)))
          : null,
    );
  }

  Widget _dnsRow(NetworkCapabilities? caps) {
    final available = caps?.dns ?? true;
    final id = AppSettings.netDoh.value;
    final byWarp = _modes.warp.value.phase == ModePhase.active;
    final String line = !available
        ? 'Not available on this device'
        : byWarp
        ? 'Managed by Cloudflare WARP (resolved remotely). Your choice below applies when WARP is off.'
        : _modes.antiDpi.value.phase == ModePhase.active && id != 'off'
        ? 'Works together with Anti-DPI'
        : id == 'off'
        ? 'Off: the network\'s own DNS is used'
        : 'On: ${dnsProviderById(id).label}';
    const short = {'cloudflare': 'Cloudflare', 'google': 'Google', 'adguard': 'AdGuard', 'custom': 'Custom', 'off': 'Off'};
    return _Row(
      title: 'Secure DNS',
      subtitleWidget: _subtitle(
        'Encrypt DNS queries with a secure resolver',
        Text(
          line,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: !available ? VyseColors.textFaint : (id != 'off' && !byWarp ? _green : VyseColors.textDim),
            height: 1.35,
          ),
        ),
      ),
      below: !available
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Choice<String>(
                  value: id,
                  options: const ['cloudflare', 'google', 'adguard', 'custom', 'off'],
                  label: (v) => '${short[v]}${v == id ? ' ✓' : ''}',
                  onChanged: (v) {
                    setState(() => _dnsProblem = null);
                    unawaited(_modes.setDoh(v));
                  },
                ),
                if (id == 'custom') ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _custom,
                          keyboardType: TextInputType.url,
                          onSubmitted: (_) => _applyCustom(),
                          style: const TextStyle(fontSize: 14),
                          decoration: _decoration('https://dns.example/dns-query'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _SmallButton(label: 'Use this resolver', icon: Icons.check_rounded, primary: true, onTap: _applyCustom),
                    ],
                  ),
                  _problem(_dnsProblem),
                ],
              ],
            ),
    );
  }

  Future<void> _applyCustom() async {
    final bad = await _modes.setCustomDoh(_custom.text);
    if (mounted) setState(() => _dnsProblem = bad);
  }

  Widget _antiDpiRow(NetworkCapabilities? caps) {
    final available = caps?.antiDpi ?? true;
    final s = _modes.antiDpi.value;
    final presetId = AppSettings.netAntiDpiPreset.value;
    return _Row(
      title: 'Anti-DPI Mode',
      subtitleWidget: _subtitle(
        'Get past connection inspection that blocks sites',
        _state(s, available: available, busy: 'Starting…'),
        "Works on connections this app makes; it can't help where a network blocks by address alone: use WARP for that.",
      ),
      trailing: available
          ? _Switch(value: s.phase == ModePhase.active || s.phase == ModePhase.starting, onChanged: (on) => unawaited(_modes.setAntiDpi(on)))
          : null,
      below: !available
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in antiDpiPresets)
                  Pressable(
                    onTap: () {
                      setState(() {
                        _argsProblem = _argsSaved = null;
                        _args.text = p.args;
                      });
                      unawaited(_modes.setAntiDpiPreset(p.id));
                    },
                    builder: (context, hovered, _) => Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white.withValues(alpha: p.id == presetId ? .14 : (hovered ? .08 : .04)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            p.id == presetId ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                            size: 18,
                            color: p.id == presetId ? VyseColors.accent : VyseColors.textDim,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${p.name}${p.id == presetId ? '  ·  Selected' : ''}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                                Text(p.description, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.3)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _SmallButton(
                      label: _showArgs ? 'Hide advanced parameters' : 'Advanced parameters',
                      icon: Icons.tune_rounded,
                      onTap: () => setState(() => _showArgs = !_showArgs),
                    ),
                    if (presetId == 'custom')
                      const Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: Text('Custom parameters in use', style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
                      ),
                  ],
                ),
                if (_showArgs) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _args,
                    style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                    decoration: _decoration(defaultAntiDpiArgs),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _SmallButton(label: 'Save', icon: Icons.check_rounded, primary: true, onTap: _saveArgs),
                      const SizedBox(width: 10),
                      _SmallButton(
                        label: 'Reset to recommended',
                        icon: Icons.restart_alt_rounded,
                        onTap: () {
                          setState(() {
                            _argsProblem = null;
                            _argsSaved = 'Recommended parameters restored';
                            _args.text = defaultAntiDpiArgs;
                          });
                          unawaited(_modes.resetAntiDpiArgs());
                        },
                      ),
                    ],
                  ),
                  _problem(_argsProblem),
                  _problem(_argsSaved, good: true),
                ],
              ],
            ),
    );
  }

  Future<void> _saveArgs() async {
    final bad = await _modes.setAntiDpiArgs(_args.text);
    if (mounted) {
      setState(() {
        _argsProblem = bad;
        _argsSaved = bad == null ? 'Parameters saved' : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _modes.warp,
      _modes.antiDpi,
      _modes.route,
      _modes.capabilities,
      AppSettings.netDoh,
      AppSettings.netDohUrl,
      AppSettings.netAntiDpiPreset,
      AppSettings.netAntiDpiArgs,
    ]),
    builder: (context, _) {
      final caps = _modes.capabilities.value;
      return _Section(
        title: 'Network',
        subtitle: 'For networks that block sites. WARP and Anti-DPI cannot run together; Secure DNS works with Anti-DPI. Saved on this device.',
        children: [
          _warpRow(caps),
          _dnsRow(caps),
          _antiDpiRow(caps),
          if (_last != null) _Row(title: 'Last message', subtitle: _last),
        ],
      );
    },
  );
}
