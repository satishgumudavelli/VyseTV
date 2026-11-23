import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/layout.dart';
import '../../core/nav.dart' show openStremioLink;
import '../../core/theme.dart';
import '../../core/lean.dart';
import '../../data/sources/addons.dart';
import '../../data/sources/debrid/debrid.dart' show Debrid;
import '../../data/anime/anilist.dart';
import '../../data/anime/anime_sources.dart' show AnimeTarget;
import '../../data/sources/badges.dart';
import '../../data/catalog/meta_addons.dart';
import '../../data/catalog/tmdb.dart';
import '../../data/playback/watch_progress.dart';
import '../../data/sources/torrents.dart';
import '../../dpad/dpad_traversal.dart';
import '../../widgets/common.dart';
import '../../widgets/dialogs/debrid_consent.dart';
import '../../widgets/dialogs/p2p_consent.dart';
import '../../data/party/rooms.dart' show Rooms;
import '../../data/party/watch_party.dart';
import '../party/rooms_view.dart' show openRoom;
import 'player_episodes.dart' show EpisodeStore;
import 'player_page.dart';
import '../profile/profile_page.dart';

/// Streaming mode off: before a film or an episode plays, its sources from your Stremio addons,
/// to pick one. Each source reads as its addon wrote it (the way Stremio and Nuvio show them),
/// with badges from your badge template under it. Anime come through here too (by Kitsu id).
/// [notice]: a line said over it as it opens (why it opened instead of the player).
Future<void> openSources(BuildContext context, Media media, {PlayerEpisode? episode, int? runtime, AnimeTarget? anime, String? notice}) =>
    Navigator.of(context, rootNavigator: true).push(_fade(SourcesPage(media: media, episode: episode, runtime: runtime, anime: anime, notice: notice), name: SourcesPage.route));

PageRouteBuilder<void> _fade(Widget page, {String? name}) => PageRouteBuilder(
  settings: RouteSettings(name: name),
  transitionDuration: const Duration(milliseconds: 320),
  reverseTransitionDuration: const Duration(milliseconds: 220),
  pageBuilder: (_, _, _) => page,
  transitionsBuilder: (_, a, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
    child: child,
  ),
);

// ── filters ──

enum _Sort {
  addon('Addon order'),
  seeders('Most seeded'),
  largest('Largest first'),
  smallest('Smallest first'),
  quality('Highest quality');

  const _Sort(this.label);
  final String label;
}

enum _Size {
  small('Under 2 GB', 0, 2e9),
  medium('2–10 GB', 2e9, 10e9),
  large('10–30 GB', 10e9, 30e9),
  huge('Over 30 GB', 30e9, double.infinity);

  const _Size(this.label, this.min, this.max);
  final String label;
  final double min;
  final double max;
  bool has(AddonStream s) => s.size != null && s.size! >= min && s.size! < max;
}

enum _Kind {
  instant('Instant'),
  p2p('Peer to peer');

  const _Kind(this.label);
  final String label;
  bool has(AddonStream s) => this == p2p ? s.torrent : !s.torrent;
}

String _bucket(AddonStream s) => s.bucket;

const _qualities = ['4K', '1080p', '720p', 'SD'];
const _sourceTypes = ['Remux', 'BluRay', 'WEB-DL', 'WEBRip', 'HDTV', 'DVD', 'Cam'];

/// One addon's answer.
class _Result {
  bool loading = true;
  bool covered = true;
  String? error;
  List<AddonStream> streams = const [];
  int torrents = 0;
}

/// What the header says about the title.
class _Info {
  const _Info({required this.title, required this.show, this.episode, this.overview = '', this.art, this.meta = const []});
  final String title; // the film's, or the episode's name
  final String show; // the show, for episodes
  final String? episode; // "Season 2 · Episode 13"
  final String overview;
  final String? art;
  final List<String> meta;
}

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.media, this.episode, this.runtime, this.anime, this.overlay = false, this.playing, this.onPick, this.onClose, this.notice});
  final Media media;

  /// Said over the page as it opens (a title from a metadata addon that TMDB doesn't have:
  /// why it plays from your addons with Streaming mode on).
  final String? notice;
  final PlayerEpisode? episode;
  final int? runtime;
  final AnimeTarget? anime;

  /// Inside the player, over the video still playing ("Choose another source"): see-through, no
  /// art; a pick hands the stream to the player ([onPick]) and Back closes it ([onClose]).
  final bool overlay;

  /// The stream playing now, marked in the list.
  final AddonStream? playing;
  final ValueChanged<AddonPick>? onPick;
  final VoidCallback? onClose;

  /// Its route's name: a player minimized from a source picked here takes this page with it.
  static const route = 'sources';

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  // (growable: the addon whose details carry streams of their own joins it)
  late final List<Addon> _addons = [...Addons.streamAddons];
  late final _results = {for (final a in _addons) a.manifestUrl: _Result()};
  AddonTarget? _target;
  late final Future<_Info> _info = _loadInfo();
  late final Future<String?> _logo = widget.anime != null ? Future.value() : HomeFeed.instance.logo(widget.media);

  // what's shown
  String? _addon; // manifest url, or null for all
  _Sort _sort = _Sort.addon;
  String? _quality;
  String? _language;
  String? _source;
  _Size? _size;
  _Kind? _kind;

  PlayerEpisode? get _ep => widget.episode;
  Media get _m => widget.media;

  @override
  void initState() {
    super.initState();
    Badges.list.addListener(_badgesChanged);
    _ask();
    final notice = widget.notice;
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showToast(context, Text(notice, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.info_outline_rounded);
      });
    }
  }

  @override
  void dispose() {
    Badges.list.removeListener(_badgesChanged);
    unawaited(Torrents.forgetPrepared()); // torrents hovered here but never played
    super.dispose();
  }

  void _badgesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _ask() async {
    final AddonTarget t;
    try {
      t = await Addons.target(_m, season: _ep?.season, episode: _ep?.number, anime: widget.anime?.anime);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        for (final r in _results.values) {
          r
            ..loading = false
            ..error = "Couldn't look the title up";
        }
      });
      return;
    }
    if (!mounted) return;
    // Streams the title's own details carry (Stremio's `streams` on a video): listed first, as
    // that addon's own. An addon that isn't one of your stream addons joins the list for them.
    final from = t.inlineFrom;
    final inline = from == null ? const <AddonStream>[] : [for (final s in t.inline) ?AddonStream.parse(from, s)];
    setState(() {
      _target = t;
      if (inline.isNotEmpty && !_addons.any((a) => a.manifestUrl == from!.manifestUrl)) {
        _addons.insert(0, from!);
        _results[from.manifestUrl] = _Result()
          ..loading = false
          ..streams = inline;
      }
    });
    for (final a in [..._addons]) {
      final r = _results[a.manifestUrl]!;
      if (!a.streams) continue; // (there only for the streams its details carry)
      final own = a.manifestUrl == from?.manifestUrl ? inline : const <AddonStream>[];
      unawaited(
        Addons.streams(
          a,
          t,
          // a plugin repository's streams as each plugin finds them (it is still looking)
          onSome: (l) {
            if (mounted) setState(() => r.streams = [...own, ...l]);
          },
        ).then(
          (got) {
            // torrents among them: start the engine now, so peers are warm by the time one is picked
            if (got != null && got.streams.any((s) => s.torrent)) Torrents.warmUp();
            if (!mounted) return;
            setState(() {
              r
                ..loading = false
                ..covered = got != null || own.isNotEmpty
                ..streams = [...own, ...?got?.streams]
                ..torrents = got?.torrents ?? 0;
            });
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              r
                ..loading = false
                ..error = e is TimeoutException ? 'took too long' : "didn't answer";
            });
          },
        ),
      );
    }
  }

  Future<_Info> _loadInfo() async {
    final ep = _ep;
    final a = widget.anime?.anime;
    String? mins(int? m) => m == null || m <= 0 ? null : (m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m');
    if (a != null) {
      final x = await AnimeExtras.of(a.id).catchError((Object _) => const AnimeExtras());
      final e = ep == null ? null : x.episodes[ep.number];
      return _Info(
        title: ep == null ? a.title : (e?.title ?? ep.name ?? 'Episode ${ep.number}'),
        show: ep == null ? '' : a.title,
        episode: ep == null ? null : 'Episode ${ep.number}',
        overview: (e?.overview.isNotEmpty ?? false) ? e!.overview : a.description,
        art: x.fanart ?? a.banner ?? e?.image ?? a.cover,
        meta: [?a.year?.toString(), ?mins(e?.runtime ?? a.duration), if (a.score != null) '${(a.score! / 10).toStringAsFixed(1)} / 10'],
      );
    }
    if (ep != null) {
      final eps = await EpisodeStore(_m).season(ep.season).catchError((Object _) => const <Never>[]);
      final e = eps.where((x) => x.number == ep.number).firstOrNull;
      return _Info(
        title: e?.name ?? ep.name ?? 'Episode ${ep.number}',
        show: _m.title,
        episode: 'Season ${ep.season} · Episode ${ep.number}',
        overview: (e?.overview.isNotEmpty ?? false) ? e!.overview : _m.overview,
        art: _m.backdrop('w1280') ?? e?.stillUrl('w1280'),
        meta: [if (e?.aired != null) '${e!.aired!.year}' else ?_m.year, ?mins(e?.runtime), if (_m.rating > 0) '${_m.rating.toStringAsFixed(1)} / 10'],
      );
    }
    final d = await HomeFeed.instance.details(_m).then<MediaDetails?>((d) => d, onError: (Object _) => null);
    return _Info(
      title: _m.title,
      show: '',
      overview: d?.media.overview.isNotEmpty == true ? d!.media.overview : _m.overview,
      art: _m.backdrop('w1280'),
      meta: [?_m.year, ?mins(d?.runtime ?? widget.runtime), if (_m.rating > 0) '${_m.rating.toStringAsFixed(1)} / 10', ...?d?.genres.take(2)],
    );
  }

  // ── the list ──

  List<AddonStream> get _everything => [for (final a in _addons) ..._results[a.manifestUrl]!.streams];

  Iterable<AddonStream> get _fromAddon sync* {
    for (final a in _addons) {
      if (_addon == null || _addon == a.manifestUrl) yield* _results[a.manifestUrl]!.streams;
    }
  }

  bool _passes(AddonStream s) =>
      (_quality == null || _bucket(s) == _quality) &&
      (_language == null || s.languages.contains(_language)) &&
      (_source == null || s.source == _source) &&
      (_size == null || _size!.has(s)) &&
      (_kind == null || _kind!.has(s));

  static int _best(AddonStream a, AddonStream b) => Addons.byBest(a, b);

  /// The list's order, by [_key]: a stream on the list keeps its place as more come in (addons and
  /// plugins answer one after another), so the one about to be picked never moves, nor does the
  /// row a remote's ring is on; later ones go below, in the chosen order among themselves. Another
  /// sort, filter or addon tab puts the whole list in that order afresh.
  List<String> _order = const [];
  Object? _orderFor;

  static String _key(AddonStream s) => '${s.addon.manifestUrl}|${s.infoHash ?? ''}|${s.fileIdx ?? ''}|${s.url}|${s.name}|${s.description}';

  List<AddonStream> get _shown {
    final view = (_sort, _addon, _quality, _language, _source, _size, _kind);
    if (view != _orderFor) {
      _orderFor = view;
      _order = const [];
    }
    // (two streams alike in every way are told apart by their turn)
    final seen = <String, int>{};
    final keyed = <(String, AddonStream)>[
      for (final st in _sorted)
        () {
          final k = _key(st);
          final n = seen[k] = (seen[k] ?? 0) + 1;
          return (n == 1 ? k : '$k#$n', st);
        }(),
    ];
    final byKey = {for (final (k, st) in keyed) k: st};
    final before = _order.toSet();
    _order = [
      for (final k in _order)
        if (byKey.containsKey(k)) k,
      for (final (k, _) in keyed)
        if (!before.contains(k)) k,
    ];
    return [for (final k in _order) byKey[k]!];
  }

  List<AddonStream> get _sorted {
    final l = [
      for (final s in _fromAddon)
        if (_passes(s)) s,
    ];
    switch (_sort) {
      case _Sort.addon:
        break;
      case _Sort.seeders:
        l.sort((a, b) => (b.seeders ?? -1).compareTo(a.seeders ?? -1));
      case _Sort.largest:
        l.sort((a, b) => (b.size ?? 0).compareTo(a.size ?? 0));
      case _Sort.smallest:
        l.sort((a, b) => (a.size ?? 1 << 62).compareTo(b.size ?? 1 << 62));
      case _Sort.quality:
        l.sort(_best);
    }
    // links that open elsewhere (a page, a YouTube video) come after everything that plays
    return [...l.where((s) => s.playable), ...l.where((s) => !s.playable)];
  }

  bool get _loading => _results.values.any((r) => r.loading);
  int get _torrents => _results.values.fold(0, (n, r) => n + r.torrents);
  bool get _filtered => _quality != null || _language != null || _source != null || _size != null || _kind != null;

  void _clear() => setState(() {
    _quality = _language = _source = null;
    _size = null;
    _kind = null;
  });

  // ── playing ──

  Future<void> _play(AddonStream s) async {
    final t = _target;
    if (t == null) return;
    HapticFeedback.selectionClick();
    if (!s.playable) return _openLink(s.external!);
    // P2P off: ask first, and start nothing unless allowed (in your room, everyone there too)
    final party = Rooms.mine.value?.iOwn == true;
    // with debrid on, torrents come from the service: nothing peer to peer to agree to
    final p2p = s.torrent && !Debrid.active;
    if (p2p && !await allowP2p(context)) return;
    if (p2p && party && mounted && !await allowP2pTogether(context)) return;
    // your room, through your debrid account: everyone there plays your link, so say so first
    // (a source changed from inside the room's player is asked there, in the player)
    if (party && !widget.overlay && s.torrent && Debrid.active && mounted && !await allowDebridInRoom(context)) return;
    if (!mounted) return;
    if (widget.overlay) return widget.onPick?.call(AddonPick(s, t));
    if (party) {
      // your room: this exact source plays there for everyone
      final ep = _ep;
      try {
        await WatchParty.hostState(WatchState(
          media: _m,
          season: ep?.season,
          episode: ep?.number,
          episodeName: ep?.name,
          position: WatchProgress.resumeSeconds(_m, season: ep?.season, episode: ep?.number),
          playing: true,
          by: WatchParty.me,
          source: WatchParty.sourceJson(AddonPick(s, t)),
        ));
      } catch (_) {
        if (mounted) showToast(context, const Text("Couldn't start it in your room", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
        return;
      }
      if (mounted) openRoom(Navigator.of(context), theater: true);
      return;
    }
    Navigator.of(context).push(_fade(PlayerPage(media: _m, episode: _ep, runtime: widget.runtime, anime: widget.anime, pick: AddonPick(s, t))));
  }

  /// A source that is a link: a Stremio link opens its page in VyseTV, anything else (a web page,
  /// a YouTube video) where it lives.
  Future<void> _openLink(String link) async {
    if (await openStremioLink(context, link)) return;
    final ok = await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication).catchError((Object _) => false);
    if (!ok && mounted) {
      showToast(context, const Text("Couldn't open the link", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
    }
  }

  /// Back: closes the overlay (the video keeps playing), or leaves the page.
  void _close() => widget.overlay ? widget.onClose?.call() : Navigator.of(context).maybePop();

  bool _isPlaying(AddonStream s) {
    final p = widget.playing;
    if (p == null) return false;
    return p.torrent ? s.infoHash == p.infoHash && s.fileIdx == p.fileIdx : s.url == p.url;
  }

  /// VyseTV's own servers instead. A title from a metadata addon plays there as its TMDB match;
  /// one TMDB doesn't have says so and stays here.
  Future<void> _builtIn() async {
    var m = _m;
    if (m.isAddon && !m.tmdbKnown) {
      final twin = await MetaAddons.twin(m).catchError((Object _) => null);
      if (!mounted) return;
      if (twin == null || !twin.tmdbKnown) {
        showToast(
          context,
          Text("${m.title} isn't on TMDB, so VyseTV's servers can't find it", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          icon: Icons.info_outline_rounded,
        );
        return;
      }
      m = twin;
    }
    unawaited(Navigator.of(context).pushReplacement(_fade(PlayerPage(media: m, episode: _ep, runtime: widget.runtime, anime: widget.anime))));
  }

  void _openAddons() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProfilePage(addons: true)));

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.escape || e.logicalKey == LogicalKeyboardKey.backspace)) {
        _close();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Material(
      // over the player: dimmed and blurred, the video still moving underneath
      color: widget.overlay ? Colors.transparent : VyseColors.bg,
      child: _Backdrop(
        on: widget.overlay,
        child: FutureBuilder<_Info>(
          future: _info,
          builder: (context, snap) {
            // until the details arrive: what's already known, the episode line included
            final ep = _ep;
            final info =
                snap.data ??
                _Info(
                  title: ep == null ? _m.title : (ep.name ?? 'Episode ${ep.number}'),
                  show: ep == null ? '' : _m.title,
                  episode: ep == null ? null : (widget.anime != null ? 'Episode ${ep.number}' : 'Season ${ep.season} · Episode ${ep.number}'),
                  art: _m.backdrop('w1280'),
                );
            return Layout.isPhone(context) ? _phone(info) : _desktop(info);
          },
        ),
      ),
    ),
  );

  // ── phone: the art and title on top, then the list ──

  Widget _phone(_Info info) {
    final top = MediaQuery.paddingOf(context).top;
    final list = _shown;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 250 + top,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!widget.overlay) _Art(url: info.art),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x8C000000), Color(0x00000000), Color(0xE607080F), VyseColors.bg],
                      stops: [0, .32, .82, 1],
                    ),
                  ),
                ),
                Positioned(
                  top: top + 6,
                  left: 6,
                  child: _Back(onTap: _close),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 4,
                  child: _Heading(info: info, logo: _logo, compact: true),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 0), child: _controls(phone: true)),
        ),
        ..._listSlivers(list, const EdgeInsets.fromLTRB(12, 12, 12, 0), phone: true),
        SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom)),
      ],
    );
  }

  // ── desktop: the list on the left; the title over its art on the right ──

  Widget _desktop(_Info info) {
    final size = MediaQuery.sizeOf(context);
    final top = Layout.windowChrome(context) + 26;
    final inset = Layout.inset(context);
    final listW = math.min(720.0, size.width * .52);
    final list = _shown;
    // "Play best" is what autoplay would pick: your autoplay order when you've set one
    final playable = [for (final s in list) if (s.playable) s];
    final best = AutoplayOrder.arrange(playable).firstOrNull ?? (playable.isEmpty ? null : ([...playable]..sort(_best)).first);
    return Stack(
      children: [
        // the art fills the right of the window and fades into the page behind the list
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: size.width * .66,
          // (lean: the same picture without the off-screen buffers, _LeanArt)
          child: Lean.on
              ? (widget.overlay ? const SizedBox.shrink() : _LeanArt(url: info.art))
              : ShaderMask(
            shaderCallback: (r) => const LinearGradient(colors: [Color(0x00FFFFFF), Color(0x99FFFFFF), Color(0xFFFFFFFF)], stops: [0, .35, .7]).createShader(r),
            blendMode: BlendMode.dstIn,
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
                stops: [0, .55, 1],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: widget.overlay ? const SizedBox.shrink() : Opacity(opacity: .5, child: _Art(url: info.art)),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(inset, top, inset, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: listW,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _Back(onTap: _close),
                              const SizedBox(width: 12),
                              const Text('Sources', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
                              const SizedBox(width: 12),
                              if (_loading)
                                const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: VyseColors.textDim))
                              else
                                Text(
                                  '${_everything.length}',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: VyseColors.textFaint),
                                ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          _controls(phone: false),
                        ],
                      ),
                    ),
                    ..._listSlivers(list, const EdgeInsets.only(top: 14), phone: false),
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                ),
              ),
              const Spacer(),
              // the title, over its art
              SizedBox(
                width: math.min(420.0, size.width * .3),
                child: Padding(
                  padding: EdgeInsets.only(top: size.height * .16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Heading(info: info, logo: _logo, compact: false),
                      if (info.overview.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          info.overview,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, height: 1.55, color: Color(0xD9F4F5FB)),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          if (best != null) ...[_Primary(label: 'Play best', onTap: () => _play(best)), const SizedBox(width: 10)],
                          if (!widget.overlay) _Secondary(label: 'VyseTV servers', onTap: _builtIn),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── tabs and filters ──

  Widget _controls({required bool phone}) {
    if (_addons.isEmpty) return const SizedBox.shrink();
    final all = _everything;
    final langs = <String, int>{};
    for (final s in all) {
      for (final l in s.languages) {
        langs[l] = (langs[l] ?? 0) + 1;
      }
    }
    final langList = langs.keys.toList()..sort((a, b) => langs[b]!.compareTo(langs[a]!));
    int count(bool Function(AddonStream) f) => all.where(f).length;
    final kinds = all.any((s) => s.torrent) && all.any((s) => !s.torrent);
    final filters = <Widget>[
      _Dropdown<_Sort>(
        icon: Icons.swap_vert_rounded,
        label: _sort.label,
        active: _sort != _Sort.addon,
        value: _sort,
        options: [for (final s in _Sort.values) (s, s.label, null)],
        onPick: (s) => setState(() => _sort = s ?? _Sort.addon),
        nullable: false,
      ),
      _Dropdown<String>(
        label: _quality ?? 'Quality',
        active: _quality != null,
        value: _quality,
        options: [for (final q in _qualities) (q, q, count((s) => _bucket(s) == q))],
        onPick: (q) => setState(() => _quality = q),
      ),
      _Dropdown<String>(
        label: _source ?? 'Source',
        active: _source != null,
        value: _source,
        options: [
          for (final t in _sourceTypes)
            if (all.any((s) => s.source == t)) (t, t, count((s) => s.source == t)),
        ],
        onPick: (t) => setState(() => _source = t),
      ),
      _Dropdown<_Size>(
        label: _size?.label ?? 'Size',
        active: _size != null,
        value: _size,
        options: [for (final z in _Size.values) (z, z.label, count(z.has))],
        onPick: (z) => setState(() => _size = z),
      ),
      // These two come with the streams (a language named, torrents and links both): at the end, with
      // their room kept while there is nothing to pick, so the bar never grows and pushes the list
      // down as streams come in. (A phone's bar is one row that scrolls: nothing to keep there.)
      if (langList.isNotEmpty || !phone)
        _Kept(
          shown: langList.isNotEmpty,
          child: _Dropdown<String>(
            label: _language ?? 'Language',
            active: _language != null,
            value: _language,
            options: [for (final l in langList) (l, l, langs[l])],
            onPick: (l) => setState(() => _language = l),
          ),
        ),
      if (kinds || !phone)
        _Kept(
          shown: kinds,
          child: _Dropdown<_Kind>(
            label: _kind?.label ?? 'Type',
            active: _kind != null,
            value: _kind,
            options: [for (final k in _Kind.values) (k, k.label, count(k.has))],
            onPick: (k) => setState(() => _kind = k),
          ),
        ),
      if (_filtered) _ClearButton(onTap: _clear),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // which addon: the app's own underlined tabs
        SizedBox(
          height: 34,
          // the tabs: one row to a D-pad, entered on the tab that is showing
          child: DpadRail(child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _Tab(label: 'All', count: all.length, loading: _loading, selected: _addon == null, onTap: () => setState(() => _addon = null)),
              for (final a in _addons)
                _Tab(
                  label: a.name,
                  count: _results[a.manifestUrl]!.streams.length,
                  loading: _results[a.manifestUrl]!.loading,
                  failed: _results[a.manifestUrl]!.error != null,
                  selected: _addon == a.manifestUrl,
                  onTap: () => setState(() => _addon = a.manifestUrl),
                ),
            ],
          )),
        ),
        const Divider(height: 1, thickness: 1, color: VyseColors.stroke),
        const SizedBox(height: 14),
        phone
            ? SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: filters.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => filters[i],
                ),
              )
            : Wrap(spacing: 8, runSpacing: 8, children: filters),
      ],
    );
  }

  List<Widget> _listSlivers(List<AddonStream> list, EdgeInsets pad, {required bool phone}) {
    Widget one(Widget child) => SliverPadding(
      padding: pad,
      sliver: SliverToBoxAdapter(child: child),
    );
    if (_addons.isEmpty) {
      return [
        one(
          _Note(
            title: 'No source addons',
            text: 'Install a Stremio addon in Settings › Addons and its sources show up here.',
            actions: [
              _Primary(label: 'Add addons', onTap: _openAddons),
              if (!widget.overlay) _Secondary(label: 'VyseTV servers', onTap: _builtIn),
            ],
          ),
        ),
      ];
    }
    if (list.isEmpty && _loading) {
      return [
        SliverPadding(
          padding: pad,
          sliver: SliverList.list(children: [for (var i = 0; i < 5; i++) const _Skeleton()]),
        ),
      ];
    }
    if (list.isEmpty) {
      final t = _torrents;
      return [
        one(
          _Note(
            title: _filtered ? 'Nothing matches these filters' : 'No sources',
            text: _filtered
                ? 'Loosen a filter to see more.'
                : t > 0
                ? 'Your addons found $t torrents, but this device can only play them through a debrid service set up in the addon.'
                : 'Your addons have nothing for this right now.',
            actions: [
              if (_filtered) _Secondary(label: 'Clear filters', onTap: _clear),
              if (!widget.overlay) _Secondary(label: 'VyseTV servers', onTap: _builtIn),
            ],
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: pad,
        sliver: SliverList.builder(
          itemCount: list.length + (widget.overlay ? 0 : 1),
          itemBuilder: (context, i) => i == list.length
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: TextButton(
                      onPressed: _builtIn,
                      child: const Text('Play with VyseTV’s servers instead', style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
                    ),
                  ),
                )
              : _SourceRow(stream: list[i], phone: phone, playing: _isPlaying(list[i]), onTap: () => _play(list[i])),
        ),
      ),
    ];
  }
}

// ───────────────────────── pieces ─────────────────────────

/// A filter that is there only once the streams give it something to pick: until then its room is
/// kept, blank, and nothing can land on it.
class _Kept extends StatelessWidget {
  const _Kept({required this.shown, required this.child});
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) => Visibility(
    visible: shown,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: ExcludeFocus(excluding: !shown, child: child),
  );
}

/// Over the player: the video, blurred and dimmed, behind the list.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.on, required this.child});
  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) => !on
      ? child
      : Stack(
          children: [
            Positioned.fill(
              // Lean (a TV): dimmed only. The video is on a surface of its own behind the
              // interface, where a blur can't reach it, so this one blurred nothing and still
              // cost an off-screen copy of the screen for every frame.
              child: Lean.on
                  ? const ColoredBox(color: Color(0xB807080F))
                  : ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: const ColoredBox(color: Color(0xB807080F)),
                ),
              ),
            ),
            Positioned.fill(child: child),
          ],
        );
}

/// The art as the two masks and the fade leave it, without them (lean, core/lean.dart): at half
/// strength, melting into the page on the left and at the bottom. Over a page of one colour, a
/// picture faded and masked away is that picture under veils of the page's colour, and those
/// are plain draws where each mask is an off-screen copy of two thirds of the screen.
class _LeanArt extends StatelessWidget {
  const _LeanArt({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    const bg = VyseColors.bg;
    final u = url;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (u == null)
          ColoredBox(color: Color.lerp(bg, VyseColors.surface, .5)!)
        else
          CachedNetworkImage(
            imageUrl: u,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            fadeInDuration: const Duration(milliseconds: 400),
            color: bg.withValues(alpha: .5),
            colorBlendMode: BlendMode.srcOver,
            placeholder: (_, _) => const ColoredBox(color: bg),
            errorWidget: (_, _, _) => const ColoredBox(color: bg),
          ),
        const Scrim.left(alphas: [1, .4, 0], stops: [0, .35, .7]),
        const Scrim.bottom(alphas: [1, 0], stops: [0, .45]),
      ],
    );
  }
}

class _Art extends StatelessWidget {
  const _Art({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) => url == null
      ? const ColoredBox(color: VyseColors.surface)
      : CachedNetworkImage(
          imageUrl: url!,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          fadeInDuration: const Duration(milliseconds: 400),
          placeholder: (_, _) => const ColoredBox(color: VyseColors.bg),
          errorWidget: (_, _, _) => const ColoredBox(color: VyseColors.bg),
        );
}

class _Back extends StatelessWidget {
  const _Back({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: hovered ? .14 : .07),
      ),
      child: const Icon(Icons.arrow_back_rounded, size: 20, color: VyseColors.text),
    ),
  );
}

/// The title as its logo (or its name), the episode, and a line of facts.
class _Heading extends StatelessWidget {
  const _Heading({required this.info, required this.logo, required this.compact});
  final _Info info;
  final Future<String?> logo;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final name = info.show.isNotEmpty ? info.show : info.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder<String?>(
          future: logo,
          builder: (context, snap) => snap.data == null
              ? Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: compact ? 28 : 36, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -1),
                )
              : ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: compact ? 56 : 92, maxWidth: compact ? 240 : 360),
                  child: CachedNetworkImage(
                    imageUrl: snap.data!,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomLeft,
                    errorWidget: (_, _, _) => Text(name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                  ),
                ),
        ),
        if (info.episode != null) ...[
          SizedBox(height: compact ? 10 : 16),
          Text(
            info.episode!.toUpperCase(),
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.3, color: VyseColors.textDim),
          ),
          const SizedBox(height: 3),
          Text(
            info.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: compact ? 17 : 20, fontWeight: FontWeight.w700, letterSpacing: -.3),
          ),
        ],
        if (info.meta.isNotEmpty) ...[
          SizedBox(height: compact ? 6 : 10),
          Text(
            info.meta.join('   ·   '),
            style: const TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.count, required this.loading, required this.selected, required this.onTap, this.failed = false});
  final String label;
  final int count;
  final bool loading;
  final bool failed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    railEntry: selected, // where a D-pad comes into the row of tabs
    builder: (context, hovered, _) => Padding(
      padding: const EdgeInsets.only(right: 26),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected || hovered ? VyseColors.text : VyseColors.textDim,
                ),
              ),
              const SizedBox(width: 7),
              if (loading)
                const SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: VyseColors.textFaint))
              else if (failed)
                const Tooltip(
                  message: "This addon didn't answer",
                  child: Icon(Icons.error_outline_rounded, size: 14, color: Color(0xFFF26B6B)),
                )
              else
                Text(
                  '$count',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.textFaint),
                ),
            ],
          ),
          const SizedBox(height: 9),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            height: 2,
            width: selected ? 24 : 0,
            decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(1)),
          ),
        ],
      ),
    ),
  );
}

/// A filter as a small button that opens its choices; it reads as the choice once one is made.
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.active,
    required this.value,
    required this.options,
    required this.onPick,
    this.icon,
    this.nullable = true,
  });
  final String label;
  final bool active;
  final T? value;
  final List<(T, String, int?)> options; // value, label, how many
  final ValueChanged<T?> onPick;
  final IconData? icon;
  final bool nullable;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height + 6));
    final picked = await showMenu<Object>(
      context: context,
      color: const Color(0xFF151827),
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: VyseColors.stroke),
      ),
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        if (nullable) _item('Any', null, value == null),
        for (final (v, l, n) in options) _item(l, n, v == value, value: v),
      ],
    );
    if (picked == null) return;
    onPick(picked is _Any ? null : picked as T);
  }

  PopupMenuItem<Object> _item(String label, int? count, bool on, {Object? value}) => PopupMenuItem<Object>(
    value: value ?? const _Any(),
    height: 38,
    child: SizedBox(
      width: 180,
      child: Row(
        children: [
          SizedBox(width: 22, child: on ? const Icon(Icons.check_rounded, size: 16, color: VyseColors.accent) : null),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
          ),
          if (count != null) Text('$count', style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => _open(context),
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      height: 34,
      padding: EdgeInsets.fromLTRB(icon == null ? 13 : 10, 0, 9, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: active ? Colors.white.withValues(alpha: hovered ? .18 : .13) : Colors.white.withValues(alpha: hovered ? .08 : .04),
        border: Border.all(color: active ? Colors.white.withValues(alpha: .22) : VyseColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16, color: active ? VyseColors.text : VyseColors.textDim), const SizedBox(width: 6)],
          Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: active ? VyseColors.text : VyseColors.textDim),
          ),
          const SizedBox(width: 3),
          Icon(Icons.expand_more_rounded, size: 17, color: active ? VyseColors.text : VyseColors.textFaint),
        ],
      ),
    ),
  );
}

class _Any {
  const _Any();
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => SizedBox(
      height: 34,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            'Clear',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: hovered ? VyseColors.text : VyseColors.accent),
          ),
        ),
      ),
    ),
  );
}

/// One source: its addon's logo, the description as the addon wrote it, and the template's badges
/// underneath.
/// Where a source that is a link goes: VyseTV (a Stremio link), YouTube, or the browser.
class _Opens extends StatelessWidget {
  const _Opens({required this.link});
  final String link;

  @override
  Widget build(BuildContext context) {
    final where = StremioLink.parse(link) != null
        ? 'Opens in VyseTV'
        : (link.contains('youtube.com/') || link.contains('youtu.be/') ? 'Opens on YouTube' : 'Opens in your browser');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.open_in_new_rounded, size: 14, color: VyseColors.accent),
        const SizedBox(width: 6),
        Flexible(
          child: Text(where, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.accent)),
        ),
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.stream, required this.phone, required this.onTap, this.playing = false});
  final AddonStream stream;
  final bool phone;
  final VoidCallback onTap;
  final bool playing; // the one on screen now (in the player's overlay)

  static const _now = Text(
    'NOW PLAYING',
    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.accent),
  );

  @override
  Widget build(BuildContext context) {
    final s = stream;
    final description = s.description;
    final badges = s.badges;
    // a torrent starts fetching its file list as soon as you point at it or press it
    void prepare() {
      if (s.torrent && !Debrid.active) Torrents.prepare(s.infoHash!, trackers: s.trackers, title: s.release);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => prepare(),
        child: Listener(
          onPointerDown: (_) => prepare(),
          child: Pressable(
            onTap: onTap,
            builder: (context, hovered, pressed) => AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: EdgeInsets.fromLTRB(phone ? 14 : 18, 14, phone ? 14 : 16, 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: pressed ? const Color(0x1FFFFFFF) : (hovered ? const Color(0x14FFFFFF) : const Color(0x0BFFFFFF)),
                border: playing ? Border.all(color: VyseColors.accent.withValues(alpha: .55)) : null,
              ),
              child: phone
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (playing) ...[_now, const SizedBox(height: 8)],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AddonLogo(addon: s.addon, size: 34),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (description.isNotEmpty) Text(description, maxLines: 7, overflow: TextOverflow.ellipsis, style: _descStyle),
                                  if (!s.playable) ...[SizedBox(height: description.isEmpty ? 0 : 8), _Opens(link: s.external!)],
                                ],
                              ),
                            ),
                            if (s.torrent) ...[const SizedBox(width: 6), _CopyMagnet(stream: s)],
                          ],
                        ),
                        if (badges.isNotEmpty) ...[const SizedBox(height: 12), BadgeRow(badges: badges)],
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AddonLogo(addon: s.addon, size: 44),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (playing) ...[_now, const SizedBox(height: 6)],
                              if (description.isNotEmpty) Text(description, maxLines: 7, overflow: TextOverflow.ellipsis, style: _descStyle),
                              if (!s.playable) ...[SizedBox(height: description.isEmpty ? 0 : 8), _Opens(link: s.external!)],
                              if (badges.isNotEmpty) ...[SizedBox(height: description.isEmpty ? 0 : 12), BadgeRow(badges: badges)],
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 140),
                          opacity: hovered ? 1 : 0,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (s.torrent) ...[_CopyMagnet(stream: s), const SizedBox(width: 6)],
                              const Padding(
                                padding: EdgeInsets.only(top: 2),
                                child: Icon(Icons.play_arrow_rounded, size: 22, color: VyseColors.text),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  static const _descStyle = TextStyle(fontSize: 13, height: 1.5, color: Color(0xFFB4B9D2));
}

/// Copies a torrent source's magnet link, for opening it in another app.
class _CopyMagnet extends StatelessWidget {
  const _CopyMagnet({required this.stream});
  final AddonStream stream;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Copy magnet link',
    onPressed: () {
      Clipboard.setData(ClipboardData(text: Torrents.magnet(stream.infoHash!, trackers: stream.trackers, title: stream.release)));
      showToast(context, const Text('Magnet link copied', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.link_rounded);
    },
    icon: const Icon(Icons.link_rounded),
    iconSize: 18,
    color: VyseColors.textDim,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
  );
}

/// The addon's own logo (its first letter when it has none), named in a tooltip.
class AddonLogo extends StatelessWidget {
  const AddonLogo({super.key, required this.addon, required this.size});
  final Addon addon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      color: const Color(0x1FFFFFFF),
      alignment: Alignment.center,
      child: Text(
        addon.name.isEmpty ? '?' : addon.name.characters.first.toUpperCase(),
        style: TextStyle(fontSize: size * .42, fontWeight: FontWeight.w800, color: VyseColors.textDim),
      ),
    );
    return Tooltip(
      message: addon.name,
      waitDuration: tooltipWait(const Duration(milliseconds: 400)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .24),
        child: SizedBox.square(
          dimension: size,
          child: addon.logo == null
              ? letter
              : CachedNetworkImage(
                  imageUrl: addon.logo!,
                  fit: BoxFit.cover,
                  memCacheWidth: (size * 3).round(),
                  placeholder: (_, _) => const ColoredBox(color: Color(0x14FFFFFF)),
                  errorWidget: (_, _, _) => letter,
                ),
        ),
      ),
    );
  }
}

/// The badges, as their images at one height (or as text tags, for badges without one).
class BadgeRow extends StatelessWidget {
  const BadgeRow({super.key, required this.badges, this.height = 19});
  final List<SourceBadge> badges;
  final double height;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 7,
    runSpacing: 7,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [for (final b in badges) _BadgeView(badge: b, height: height)],
  );
}

class _BadgeView extends StatelessWidget {
  const _BadgeView({required this.badge, required this.height});
  final SourceBadge badge;
  final double height;

  static String _plain(String s) => s.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();

  @override
  Widget build(BuildContext context) {
    final b = badge;
    final tag = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: b.tag != null && (b.tag! >> 24) > 0 ? Color(b.tag!) : const Color(0x1AFFFFFF),
        border: b.border != null && (b.border! >> 24) > 0 ? Border.all(color: Color(b.border!)) : null,
      ),
      child: Text(
        _plain(b.name),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: .3,
          color: b.text != null && (b.text! >> 24) > 0 ? Color(b.text!) : VyseColors.textDim,
        ),
      ),
    );
    if (b.image == null) return tag;
    return Tooltip(
      message: _plain(b.name),
      waitDuration: tooltipWait(const Duration(milliseconds: 500)),
      child: CachedNetworkImage(
        imageUrl: b.image!,
        height: height,
        fit: BoxFit.contain,
        memCacheHeight: (height * 3).round(), // some are 2000 px wide; keep them light
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => SizedBox(height: height, width: height * 2),
        errorWidget: (_, _, _) => tag,
      ),
    );
  }
}

class _Primary extends StatelessWidget {
  const _Primary({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .97 : 1,
      duration: const Duration(milliseconds: 100),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 42,
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: hovered ? const Color(0xFFE6E7EE) : Colors.white),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow_rounded, size: 22, color: Colors.black),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.black),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Secondary extends StatelessWidget {
  const _Secondary({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.white.withValues(alpha: hovered ? .16 : .09),
      ),
      child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.title, required this.text, required this.actions});
  final String title;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(text, style: const TextStyle(fontSize: 13.5, color: VyseColors.textDim, height: 1.45)),
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: actions),
      ],
    ),
  );
}

/// A row-shaped placeholder that breathes while addons answer.
class _Skeleton extends StatefulWidget {
  const _Skeleton();

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton> with SingleTickerProviderStateMixin {
  late final _c = Lean.loop(AnimationController(vsync: this, duration: const Duration(milliseconds: 1000)), reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final a = .04 + .03 * Curves.easeInOut.transform(_c.value);
      Widget bar(double w, double h) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: Colors.white.withValues(alpha: a),
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: const Color(0x0BFFFFFF)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(120, 13),
              const SizedBox(height: 10),
              bar(260, 10),
              const SizedBox(height: 7),
              bar(200, 10),
              const SizedBox(height: 12),
              bar(170, 17),
            ],
          ),
        ),
      );
    },
  );
}
