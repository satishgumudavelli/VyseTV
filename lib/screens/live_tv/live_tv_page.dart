import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/live_tv/channel_catalog.dart';
import '../../data/live_tv/live_tv.dart';
import '../../data/live_tv/live_favorites.dart';
import '../../data/live_tv/portal_names.dart';
import '../../models/iptv/iptv_models.dart';
import '../../models/iptv/m3u_models.dart';
import '../../services/iptv/hardcoded_channels.dart';
import '../../services/iptv/iptv_network.dart' show CatalogSource;
import '../../dpad/dpad_traversal.dart';
import '../../widgets/common.dart';
import 'live_tv_widgets.dart';
import '../../widgets/media_rows.dart';
import '../../widgets/page_scrollbar.dart';
import '../../widgets/section_chrome.dart';
import 'live_tv_pages.dart';
import 'live_tv_player_page.dart' show openLivePlayer;
import 'matches_view.dart';
import 'portal_browser_page.dart';

/// Live TV: featured channels found across portals, the portal manager, and M3U playlists.
class LiveTvPage extends StatefulWidget {
  const LiveTvPage({super.key});

  @override
  State<LiveTvPage> createState() => _LiveTvPageState();
}

class _LiveTvPageState extends State<LiveTvPage> {
  // The tab you were on, for this run of the app. Before you have picked one: Favorites if you
  // have any (the quick way back to the channels you starred), else Matches.
  static int? _lastTab;
  final _scroll = ScrollController();
  int _tab = _lastTab ?? (LiveFavorites.saved.value.isNotEmpty ? 4 : 3);
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    ensureIptvStarted();
    _search.addListener(() => setState(() {}));
    PortalNames.load();
    LiveFavorites.load().then((_) {
      if (mounted && _lastTab == null && _tab != 4 && LiveFavorites.saved.value.isNotEmpty) setState(() => _tab = 4);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _pick(int i) {
    setState(() => _tab = _lastTab = i);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: _scroll,
          child: ListenableBuilder(
            listenable: Listenable.merge([iptv, LiveFavorites.saved, PortalNames.changes]),
            builder: (context, _) => CustomScrollView(controller: _scroll, slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, top, right, 18),
                sliver: const SliverToBoxAdapter(
                  child: SectionHeader(title: 'Live TV', subtitle: 'Channels, IPTV portals and your M3U playlists'),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 0, right, 24),
                sliver: SliverToBoxAdapter(
                  child: FadeSlideIn(
                    delay: const Duration(milliseconds: 80),
                    offset: 8,
                    // the page's tabs: one row to a D-pad, entered on the tab that is showing
                    child: DpadRail(child: Wrap(spacing: 8, runSpacing: 8, children: [
                      FilterChipPill(
                        label: 'Favorites${LiveFavorites.saved.value.isEmpty ? '' : ' · ${LiveFavorites.saved.value.length}'}',
                        icon: Icons.star_rounded,
                        selected: _tab == 4,
                        tab: true, onTap: () => _pick(4),
                      ),
                      FilterChipPill(label: 'Matches', icon: Icons.sports_soccer_rounded, selected: _tab == 3, tab: true, onTap: () => _pick(3)),
                      FilterChipPill(label: 'Channels', icon: Icons.live_tv_rounded, selected: _tab == 0, tab: true, onTap: () => _pick(0)),
                      FilterChipPill(
                        label: 'Portals${iptv.verified.isEmpty ? '' : ' · ${iptv.verified.length}'}',
                        icon: Icons.dns_rounded,
                        selected: _tab == 1,
                        tab: true, onTap: () => _pick(1),
                      ),
                      FilterChipPill(
                        label: 'Playlists${iptv.m3uPlaylists.isEmpty ? '' : ' · ${iptv.m3uPlaylists.length}'}',
                        icon: Icons.playlist_play_rounded,
                        selected: _tab == 2,
                        tab: true, onTap: () => _pick(2),
                      ),
                    ])),
                  ),
                ),
              ),
              if (iptv.error != null)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, 16),
                  sliver: SliverToBoxAdapter(child: StatusLine(text: iptv.error!, busy: false)),
                ),
              ...switch (_tab) {
                4 => _favorites(context, inset, right),
                3 => [const SliverToBoxAdapter(child: MatchesView())],
                1 => _portals(context, inset, right),
                2 => _playlists(context, inset, right),
                _ => _channels(context, inset, right),
              },
              SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
            ]),
          ),
        ),
      ]),
    );
  }

  // ───────── Favorites ─────────

  /// Every channel you starred, from any portal or playlist, in one list. OK plays one, and
  /// Up and Down in the player then go through the rest of them.
  List<Widget> _favorites(BuildContext context, double inset, double right) {
    final list = LiveFavorites.saved.value;
    if (list.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.star_border_rounded,
            title: 'No favorites yet',
            body: 'Star a channel while it plays, or in a portal\'s list. Every channel you star is kept here.',
          ),
        ),
      ];
    }
    final items = [for (final c in list) LiveItem.favorite(c)];
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
        sliver: SliverList.builder(
          itemCount: list.length,
          itemBuilder: (context, i) => _FavoriteRow(channel: list[i], onTap: () => openLivePlayer(context, items, i)),
        ),
      ),
    ];
  }

  // ───────── Channels ─────────

  List<Widget> _channels(BuildContext context, double inset, double right) {
    // Search matches the name, short name, category and every keyword ("bein", "f1", "sky news").
    final q = _search.text.trim().toLowerCase();
    bool hit(HardcodedChannel c) =>
        q.isEmpty ||
        c.name.toLowerCase().contains(q) ||
        c.short.toLowerCase().contains(q) ||
        c.category.toLowerCase().contains(q) ||
        c.keywords.any((k) => k.toLowerCase().contains(q));
    final byCategory = <String, List<HardcodedChannel>>{};
    for (final c in liveChannels) {
      if (hit(c)) byCategory.putIfAbsent(c.category, () => []).add(c);
    }
    final phone = Layout.isPhone(context);
    final tileW = phone ? 230.0 : (MediaQuery.sizeOf(context).width * .2).clamp(250.0, 380.0);
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 22),
        sliver: SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: VyseSearchField(controller: _search, hint: 'Search channels'),
            ),
          ),
        ),
      ),
      if (byCategory.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(icon: Icons.search_off_rounded, title: 'No channels match "$q"', body: 'Try a shorter name, like "sky" or "espn".'),
        ),
      if (iptv.verified.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 20),
          sliver: SliverToBoxAdapter(
            child: StatusLine(
              busy: false,
              text: 'Channels are found by searching your IPTV portals. Add or find portals in the Portals tab first.',
              onStop: null,
            ),
          ),
        ),
      for (final e in byCategory.entries) ...[
        SliverToBoxAdapter(child: ShelfHeader(title: e.key)),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 4, right, 26),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: tileW,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 16 / 9,
            ),
            itemCount: e.value.length,
            itemBuilder: (context, i) => FadeSlideIn(
              delay: Duration(milliseconds: 25 * (i % 12)),
              offset: 8,
              child: ChannelTile(
                channel: e.value[i],
                onTap: () => Navigator.of(context).push(ShellRoute(child: LiveChannelPage(channel: e.value[i]))),
              ),
            ),
          ),
        ),
      ],
    ];
  }

  // ───────── Portals ─────────

  List<Widget> _portals(BuildContext context, double inset, double right) {
    final portals = <String, VerifiedPortal>{
      for (final p in [...iptv.verified, ...iptv.manualVerified]) p.key: p,
    }.values.toList()
      ..sort((a, b) => (iptv.isFavoritePortal(b.key) ? 1 : 0) - (iptv.isFavoritePortal(a.key) ? 1 : 0));
    final busy = iptv.isScraping || iptv.isLoading || iptv.isImporting;
    final edit = iptv.editMode;

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
        sliver: SliverToBoxAdapter(
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ToolButton(icon: Icons.add_rounded, label: 'Add portal', onTap: iptv.isAdding ? null : () => _addPortal(context)),
            _SourcePicker(),
            ToolButton(icon: Icons.travel_explore_rounded, label: 'Find portals', onTap: busy ? null : iptv.scrape),
            ToolButton(icon: Icons.verified_rounded, label: 'Re-verify', onTap: busy || portals.isEmpty ? null : iptv.runVerification),
            ToolButton(icon: Icons.file_upload_outlined, label: 'Import JSON', onTap: iptv.isImporting ? null : () => _import(context)),
            if (portals.isNotEmpty) ToolButton(icon: edit ? Icons.check_rounded : Icons.edit_rounded, label: edit ? 'Done' : 'Edit', onTap: iptv.toggleEditMode),
          ]),
        ),
      ),
      if (edit)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
          sliver: SliverToBoxAdapter(
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              ToolButton(icon: Icons.select_all_rounded, label: 'Select all', onTap: iptv.selectAllPortals),
              ToolButton(icon: Icons.deselect_rounded, label: 'Select none', onTap: iptv.deselectAllPortals),
              ToolButton(
                icon: Icons.delete_outline_rounded,
                label: 'Delete ${iptv.selected.length}',
                danger: true,
                onTap: iptv.selected.isEmpty ? null : () => iptv.deletePortalsByKeys({...iptv.selected}),
              ),
            ]),
          ),
        ),
      if (busy || iptv.statusText.isNotEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
          sliver: SliverToBoxAdapter(child: StatusLine(text: iptv.statusText.isEmpty ? 'Working…' : iptv.statusText, busy: busy)),
        ),
      if (iptv.addError != null)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
          sliver: SliverToBoxAdapter(child: StatusLine(text: iptv.addError!, busy: false)),
        ),
      if (portals.isEmpty && !busy)
        const SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.dns_outlined,
            title: 'No portals yet',
            body: 'Add one with its URL and login, import a JSON list, or let VyseTV find some.',
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              mainAxisExtent: 88,
            ),
            itemCount: portals.length,
            itemBuilder: (context, i) => FadeSlideIn(
              delay: Duration(milliseconds: 20 * (i % 14)),
              offset: 6,
              child: _PortalCard(portal: portals[i]),
            ),
          ),
        ),
      if (iptv.canGetMore)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 16, right, 0),
          sliver: SliverToBoxAdapter(
            child: Center(child: ToolButton(icon: Icons.expand_more_rounded, label: 'Find more', onTap: busy ? null : iptv.getMore)),
          ),
        ),
    ];
  }

  Future<void> _addPortal(BuildContext context) async {
    final v = await showFieldsDialog(
      context,
      title: 'Add a portal',
      message: 'Xtream Codes login from your provider.',
      confirm: 'Add',
      fields: [
        ('Server URL', 'http://example.com:8080', multiline: false, obscure: false),
        ('Username', 'username', multiline: false, obscure: false),
        ('Password', 'password', multiline: false, obscure: true),
      ],
    );
    if (v == null || v[0].isEmpty) return;
    final ok = await iptv.addManual(url: v[0], username: v[1], password: v[2]);
    if (context.mounted) {
      showToast(context, Text(ok ? 'Portal added' : (iptv.addError ?? "Couldn't verify that portal")),
          icon: ok ? Icons.check_circle_rounded : Icons.error_outline_rounded);
    }
  }

  Future<void> _import(BuildContext context) async {
    final v = await showFieldsDialog(
      context,
      title: 'Import portals',
      message: 'Paste a JSON export of portals.',
      confirm: 'Import',
      fields: [('JSON', '[{"url": …, "username": …, "password": …}]', multiline: true, obscure: false)],
    );
    if (v == null || v[0].isEmpty) return;
    final r = await iptv.importFromJsonString(v[0]);
    if (context.mounted) {
      showToast(
        context,
        Text(r.error ?? 'Added ${r.added}, skipped ${r.skipped}, failed ${r.failed}'),
        icon: r.error == null ? Icons.check_circle_rounded : Icons.error_outline_rounded,
      );
    }
  }

  // ───────── Playlists ─────────

  List<Widget> _playlists(BuildContext context, double inset, double right) {
    final lists = iptv.m3uPlaylists;
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
        sliver: SliverToBoxAdapter(
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            ToolButton(icon: Icons.link_rounded, label: 'Add from URL', onTap: iptv.isM3uLoading ? null : () => _addM3u(context, url: true)),
            ToolButton(icon: Icons.content_paste_rounded, label: 'Paste M3U', onTap: iptv.isM3uLoading ? null : () => _addM3u(context, url: false)),
            if (lists.isNotEmpty)
              ToolButton(icon: Icons.delete_sweep_outlined, label: 'Delete all', danger: true, onTap: () => _confirmDeleteAll(context)),
          ]),
        ),
      ),
      if (iptv.isM3uLoading)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
          sliver: const SliverToBoxAdapter(child: StatusLine(text: 'Loading playlist…')),
        ),
      if (lists.isEmpty && !iptv.isM3uLoading)
        const SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.playlist_add_rounded,
            title: 'No playlists',
            body: 'Add an M3U / M3U8 playlist by URL, or paste its contents.',
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              mainAxisExtent: 88,
            ),
            itemCount: lists.length,
            itemBuilder: (context, i) => _PlaylistCard(playlist: lists[i]),
          ),
        ),
    ];
  }

  Future<void> _addM3u(BuildContext context, {required bool url}) async {
    final v = await showFieldsDialog(
      context,
      title: url ? 'Add playlist' : 'Paste playlist',
      confirm: 'Add',
      fields: [
        ('Name', 'My channels', multiline: false, obscure: false),
        url
            ? ('Playlist URL', 'https://…/playlist.m3u', multiline: false, obscure: false)
            : ('M3U contents', '#EXTM3U …', multiline: true, obscure: false),
      ],
    );
    if (v == null || v[1].isEmpty) return;
    final name = v[0].isEmpty ? 'Playlist' : v[0];
    url ? await iptv.addM3uFromUrl(name, v[1]) : await iptv.addM3uFromContent(name, v[1]);
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surfaceHi,
        title: const Text('Delete all playlists?'),
        content: const Text('This removes every saved M3U playlist from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Color(0xFFFF7A7C)))),
        ],
      ),
    );
    if (ok == true) await iptv.deleteAllM3uPlaylists();
  }
}

class _SourcePicker extends StatelessWidget {
  @override
  Widget build(BuildContext context) => PopupMenuButton<CatalogSource>(
        tooltip: 'Where to look for portals',
        color: VyseColors.surfaceHi,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: VyseColors.stroke)),
        onSelected: iptv.setScrapeSource,
        itemBuilder: (_) => [
          for (final s in CatalogSource.values)
            PopupMenuItem(
              value: s,
              height: 38,
              child: Text(_label(s.name), style: TextStyle(color: s == iptv.scrapeSource ? VyseColors.accent : VyseColors.text)),
            ),
        ],
        // the tool button is the menu button's face: taps and focus are the menu button's
        child: IgnorePointer(child: ExcludeFocus(child: ToolButton(icon: Icons.tune_rounded, label: 'Source: ${_label(iptv.scrapeSource.name)}', onTap: () {}))),
      );

  /// camelCase enum name → "Camel case".
  static String _label(String n) {
    final s = n.replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
  }
}

class _PortalCard extends StatelessWidget {
  const _PortalCard({required this.portal});
  final VerifiedPortal portal;

  Future<void> _rename(BuildContext context) async {
    final v = await showFieldsDialog(
      context,
      title: 'Rename portal',
      message: 'A name of your own for this portal, on this device. Leave it empty to go back to its own.',
      confirm: 'Save',
      fields: [('Name', portalLabel(portal), multiline: false, obscure: false)],
    );
    if (v != null) PortalNames.set(portal.key, v[0]);
  }

  @override
  Widget build(BuildContext context) {
    final fav = iptv.isFavoritePortal(portal.key);
    final edit = iptv.editMode;
    final selected = iptv.selected.contains(portal.key);
    return InfoTile(
      title: portalLabel(portal),
      selected: selected,
      lines: [
        portal.portal.url,
        [
          if (portal.expiry.isNotEmpty) 'Expires ${portal.expiry}',
          if (portal.maxConnections.isNotEmpty) '${portal.activeConnections}/${portal.maxConnections} connections',
        ].join('  ·  '),
      ],
      onTap: () => edit ? iptv.toggleSelect(portal.key) : Navigator.of(context).push(ShellRoute(child: PortalBrowserPage(portal: portal))),
      trailing: edit
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined, size: 20, color: selected ? Colors.white : VyseColors.textFaint),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // a name of your own for it (its own is often just the account's user name)
                IconButton(
                  tooltip: 'Rename',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _rename(context),
                  icon: const Icon(Icons.edit_outlined, size: 18, color: VyseColors.textFaint),
                ),
                // the login in one line, to paste into another app or send to someone
                IconButton(
                  tooltip: 'Copy login (url:username:password)',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final p = portal.portal;
                    final String url = p.url, username = p.username, password = p.password;
                    Clipboard.setData(ClipboardData(text: '$url:$username:$password'));
                    showToast(
                      context,
                      const Text('Portal login copied', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      icon: Icons.copy_rounded,
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18, color: VyseColors.textFaint),
                ),
                IconButton(
                  tooltip: fav ? 'Unfavorite' : 'Favorite',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => iptv.toggleFavoritePortal(portal.key),
                  icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded, size: 20, color: fav ? VyseColors.star : VyseColors.textFaint),
                ),
              ],
            ),
    );
  }
}

/// One favorite channel: OK plays it, and its star (Right, then OK) takes it off the list.
class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({required this.channel, required this.onTap});
  final FavoriteChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white.withValues(alpha: hovered ? .06 : 0)),
        child: Row(children: [
          Container(
            width: 56,
            height: 38,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: VyseColors.surfaceHi, borderRadius: BorderRadius.circular(7)),
            child: NetImage(url: channel.logo, fit: BoxFit.contain, fallback: Icons.live_tv_rounded, decodeWidth: NetImage.decodeWidthFor(context, 48)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(channel.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              if (channel.from != null && channel.from!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(channel.from!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim)),
              ],
            ]),
          ),
          IconButton(
            tooltip: 'Remove from favorites',
            onPressed: () => LiveFavorites.toggleChannel(channel),
            icon: const Icon(Icons.star_rounded, color: VyseColors.star),
          ),
          Icon(Icons.play_circle_outline_rounded, color: hovered ? VyseColors.accent : VyseColors.textFaint),
          const SizedBox(width: 8),
        ]),
      ),
    ),
  );
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist});
  final M3uPlaylist playlist;

  @override
  Widget build(BuildContext context) => InfoTile(
        title: playlist.name,
        lines: [playlist.sourceUrl ?? 'Pasted playlist', '${fmtThousands(playlist.channels.length)} channels'],
        onTap: () => Navigator.of(context).push(ShellRoute(child: M3uPlaylistPage(playlist: playlist))),
        trailing: IconButton(
          tooltip: 'Delete',
          onPressed: () => iptv.deleteM3uPlaylist(playlist.id),
          icon: const Icon(Icons.delete_outline_rounded, size: 19, color: VyseColors.textFaint),
        ),
      );
}
