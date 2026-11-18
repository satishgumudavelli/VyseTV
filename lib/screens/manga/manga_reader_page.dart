import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/manga/manga_library.dart';
import '../../models/manga/manga.dart';
import '../../models/manga/manga_chapter.dart';
import '../../dpad/dpad_navigator.dart' show DpadKeyExtension;
import '../../dpad/dpad_picture.dart';
import '../../dpad/dpad_traversal.dart';
import '../../core/platform/platform_detector.dart' show PlatformDetector;
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import '../shell/shell.dart' show WindowBar;

enum ReaderMode { scroll, paged }

/// How a page sits on the screen. OK (Enter), or the bar's button, goes on to the next one.
enum ReaderFit {
  page('Fit page', Icons.fit_screen_rounded),
  width('Fit width', Icons.width_full_rounded),
  stretch('Stretch', Icons.aspect_ratio_rounded);

  const ReaderFit(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Opens the reader full screen, over the rail.
Future<void> openReader(
  BuildContext context, {
  required Manga manga,
  required List<MangaChapter> chapters,
  required int index,
  int startPage = 0,
}) =>
    Navigator.of(context, rootNavigator: true).push(ShellRoute(
      child: MangaReaderPage(manga: manga, chapters: chapters, index: index, startPage: startPage),
    ));

/// Continue reading: straight into the saved chapter, at the saved page.
Future<void> resumeReading(BuildContext context, MangaProgress p) async {
  showToast(context, Text('Opening ${p.chapterLabel ?? 'Chapter ${p.chapterIndex + 1}'}…'), icon: Icons.auto_stories_rounded);
  try {
    final order = readingOrder(await mangaService.getChapters(p.manga.id));
    if (!context.mounted || order.isEmpty) return;
    await openReader(context, manga: p.manga, chapters: order, index: p.chapterIndex.clamp(0, order.length - 1), startPage: p.page);
  } catch (_) {
    if (context.mounted) showToast(context, const Text("Couldn't load this series"), icon: Icons.error_outline_rounded);
  }
}

/// Full-screen reader with two modes: one long vertical strip, or one page at a time that you
/// flip. Tap to show / hide the bar (in page mode the left and right thirds flip).
/// Keys: ← → the page before / after (past the last page, the next chapter), Space next,
/// Enter changes the fit, M switches mode, Esc closes.
///
/// Only the pages near the screen are fetched and kept, each decoded at the size it is shown.
/// (It used to lay out every page of a chapter at once, at full size: on a TV box that ran
/// out of memory within a minute.)
class MangaReaderPage extends StatefulWidget {
  const MangaReaderPage({super.key, required this.manga, required this.chapters, required this.index, this.startPage = 0});
  final Manga manga;

  /// In reading order, oldest first.
  final List<MangaChapter> chapters;
  final int index;
  final int startPage;

  /// Tests hand the reader a chapter's pages (their bed has no manga source).
  @visibleForTesting
  static Future<List<String>> Function(MangaChapter chapter)? debugPages;

  @override
  State<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends State<MangaReaderPage> {
  static const _modeKey = 'manga.readerMode';
  static String _fitKey(ReaderMode m) => 'manga.readerFit.${m.name}';
  static ReaderMode _lastMode = ReaderMode.scroll;
  static ReaderFit? _lastScrollFit;
  static ReaderFit? _lastPagedFit;

  /// What OK goes round, in each mode. (A strip can't be stretched: its pages share a width.)
  static const _fits = {
    ReaderMode.paged: [ReaderFit.page, ReaderFit.width, ReaderFit.stretch],
    ReaderMode.scroll: [ReaderFit.width, ReaderFit.page],
  };

  /// The hint about OK is shown once a run, the first time the reader opens with a D-pad.
  static bool _hinted = false;

  final _scroll = ScrollController();

  // D-pad. The reader has the players' two states (see DpadPicture). Reading: focus rests on
  // the page and the keys read: Left and Right go a page back and on, Up and Down scroll (in
  // page mode, down a page that is wider than the screen is tall). OK changes the fit. Holding
  // OK, the Menu key, or Up at the very top brings the bar up and puts focus on its buttons;
  // Back there hides the bar and returns to the page; Back again leaves.
  late final _picture = DpadPicture(
    debugLabel: 'reader',
    ownsKey: (key) =>
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        ((_mode == ReaderMode.scroll || _fitPaged == ReaderFit.width) && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)),
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  void _enterControls() {
    if (!_chrome) setState(() => _chrome = true);
    _picture.toControls(shown: () => mounted && _chrome);
  }

  void _backKey() {
    if (_chrome && _picture.backToPicture()) {
      setState(() => _chrome = false);
      return;
    }
    _close();
  }

  PageController? _pager;

  /// Page mode, Fit width: each page scrolls down on its own.
  final _pageScrolls = <int, ScrollController>{};
  ScrollController _pageScroll(int i) => _pageScrolls.putIfAbsent(i, ScrollController.new);

  late ReaderMode _mode = _lastMode;
  late ReaderFit _fitScroll = _lastScrollFit ?? (PlatformDetector.isTV() ? ReaderFit.page : ReaderFit.width);
  late ReaderFit _fitPaged = _lastPagedFit ?? ReaderFit.page;
  ReaderFit get _fit => _mode == ReaderMode.paged ? _fitPaged : _fitScroll;
  late int _index = widget.index;
  late int _start = widget.startPage;
  late Future<List<String>> _pages = _load();
  int _count = 0;
  int _page = 0;
  bool _chrome = true;
  double _scrollFraction = 0;

  /// The colour under the progress line at the foot of the screen.
  static const _track = Color(0x8C000000);
  Timer? _saveTimer;

  // ───────── scroll mode's strip ─────────
  //
  // Every page has a height before its picture comes (its width times [_guessRatio]); once the
  // picture is in, its own. In Fit page each page is as wide as lets all of it fit the screen's
  // height, so pages of other shapes get other widths. So the strip can open on any page, and only the pages near the
  // screen are built and fetched. When a page above the one being read changes height, the
  // strip moves by as much, so the page being read stays put.

  static const _guessRatio = 1.45; // a manga page's height to its width
  static const _endH = 260.0; // the card after the last page
  final _ratio = <int, double>{}; // pages whose picture is in: height to width
  final _broken = <int>{};
  double _stripW = 0; // the strip at its widest (set by build)
  double _viewH = 0;
  double _padTop = 0;

  /// Whether the strip is where it opens (the saved page). Until it is, its pictures wait: the
  /// pages it lays out first are not fetched for nothing.
  bool _placed = false;

  double _w(int i) => _fitScroll == ReaderFit.page ? math.min(_stripW, _viewH / (_ratio[i] ?? _guessRatio)) : _stripW;
  double _h(int i) => i >= _count ? _endH : _w(i) * (_broken.contains(i) ? .6 : (_ratio[i] ?? _guessRatio));

  double _startOf(int i) {
    var y = _padTop;
    for (var j = 0; j < i && j < _count; j++) {
      y += _h(j);
    }
    return y;
  }

  /// The page at the reading line, a third of the way down the screen.
  int _pageAt(double pixels, double viewport) {
    final line = pixels + viewport * .35;
    var y = _padTop;
    for (var i = 0; i < _count; i++) {
      y += _h(i);
      if (y > line) return i;
    }
    return math.max(0, _count - 1);
  }

  /// Where the strip stands to show page [i] from its top ([_count]: the end card): under the
  /// bar while it shows, at the top of the screen when it doesn't.
  double _offsetFor(int i) => i <= 0 ? 0 : math.max(0.0, _startOf(i) - (_chrome ? _padTop : 0));

  // ───────── keys ─────────

  /// The key being handled is a held key's repeat: it reads on, but never changes chapter or
  /// opens the bar (a held Right used to run through chapter after chapter).
  bool _repeat = false;

  /// A held key moves in steps, not glides: each repeat would start a glide over from where
  /// the last had got to, and the page barely moved. Pages go by about six a second.
  DateTime _lastHeldStep = DateTime.fromMillisecondsSinceEpoch(0);
  bool _heldStepDue() {
    final now = clock.now();
    if (now.difference(_lastHeldStep) < const Duration(milliseconds: 160)) return false;
    _lastHeldStep = now;
    return true;
  }

  /// OK: a short press changes the fit, a long one brings the bar up.
  bool _okDown = false;
  bool _okHeld = false;
  Timer? _okHold;

  KeyEventResult _earlyKey(KeyEvent e) {
    if (!mounted) return KeyEventResult.ignored;
    _repeat = e is KeyRepeatEvent;
    final ok = e.logicalKey.isSelectKey;
    if (ok && _okDown) {
      // the rest of a press that began on the page stays the page's, wherever focus went
      if (e is KeyUpEvent) {
        _okDown = false;
        _okHold?.cancel();
        if (!_okHeld) _cycleFit();
      }
      return KeyEventResult.handled;
    }
    if (!ok || e is! KeyDownEvent || !_picture.onPicture || !(ModalRoute.of(context)?.isCurrent ?? false)) return KeyEventResult.ignored;
    _okDown = true;
    _okHeld = false;
    _okHold?.cancel();
    _okHold = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || !_okDown) return;
      _okHeld = true;
      _enterControls();
    });
    return KeyEventResult.handled;
  }

  /// Arrows that scroll (on a TV): down tucks the bar away, as a finger does, and up brings it
  /// back.
  void _barForKeys(bool show) {
    if (DpadPicture.dpad && show != _chrome) setState(() => _chrome = show);
  }

  @override
  void initState() {
    super.initState();
    _picture.attach();
    FocusManager.instance.addEarlyKeyEventHandler(_earlyKey);
    _restoreMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hinted || !DpadPicture.dpad) return;
      _hinted = true;
      showToast(context, const Text('OK changes the fit. Hold OK for the menu.'), icon: Icons.settings_remote_rounded);
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_earlyKey);
    _okHold?.cancel();
    _saveTimer?.cancel();
    _save();
    _scroll.dispose();
    _pager?.dispose();
    for (final c in _pageScrolls.values) {
      c.dispose();
    }
    _picture.dispose();
    super.dispose();
  }

  Future<void> _restoreMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = ReaderMode.values.asNameMap()[prefs.getString(_modeKey)];
      final fits = ReaderFit.values.asNameMap();
      final scroll = fits[prefs.getString(_fitKey(ReaderMode.scroll))];
      final paged = fits[prefs.getString(_fitKey(ReaderMode.paged))];
      if (!mounted) return;
      if (saved != null && saved != _mode) _switchMode(saved, persist: false);
      if (scroll != null && _fits[ReaderMode.scroll]!.contains(scroll)) _setFit(ReaderMode.scroll, scroll, persist: false);
      if (paged != null && _fits[ReaderMode.paged]!.contains(paged)) _setFit(ReaderMode.paged, paged, persist: false);
    } catch (_) {}
  }

  Future<List<String>> _load() async {
    _ratio.clear();
    _broken.clear();
    _placed = false;
    final pages = await (MangaReaderPage.debugPages?.call(_chapter) ?? mangaService.getChapterImages(_chapter.id));
    _count = pages.length;
    _page = _start.clamp(0, math.max(0, pages.length - 1));
    _pager?.dispose();
    _pager = PageController(initialPage: _page);
    _save();
    return pages;
  }

  MangaChapter get _chapter => widget.chapters[_index];
  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.chapters.length - 1;

  // ───────── progress ─────────

  void _save() => MangaHistory.save(widget.manga, _index, _page, widget.chapters).catchError((Object _) {});

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), _save);
  }

  void _setPage(int p) {
    if (p == _page) return;
    setState(() => _page = p);
    _saveSoon();
  }

  // ───────── navigation ─────────

  void _go(int index) {
    if (index < 0 || index >= widget.chapters.length) return;
    _saveTimer?.cancel();
    _save();
    final old = Map.of(_pageScrolls);
    _pageScrolls.clear();
    setState(() {
      _index = index;
      _start = 0;
      _page = 0;
      _count = 0;
      _scrollFraction = 0;
      _chrome = true;
      _pages = _load();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // (once the old chapter's pages are gone)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old.values) {
        c.dispose();
      }
    });
  }

  void _switchMode(ReaderMode m, {bool persist = true}) {
    if (m == _mode) return;
    _lastMode = m;
    setState(() {
      _mode = m;
      if (m == ReaderMode.paged) {
        _pager?.dispose();
        _pager = PageController(initialPage: _page);
      } else {
        _placed = false; // the strip opens on the page that was showing
      }
    });
    if (persist) {
      SharedPreferences.getInstance().then((p) => p.setString(_modeKey, m.name)).catchError((Object _) => false);
      showToast(context, Text(m == ReaderMode.paged ? 'Page mode' : 'Scroll mode'),
          icon: m == ReaderMode.paged ? Icons.auto_stories_rounded : Icons.view_day_rounded);
    }
  }

  /// OK (Enter), or the bar's button: the next fit for this mode.
  void _cycleFit() {
    final list = _fits[_mode]!;
    _setFit(_mode, list[(list.indexOf(_fit) + 1) % list.length]);
  }

  void _setFit(ReaderMode mode, ReaderFit f, {bool persist = true}) {
    final was = mode == ReaderMode.paged ? _fitPaged : _fitScroll;
    if (was == f) return;
    // the strip keeps the page being read, and how far down it you were
    (int, double)? anchor;
    if (mode == ReaderMode.scroll && _mode == ReaderMode.scroll && _placed && _scroll.hasClients && _count > 0) {
      final p = _scroll.position;
      final cur = _pageAt(p.pixels, p.viewportDimension);
      anchor = (cur, ((p.pixels - _startOf(cur)) / _h(cur)).clamp(0.0, 1.0));
    }
    setState(() {
      if (mode == ReaderMode.paged) {
        _fitPaged = _lastPagedFit = f;
      } else {
        _fitScroll = _lastScrollFit = f;
      }
    });
    if (anchor != null) {
      final (cur, into) = anchor;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final p = _scroll.position;
        p.jumpTo((cur == 0 && into == 0 ? 0.0 : _startOf(cur) + into * _h(cur)).clamp(0.0, p.maxScrollExtent));
      });
    }
    if (persist) {
      SharedPreferences.getInstance().then((p) => p.setString(_fitKey(mode), f.name)).catchError((Object _) => false);
      showToast(context, Text(f.label), icon: f.icon);
    }
  }

  /// [key]: from a key, not a tap (a held key's repeats turn pages but never the chapter).
  void _flip(int dir, {bool key = false}) {
    final pager = _pager;
    if (pager == null || !pager.hasClients) return;
    final held = key && _repeat;
    if (held && !_heldStepDue()) return;
    final target = (pager.page?.round() ?? _page) + dir;
    if (target < 0) {
      if (_hasPrev && !held) _go(_index - 1);
      return;
    }
    if (target > _count) {
      if (_hasNext && !held) _go(_index + 1);
      return;
    }
    if (held) {
      pager.jumpToPage(target);
    } else {
      pager.animateToPage(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  /// Scrolls by [f] screens: glides, or for a held key's repeat steps (a smaller step, about
  /// three screens a second).
  void _scrollBy(double f) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (_repeat) {
      _scroll.jumpTo((p.pixels + p.viewportDimension * f.sign * .15).clamp(0.0, p.maxScrollExtent));
      return;
    }
    _scroll.animateTo((p.pixels + p.viewportDimension * f).clamp(0.0, p.maxScrollExtent),
        duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  void _glide(double to) {
    if (!_scroll.hasClients) return;
    final at = to.clamp(0.0, _scroll.position.maxScrollExtent);
    if (_repeat) {
      _scroll.jumpTo(at);
    } else {
      _scroll.animateTo(at, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  /// Scroll mode, Left and Right: on to the next page's top; back to the top of this one, then
  /// to the one before. Right on the end card is the next chapter; Left at the top of the first
  /// page the chapter before. (Turning pages tucks the bar away, either way.)
  void _stepPage(int dir) {
    if (!_scroll.hasClients || _count == 0) return;
    if (_repeat && !_heldStepDue()) return;
    final p = _scroll.position;
    final cur = _pageAt(p.pixels, p.viewportDimension);
    _barForKeys(false);
    if (dir > 0) {
      if (p.pixels >= p.maxScrollExtent - 2) {
        if (_hasNext && !_repeat) _go(_index + 1);
        return;
      }
      _glide(_offsetFor(cur + 1)); // (cur + 1 == _count: the end card)
      return;
    }
    final here = _offsetFor(cur);
    if (p.pixels > here + 4) return _glide(here);
    if (cur == 0) {
      if (_hasPrev && !_repeat) _go(_index - 1);
      return;
    }
    _glide(_offsetFor(cur - 1));
  }

  /// Scroll mode, Up and Down. Up at the very top brings the bar up.
  void _scrollKey(int dir) {
    if (!_scroll.hasClients) return;
    if (dir < 0 && _scroll.position.pixels <= 0) {
      if (!_repeat) _enterControls();
      return;
    }
    _barForKeys(dir < 0);
    _scrollBy(dir * .35);
  }

  /// Page mode, Up and Down. In Fit width they go down the page (Down at its foot turns it);
  /// otherwise, and Up at the top, they bring the bar up.
  void _pagedKey(int dir) {
    if (_fitPaged == ReaderFit.width) {
      final c = _pageScrolls[_pager?.page?.round() ?? _page];
      if (c != null && c.hasClients) {
        final p = c.position;
        if (dir > 0 ? p.pixels < p.maxScrollExtent - 1 : p.pixels > 1) {
          if (_repeat) {
            c.jumpTo((p.pixels + dir * p.viewportDimension * .15).clamp(0.0, p.maxScrollExtent));
          } else {
            c.animateTo((p.pixels + dir * p.viewportDimension * .35).clamp(0.0, p.maxScrollExtent),
                duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
          }
          return;
        }
        if (dir > 0) {
          if (!_repeat) _flip(1, key: true);
          return;
        }
      }
    }
    if (!_repeat) _enterControls();
  }

  void _close() => Navigator.of(context).maybePop();

  // ───────── scroll mode ─────────

  /// Puts the strip on the page it opens on, once it is laid out, and lets its pictures come.
  void _place() {
    if (_placed || !mounted || _mode != ReaderMode.scroll) return;
    if (_scroll.hasClients) {
      final p = _scroll.position;
      p.jumpTo(_offsetFor(_page).clamp(0.0, p.maxScrollExtent));
    }
    setState(() => _placed = true);
  }

  /// A page's picture came ([size]) or failed (null).
  void _pageIn(int i, Size? size) {
    if (!mounted || i >= _count) return;
    final before = _h(i);
    if (size == null) {
      if (!_broken.add(i)) return;
    } else {
      if (size.width <= 0 || size.height <= 0) return;
      final r = size.height / size.width;
      final had = _ratio[i];
      if (had != null && (had - r).abs() < .0005 && !_broken.contains(i)) return;
      _ratio[i] = r;
      _broken.remove(i);
    }
    final delta = _h(i) - before;
    setState(() {});
    // a page above the one being read changed height: move with it
    if (delta != 0 && _mode == ReaderMode.scroll && _scroll.hasClients && i < _page) {
      final p = _scroll.position;
      p.jumpTo(math.max(0.0, p.pixels + delta));
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      final m = n.metrics;
      final f = m.maxScrollExtent <= 0 ? 0.0 : (m.pixels / m.maxScrollExtent).clamp(0.0, 1.0);
      if ((f - _scrollFraction).abs() > .002) setState(() => _scrollFraction = f);
      if (_placed) _setPage(_pageAt(m.pixels, m.viewportDimension));
      // Scrolling down tucks the bar away; scrolling up brings it back.
      if (n is ScrollUpdateNotification && n.dragDetails != null) {
        final down = (n.scrollDelta ?? 0) > 0;
        if (down && _chrome && m.pixels > 80) {
          setState(() => _chrome = false);
          _picture.toPicture(); // the bar's buttons are gone: focus is the page's again
        }
        if (!down && !_chrome) setState(() => _chrome = true);
      }
    }
    return false;
  }

  // ───────── build ─────────

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final size = MediaQuery.sizeOf(context);
    final widthFit = phone ? size.width : size.width.clamp(0.0, 900.0);
    final top = Layout.windowChrome(context);
    _stripW = widthFit;
    _viewH = size.height;
    _padTop = top + 64;
    final paged = _mode == ReaderMode.paged;
    final progress = paged ? (_count == 0 ? 0.0 : (_page + 1) / _count) : _scrollFraction;

    return CallbackShortcuts(
      bindings: {
        // Back: Escape, a remote's Back, a controller's B. Held, it is still one Back.
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.browserBack, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.keyM): () => _switchMode(paged ? ReaderMode.scroll : ReaderMode.paged),
        const SingleActivator(LogicalKeyboardKey.space): () => paged ? _flip(1) : _scrollBy(.85),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => paged ? _flip(1) : _scrollBy(.85),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => paged ? _flip(-1) : _scrollBy(-.85),
        // With focus on the page the arrows read (and OK changes the fit: see _earlyKey). With
        // focus on the bar's buttons they move between the buttons.
        if (_picture.onPicture) ...{
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => paged ? _flip(1, key: true) : _stepPage(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => paged ? _flip(-1, key: true) : _stepPage(-1),
          // a remote has no Space or Page Down: Up and Down scroll
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => paged ? _pagedKey(1) : _scrollKey(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => paged ? _pagedKey(-1) : _scrollKey(-1),
          const SingleActivator(LogicalKeyboardKey.contextMenu, includeRepeats: false): _enterControls,
          const SingleActivator(LogicalKeyboardKey.gameButtonX, includeRepeats: false): _enterControls,
        },
      },
      child: Focus(
        focusNode: _picture.node,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            FutureBuilder<List<String>>(
              future: _pages,
              builder: (context, snap) {
                if (snap.hasError) {
                  return EmptyState(
                    icon: Icons.broken_image_outlined,
                    title: "Couldn't load this chapter",
                    body: 'Check your connection and try again.',
                    action: ('Retry', () => setState(() {
                          _pages = _load();
                        })),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                    child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.4, color: VyseColors.accent)),
                  );
                }
                final pages = snap.data!;
                return paged ? _pagedView(pages, top) : _scrollView(pages, top);
              },
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              top: _chrome ? 0 : -(top + 80),
              left: 0,
              right: 0,
              // slid out of view, its buttons are shut to focus too
              child: ExcludeFocus(excluding: !_chrome, child: _bar(top)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // On a dark track the width of the screen: in page mode the line lies on the black
              // under the page, but a strip's pages reach the foot of the screen, and over a page
              // it hardly showed (a tester read in scroll mode and saw it only in page mode). The
              // dark part is what is left to read.
              child: Container(
                height: 3,
                color: _track,
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 3,
                  width: size.width * progress,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [VyseColors.accentHot, VyseColors.accent]),
                    boxShadow: [BoxShadow(color: Color(0x99FF8A1A), blurRadius: 8)],
                  ),
                ),
              ),
            ),
            if (isDesktopNative) Positioned(top: 0, left: 0, right: 0, child: DpadRegion(node: _picture.windowBar, child: const WindowBar())),
          ]),
        ),
      ),
    );
  }

  /// A page's picture, decoded no larger than [width] × [height] device pixels (it keeps its
  /// shape, and a smaller picture stays its own size).
  static ImageProvider _sized(String url, {required double width, double? height}) => ResizeImage(
        CachedNetworkImageProvider(url),
        width: math.max(1, width.round()),
        height: height == null ? null : math.max(1, height.round()),
        policy: ResizeImagePolicy.fit,
      );

  Widget _scrollView(List<String> pages, double top) => GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Builder(builder: (context) {
            if (!_placed) SchedulerBinding.instance.addPostFrameCallback((_) => _place());
            final dpr = MediaQuery.devicePixelRatioOf(context);
            return ListView.builder(
              key: ValueKey('scroll/$_index'),
              controller: _scroll,
              padding: EdgeInsets.only(top: _padTop, bottom: 40),
              // the next screenful is fetched before it is reached
              scrollCacheExtent: const ScrollCacheExtent.viewport(1),
              itemCount: pages.length + 1,
              itemExtentBuilder: (i, _) => i <= pages.length ? _h(i) : null,
              itemBuilder: (context, i) => i == pages.length
                  ? Center(child: SizedBox(width: math.min(math.max(_w(0), 320), 520), child: _endCard()))
                  : Center(
                      child: SizedBox(
                        width: _w(i),
                        child: _StripPage(
                          key: ValueKey('strip/$_index/$i'),
                          url: pages[i],
                          // (the same width for every page, so none is decoded twice: in Fit page
                          // as wide as a page a little wider than usual would be)
                          decodeWidth: math.max(1, ((_fitScroll == ReaderFit.page ? math.min(_stripW, _viewH / 1.2) : _stripW) * dpr).round()),
                          number: i + 1,
                          load: _placed,
                          onSize: (s) => _pageIn(i, s),
                        ),
                      ),
                    ),
            );
          }),
        ),
      );

  ImageProvider _pagedImage(String url, Size box) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return switch (_fitPaged) {
      ReaderFit.width => _sized(url, width: box.width * dpr),
      // (with room to zoom in twice before it softens)
      ReaderFit.page => _sized(url, width: box.width * dpr * 2, height: box.height * dpr * 2),
      ReaderFit.stretch => _sized(url, width: box.width * dpr, height: box.height * dpr),
    };
  }

  Widget _pagedPage(String url, int i, BoxConstraints c, double top) {
    final box = Size(c.maxWidth, math.max(1, c.maxHeight - top - 16));
    final placeholder = SizedBox(
      width: box.width,
      height: box.height,
      child: Center(
        child: Text('${i + 1}', style: const TextStyle(color: VyseColors.textFaint, fontSize: 28, fontWeight: FontWeight.w800)),
      ),
    );
    Widget picture(BoxFit fit, {double? width, double? height}) => Image(
          image: _pagedImage(url, box),
          fit: fit,
          width: width,
          height: height,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, sync) => frame == null && !sync ? placeholder : child,
          errorBuilder: (_, _, _) => SizedBox(
            width: box.width,
            height: box.height,
            child: const Center(child: Icon(Icons.broken_image_outlined, color: VyseColors.textFaint, size: 32)),
          ),
        );
    if (_fitPaged == ReaderFit.width) {
      return SingleChildScrollView(
        controller: _pageScroll(i),
        padding: EdgeInsets.only(top: top + 8, bottom: 8),
        child: picture(BoxFit.fitWidth, width: box.width),
      );
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Padding(
        padding: EdgeInsets.only(top: top + 8, bottom: 8),
        child: picture(_fitPaged == ReaderFit.stretch ? BoxFit.fill : BoxFit.contain, width: box.width, height: box.height),
      ),
    );
  }

  Widget _pagedView(List<String> pages, double top) => LayoutBuilder(
        builder: (context, c) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final x = d.localPosition.dx / c.maxWidth;
            if (x < .3) {
              _flip(-1);
            } else if (x > .7) {
              _flip(1);
            } else {
              setState(() => _chrome = !_chrome);
            }
          },
          child: PageView.builder(
            key: ValueKey('paged/$_index'),
            controller: _pager,
            itemCount: pages.length + 1,
            onPageChanged: (i) {
              _setPage(math.min(i, _count - 1));
              // Warm the next couple of pages so flipping never waits.
              final box = Size(c.maxWidth, math.max(1, c.maxHeight - top - 16));
              for (final j in [i + 1, i + 2]) {
                if (j < pages.length) precacheImage(_pagedImage(pages[j], box), context).catchError((Object _) {});
              }
            },
            itemBuilder: (context, i) => i == pages.length
                ? Center(child: SizedBox(width: math.min(c.maxWidth, 520), child: _endCard()))
                : _pagedPage(pages[i], i, c, top),
          ),
        ),
      );

  Widget _bar(double top) {
    final paged = _mode == ReaderMode.paged;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, top + 8, 12, 0),
      child: Glass(
        radius: 16,
        opacity: .7,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: DpadRail(onEdge: _picture.toWindowBar, child: Row(children: [
          GlassIconButton(icon: Icons.arrow_back_rounded, label: 'Back (Esc)', size: 38, onTap: _close),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(widget.manga.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              Text(
                [_chapter.label, ?_chapter.subtitle, if (_count > 0) '${_page + 1} / $_count'].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim),
              ),
            ]),
          ),
          GlassIconButton(icon: _fit.icon, label: '${_fit.label} (Enter changes it)', size: 38, onTap: _cycleFit),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: paged ? Icons.view_day_rounded : Icons.auto_stories_rounded,
            label: paged ? 'Switch to scroll mode (M)' : 'Switch to page mode (M)',
            size: 38,
            onTap: () => _switchMode(paged ? ReaderMode.scroll : ReaderMode.paged),
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: Icons.skip_previous_rounded,
            label: 'Previous chapter',
            size: 38,
            onTap: _hasPrev ? () => _go(_index - 1) : () {},
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: Icons.skip_next_rounded,
            label: 'Next chapter',
            size: 38,
            onTap: _hasNext ? () => _go(_index + 1) : () {},
          ),
        ])),
      ),
    );
  }

  Widget _endCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('End of ${_chapter.label}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          if (_hasNext)
            PillButton(
              primary: true,
              icon: Icons.skip_next_rounded,
              label: 'Next: ${widget.chapters[_index + 1].label}',
              onTap: () => _go(_index + 1),
            )
          else ...[
            const Text("You're all caught up.", style: TextStyle(color: VyseColors.textDim)),
            const SizedBox(height: 16),
            PillButton(icon: Icons.arrow_back_rounded, label: 'Back to series', onTap: _close),
          ],
        ]),
      );
}

/// One page of the strip. It fetches its picture only once [load] is true (the strip is in
/// place), decoded [decodeWidth] pixels wide at most, says how big the picture is once it has
/// come (the strip then gives the page that height), and fills whatever height it is given.
class _StripPage extends StatefulWidget {
  const _StripPage({super.key, required this.url, required this.decodeWidth, required this.number, required this.load, required this.onSize});
  final String url;
  final int decodeWidth;
  final int number;
  final bool load;

  /// The picture's size in pixels once it has come; null when it could not be had.
  final ValueChanged<Size?> onSize;

  @override
  State<_StripPage> createState() => _StripPageState();
}

class _StripPageState extends State<_StripPage> {
  ImageStream? _stream;
  ImageInfo? _info;
  bool _failed = false;
  late final _listener = ImageStreamListener(_got, onError: _error);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_StripPage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.decodeWidth != widget.decodeWidth || old.load != widget.load) _resolve();
  }

  void _resolve() {
    if (!widget.load) return;
    final image = _MangaReaderPageState._sized(widget.url, width: widget.decodeWidth.toDouble());
    final stream = image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  /// (the strip is told after this frame: a picture already in memory comes while it is being built)
  void _tell(Size? size) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSize(size);
      });
    } else {
      widget.onSize(size);
    }
  }

  void _got(ImageInfo info, bool sync) {
    if (!mounted) {
      info.dispose();
      return;
    }
    final old = _info;
    setState(() {
      _info = info;
      _failed = false;
    });
    // (the old picture goes once the new one has been drawn)
    if (old != null) SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
    _tell(Size(info.image.width.toDouble(), info.image.height.toDouble()));
  }

  void _error(Object error, StackTrace? stack) {
    if (!mounted || _info != null) return;
    setState(() => _failed = true);
    _tell(null);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info != null) {
      // as wide as the strip, from the top (for the one frame before the strip has the
      // picture's own height, it is cut short or has room under it, never squashed)
      return ClipRect(
        child: RawImage(image: info.image, scale: info.scale, width: double.infinity, fit: BoxFit.fitWidth, alignment: Alignment.topCenter),
      );
    }
    if (_failed) return const Center(child: Icon(Icons.broken_image_outlined, color: VyseColors.textFaint, size: 32));
    return Center(
      child: Text('${widget.number}', style: const TextStyle(color: VyseColors.textFaint, fontSize: 28, fontWeight: FontWeight.w800)),
    );
  }
}
