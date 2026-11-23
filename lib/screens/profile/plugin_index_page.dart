// Settings > Addons > Find plugins: every public repository of scraper plugins that works today
// (data/sources/plugins/plugin_index.dart), to search and install with one press, by touch, mouse or
// remote. Installing one adds it to Your addons, as pasting its link does.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/sources/addons.dart';
import '../../data/sources/plugins/plugin_index.dart';
import '../../dpad/dpad_traversal.dart';
import '../../widgets/common.dart';

enum _Kind {
  all('All'),
  scrapers('Scraper lists'),
  vega('Vega');

  const _Kind(this.label);
  final String label;
}

enum _Sort {
  best('Most plugins'),
  updated('Recently updated'),
  stars('Most starred');

  const _Sort(this.label);
  final String label;
}

/// A language's name for its code ('tr' → Turkish); the code itself for one not known here.
String languageName(String code) =>
    const {
      'en': 'English', 'ar': 'Arabic', 'tr': 'Turkish', 'es': 'Spanish', 'pt': 'Portuguese', 'pt-br': 'Portuguese (BR)', 'hi': 'Hindi',
      'fr': 'French', 'de': 'German', 'it': 'Italian', 'ita': 'Italian', 'ja': 'Japanese', 'ko': 'Korean', 'zh': 'Chinese', 'ru': 'Russian',
      'uk': 'Ukrainian', 'id': 'Indonesian', 'vi': 'Vietnamese', 'bn': 'Bengali', 'ta': 'Tamil', 'te': 'Telugu', 'ml': 'Malayalam',
      'mal': 'Malayalam', 'kn': 'Kannada', 'hu': 'Hungarian', 'pl': 'Polish', 'th': 'Thai', 'fa': 'Persian', 'ur': 'Urdu', 'ro': 'Romanian',
      'cs': 'Czech', 'sr': 'Serbian', 'hr': 'Croatian', 'bs': 'Bosnian', 'el': 'Greek', 'he': 'Hebrew', 'nl': 'Dutch', 'sv': 'Swedish',
      'mn': 'Mongolian', 'ku': 'Kurdish', 'pa': 'Punjabi', 'et': 'Estonian', 'tl': 'Filipino', 'ms': 'Malay', 'multi': 'Many languages',
    }[code.toLowerCase()] ??
    code.toUpperCase();

/// "today", "3 days ago", "2 months ago".
String _ago(DateTime? d) {
  if (d == null) return '';
  final days = DateTime.now().difference(d).inDays;
  if (days < 1) return 'today';
  if (days < 2) return 'yesterday';
  if (days < 45) return '$days days ago';
  final months = (days / 30).round();
  return months < 18 ? '$months months ago' : '${(days / 365).round()} years ago';
}

class PluginIndexPage extends StatefulWidget {
  const PluginIndexPage({super.key});

  @override
  State<PluginIndexPage> createState() => _PluginIndexPageState();
}

class _PluginIndexPageState extends State<PluginIndexPage> {
  final _query = TextEditingController();
  PluginIndexData? _data;
  String? _error;
  bool _loading = true;
  _Kind _kind = _Kind.all;
  String? _language;
  _Sort _sort = _Sort.best;
  final _busy = <String>{};
  final _failed = <String, String>{};

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    Addons.start();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({bool fresh = false}) async {
    // the copy on this device at once, then the one from the server
    final kept = await PluginIndex.kept();
    if (mounted && kept != null && _data == null) setState(() => _data = kept);
    try {
      final d = await PluginIndex.load(fresh: fresh);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// The same repository however its link is spelled.
  static String _same(String url) => url.trim().toLowerCase().replaceAll('refs/heads/', '');

  Future<void> _install(PluginListing p) async {
    if (_busy.contains(p.url)) return;
    setState(() {
      _busy.add(p.url);
      _failed.remove(p.url);
    });
    try {
      final a = await Addons.install(p.url);
      if (mounted) showToast(context, Text('${a.name} is in Your addons (${a.description}).', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.check_circle_rounded);
    } catch (e) {
      _failed[p.url] = '$e';
    }
    if (mounted) setState(() => _busy.remove(p.url));
  }

  List<PluginListing> _shown(PluginIndexData d) {
    final adult = AppSettings.animeAdult.value;
    final l = [
      for (final p in d.repos)
        if ((adult || !p.adult) &&
            (_kind == _Kind.all || p.kind == _kind.name) &&
            (_language == null || p.languages.contains(_language)) &&
            p.matches(_query.text))
          p,
    ];
    switch (_sort) {
      case _Sort.best:
        l.sort((a, b) => a.featured != b.featured ? (a.featured ? -1 : 1) : b.plugins.compareTo(a.plugins));
      case _Sort.updated:
        l.sort((a, b) => (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0)));
      case _Sort.stars:
        l.sort((a, b) => b.stars != a.stars ? b.stars.compareTo(a.stars) : b.plugins.compareTo(a.plugins));
    }
    return l;
  }

  /// The languages to offer as filters: the most common first.
  List<(String, int)> _languages(PluginIndexData d) {
    final n = <String, int>{};
    for (final p in d.repos) {
      for (final l in p.languages) {
        n[l] = (n[l] ?? 0) + 1;
      }
    }
    return (n.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(14).map((e) => (e.key, e.value)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    // clear of the side rail on the left (a phone: its edges), and of a phone's tab bar below
    final left = phone ? 16.0 : Layout.inset(context), right = phone ? 16.0 : 40.0;
    final bottom = phone ? MediaQuery.paddingOf(context).bottom + 96 : 48.0;
    final top = Layout.topChrome(context);
    final d = _data;
    final shown = d == null ? const <PluginListing>[] : _shown(d);
    return Scaffold(
      backgroundColor: VyseColors.bg,
      body: ValueListenableBuilder<List<Addon>>(
        valueListenable: Addons.list,
        builder: (context, installed, _) {
          final have = {for (final a in installed) _same(a.manifestUrl)};
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(left, top + (phone ? 12 : 28), right, 0),
                sliver: SliverToBoxAdapter(child: _header(d, phone)),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(left, 18, right, 8),
                sliver: SliverToBoxAdapter(child: d == null ? const SizedBox.shrink() : _filters(d)),
              ),
              if (d == null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: _loading
                        ? const SizedBox.square(dimension: 26, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : _Note(
                            text: _error ?? "Couldn't load the plugin list.",
                            action: _Pill(
                              label: 'Try again',
                              icon: Icons.refresh_rounded,
                              onTap: () {
                                setState(() {
                                  _loading = true;
                                  _error = null;
                                });
                                _load(fresh: true);
                              },
                            ),
                          ),
                  ),
                )
              else if (shown.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: _Note(
                      text: 'Nothing matches. Try other words, or another language.',
                      action: _Pill(
                        label: 'Show all',
                        icon: Icons.filter_alt_off_rounded,
                        onTap: () => setState(() {
                          _query.clear();
                          _kind = _Kind.all;
                          _language = null;
                        }),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(left, 10, right, bottom),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 560,
                      mainAxisExtent: phone ? 188 : 176,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final p = shown[i];
                      return _RepoCard(
                        listing: p,
                        first: i == 0,
                        installed: have.contains(_same(p.url)),
                        busy: _busy.contains(p.url),
                        error: _failed[p.url],
                        onInstall: () => _install(p),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(PluginIndexData? d, bool phone) {
    final count = d?.repos.where((p) => AppSettings.animeAdult.value || !p.adult).length;
    final plugins = d?.repos.where((p) => AppSettings.animeAdult.value || !p.adult).fold(0, (n, p) => n + p.plugins);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Round(icon: Icons.arrow_back_rounded, tooltip: 'Back', onTap: () => Navigator.of(context).maybePop()),
            const SizedBox(width: 14),
            Expanded(
              child: Text('Find plugins', style: TextStyle(fontSize: phone ? 24 : 30, fontWeight: FontWeight.w800, letterSpacing: -.6), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (_loading && d != null) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          count == null
              ? 'Repositories of scraper plugins from the community, checked every day.'
              : '$count repositories with $plugins plugins from the community, checked every day. One press adds a repository to Your addons.',
          style: const TextStyle(fontSize: 14, height: 1.4, color: VyseColors.textDim),
        ),
      ],
    );
  }

  Widget _filters(PluginIndexData d) {
    final langs = _languages(d);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SearchBox(controller: _query),
        const SizedBox(height: 14),
        SizedBox(
          height: 36,
          child: DpadRail(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final k in _Kind.values) ...[
                  _Chip(label: k.label, on: _kind == k, entry: _kind == k, onTap: () => setState(() => _kind = k)),
                  const SizedBox(width: 8),
                ],
                const SizedBox(width: 10),
                for (final s in _Sort.values) ...[
                  _Chip(label: s.label, icon: Icons.swap_vert_rounded, on: _sort == s, onTap: () => setState(() => _sort = s)),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        if (langs.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: DpadRail(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _Chip(label: 'Every language', on: _language == null, entry: _language == null, onTap: () => setState(() => _language = null)),
                  for (final (l, n) in langs) ...[
                    const SizedBox(width: 8),
                    _Chip(label: languageName(l), count: n, on: _language == l, entry: _language == l, onTap: () => setState(() => _language = _language == l ? null : l)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A repository: what it is, what it has, and Install (Installed, once it's yours).
class _RepoCard extends StatelessWidget {
  const _RepoCard({required this.listing, required this.first, required this.installed, required this.busy, required this.onInstall, this.error});
  final PluginListing listing;
  final bool first;
  final bool installed;
  final bool busy;
  final String? error;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final p = listing;
    final langs = p.languages.take(3).map((l) => l.toUpperCase()).join(' · ');
    final more = p.languages.length > 3 ? ' +${p.languages.length - 3}' : '';
    return Pressable(
      onTap: installed || busy ? null : onInstall,
      // a remote lands on the first card when the page opens
      autofocusFallback: first,
      focusRadius: 18,
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .985 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(VyseColors.surface, VyseColors.surfaceHi, hovered ? 1 : .35)!,
                VyseColors.surface,
              ],
            ),
            border: Border.all(color: p.featured ? VyseColors.accent.withValues(alpha: hovered ? .55 : .3) : (hovered ? VyseColors.strokeHi : VyseColors.stroke)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Icon(listing: p),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -.2)),
                            ),
                            if (p.featured) ...[
                              const SizedBox(width: 6),
                              const Tooltip(message: 'Picked', child: Icon(Icons.auto_awesome_rounded, size: 15, color: VyseColors.accent)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [if (p.author.isNotEmpty) 'by ${p.author}', p.kind == 'vega' ? 'Vega providers' : 'Scraper list'].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _Action(installed: installed, busy: busy, hovered: hovered),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  error ?? (p.description.isNotEmpty ? p.description : p.names.take(8).join(', ')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, height: 1.4, color: error != null ? const Color(0xFFFF6B6B) : VyseColors.textDim),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _Tag('${p.plugins} plugin${p.plugins == 1 ? '' : 's'}', strong: true),
                  if (langs.isNotEmpty) ...[const SizedBox(width: 6), Flexible(child: _Tag('$langs$more'))],
                  const Spacer(),
                  if (p.stars > 0) ...[
                    const Icon(Icons.star_rounded, size: 14, color: VyseColors.star),
                    const SizedBox(width: 3),
                    Text('${p.stars}', style: const TextStyle(fontSize: 12, color: VyseColors.textDim, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 10),
                  ],
                  if (p.updated != null) Text(_ago(p.updated), style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The repository's picture: an icon of one of its sites, or its first letter on a colour of its own.
class _Icon extends StatelessWidget {
  const _Icon({required this.listing});
  final PluginListing listing;

  @override
  Widget build(BuildContext context) {
    final p = listing;
    final hue = (p.name.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0xffff) % 360).toDouble();
    final letter = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [HSLColor.fromAHSL(1, hue, .55, .45).toColor(), HSLColor.fromAHSL(1, (hue + 40) % 360, .6, .3).toColor()],
        ),
      ),
      alignment: Alignment.center,
      child: Text(p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: SizedBox.square(
        dimension: 46,
        child: p.icon == null ? letter : CachedNetworkImage(imageUrl: p.icon!, fit: BoxFit.cover, errorWidget: (_, _, _) => letter, placeholder: (_, _) => letter),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.installed, required this.busy, required this.hovered});
  final bool installed;
  final bool busy;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    if (busy) return const SizedBox(width: 96, height: 34, child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))));
    if (installed) {
      return Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), color: const Color(0x1F3DDC97)),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded, size: 16, color: Color(0xFF3DDC97)),
            SizedBox(width: 5),
            Text('Installed', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF3DDC97))),
          ],
        ),
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), color: hovered ? Colors.white : const Color(0xFFF1F1F5)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_rounded, size: 17, color: Colors.black),
          SizedBox(width: 4),
          Text('Install', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Colors.black)),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.strong = false});
  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      color: strong ? VyseColors.accent.withValues(alpha: .14) : Colors.white.withValues(alpha: .06),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: strong ? VyseColors.accent : VyseColors.textDim),
          ),
        ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.on, required this.onTap, this.icon, this.entry = false, this.count});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? icon;
  final bool entry;
  final int? count;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    railEntry: entry,
    focusRadius: 18,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: on ? VyseColors.accent.withValues(alpha: .18) : Colors.white.withValues(alpha: hovered ? .12 : .06),
        border: Border.all(color: on ? VyseColors.accent.withValues(alpha: .6) : Colors.transparent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 15, color: on ? VyseColors.accent : VyseColors.textDim), const SizedBox(width: 6)],
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? VyseColors.accent : VyseColors.text)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text('$count', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: on ? VyseColors.accent.withValues(alpha: .75) : VyseColors.textFaint)),
          ],
        ],
      ),
    ),
  );
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 620),
    child: TextField(
      controller: controller,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        hintText: 'Search plugins, sites, languages',
        hintStyle: const TextStyle(color: VyseColors.textFaint),
        isDense: true,
        filled: true,
        fillColor: Colors.white.withValues(alpha: .06),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        prefixIcon: const Icon(Icons.search_rounded, size: 20, color: VyseColors.textDim),
        suffixIcon: controller.text.isEmpty ? null : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded, size: 18), onPressed: controller.clear),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7))),
      ),
    ),
  );
}

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 42,
      height: 42,
      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: hovered ? .14 : .07)),
      child: Icon(icon, size: 21),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PillButton(label: label, icon: icon, onTap: onTap);
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.action});
  final String text;
  final Widget action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, height: 1.4, color: VyseColors.textDim)),
        const SizedBox(height: 16),
        action,
      ],
    ),
  );
}
