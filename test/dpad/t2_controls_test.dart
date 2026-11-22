// T2: Pressable and every shared control built on it. For each: a tap still works and leaves
// no focus behind; focus shows nothing while a pointer is in charge; in D-pad mode the ring
// appears in the control's own shape without moving anything, and OK presses it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/dpad/focus_chrome.dart';
import 'package:vyse_tv/dpad/focusable_wrapper.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/screens/home/continue_watching.dart';
import 'package:vyse_tv/widgets/hero_carousel.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_widgets.dart';
import 'package:vyse_tv/screens/manga/manga_widgets.dart';
import 'package:vyse_tv/widgets/media_rows.dart';
import 'package:vyse_tv/widgets/music_widgets.dart';
import 'package:vyse_tv/widgets/section_chrome.dart';

import 'harness.dart';

const _tick = Duration(milliseconds: 320);

Future<void> _show(WidgetTester t, Widget control) async {
  // from nothing each time, so no focus or state is carried over from the control before
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(Bed.app(Scaffold(body: Center(child: control))));
  // long enough for entrances to finish: a card still sliding in is not a card moved by focus
  await Bed.settle(t, rounds: 7);
}

FocusNode _node(WidgetTester t, Finder wrapper) => t.widget<Focus>(find.descendant(of: wrapper, matching: find.byType(Focus)).first).focusNode!;
Finder _chromeOf(Finder wrapper) => find.descendant(of: wrapper, matching: find.byType(FocusChrome)).first;
double _shown(WidgetTester t, Finder wrapper) => t.renderObject<RenderFocusChrome>(_chromeOf(wrapper)).shown;

Future<void> _dpad(WidgetTester t) async {
  InputModeTracker.reportNonPointerInput();
  await t.pump();
  await t.pump(_tick);
}

Future<void> _pointer(WidgetTester t) async {
  await t.tapAt(const Offset(3, 3));
  await t.pump();
  await t.pump(_tick);
}

/// The whole contract, for a control whose press can be counted.
Future<void> _checkStop(WidgetTester t, Widget control, {required int Function() presses, BorderRadius? shape, double scale = 1}) async {
  await _show(t, control);
  final wrapper = find.byType(FocusableWrapper).first;
  final node = _node(t, wrapper);
  final rect = t.getRect(wrapper);

  // a pointer: pressing works as it always did, and leaves no focus behind
  await t.tap(wrapper);
  await t.pump(_tick);
  expect(presses(), 1, reason: 'a tap presses it');
  expect(node.hasFocus, isFalse, reason: 'a tap must not leave focus on it');
  expect(_shown(t, wrapper), 0);

  // focused while the pointer is in charge: nothing shows, Enter does nothing
  node.requestFocus();
  await t.pump(_tick);
  expect(node.hasPrimaryFocus, isTrue);
  expect(_shown(t, wrapper), 0, reason: 'no ring while a pointer is in charge');
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await t.pump(_tick);
  expect(presses(), 1, reason: 'Enter must not press what is not shown as focused');

  // D-pad mode: the ring, in the control's own shape; nothing moved; OK presses
  await _dpad(t);
  expect(_shown(t, wrapper), 1, reason: 'the ring is up');
  expect(t.getRect(wrapper), rect, reason: 'focus must not move or resize anything');
  final chrome = t.widget<FocusChrome>(_chromeOf(wrapper));
  if (shape != null) expect(chrome.shape!.radius, shape, reason: 'the ring takes the control\'s own corners');
  expect(chrome.scale, scale);
  expect(DpadRoot.debugRinged, isNull, reason: 'one ring, not two');
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await t.pump(_tick);
  expect(presses(), 2, reason: 'OK presses it');

  // the pointer comes back: the ring goes
  await _pointer(t);
  expect(_shown(t, wrapper), 0);
}

/// For a control whose press opens a page: that it is a stop and wears the right ring.
Future<void> _checkLook(WidgetTester t, Finder wrapper, {BorderRadius? shape, double scale = 1}) async {
  final node = _node(t, wrapper);
  final rect = t.getRect(wrapper);
  node.requestFocus();
  await t.pump(_tick);
  expect(node.hasPrimaryFocus, isTrue, reason: 'it is a focus stop');
  expect(_shown(t, wrapper), 0);
  await _dpad(t);
  expect(_shown(t, wrapper), 1);
  expect(t.getRect(wrapper), rect);
  final chrome = t.widget<FocusChrome>(_chromeOf(wrapper));
  if (shape != null) expect(chrome.shape!.radius, shape);
  expect(chrome.scale, scale);
  await _pointer(t);
  expect(_shown(t, wrapper), 0);
}

BorderRadius _r(double r) => BorderRadius.circular(r);

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);
  final film = Bed.catalogue[3];

  group('Pressable', () {
    testWidgets('is a stop, shows its ring in D-pad mode only, OK presses it', (t) async {
      var n = 0;
      await _checkStop(
        t,
        Pressable(onTap: () => n++, builder: (_, _, _) => Container(width: 120, height: 48, decoration: BoxDecoration(color: Colors.white12, borderRadius: _r(9)))),
        presses: () => n,
        shape: _r(9),
      );
    }, variant: screen);

    testWidgets('tells its builder it is hovered while focused in D-pad mode, and pressed for a moment on OK', (t) async {
      final seen = <(bool, bool)>[];
      await _show(t, Pressable(onTap: () {}, builder: (_, hovered, pressed) {
        seen.add((hovered, pressed));
        return const SizedBox(width: 100, height: 40);
      }));
      final wrapper = find.byType(FocusableWrapper).first;
      _node(t, wrapper).requestFocus();
      await t.pump(_tick);
      expect(seen.last, (false, false), reason: 'pointer in charge: focus is not hover');
      await _dpad(t);
      expect(seen.last, (true, false), reason: 'what hover shows, focus shows');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(seen.last, (true, true), reason: 'the pressed look, as under a finger');
      await t.pump(_tick);
      expect(seen.last, (true, false));
      await _pointer(t);
      expect(seen.last, (false, false));
    }, variant: screen);

    testWidgets('with nothing to press, or told to be passed over, it is not a stop', (t) async {
      await _show(t, Column(mainAxisSize: MainAxisSize.min, children: [
        Pressable(builder: (_, _, _) => const SizedBox(width: 100, height: 40)),
        Pressable(onTap: () {}, focusable: false, builder: (_, _, _) => const SizedBox(width: 100, height: 40)),
        Pressable(onLongPress: () {}, builder: (_, _, _) => const SizedBox(width: 100, height: 40)),
      ]));
      final nodes = [for (final e in find.byType(FocusableWrapper).evaluate()) _node(t, find.byWidget(e.widget))];
      expect(nodes[0].canRequestFocus, isFalse, reason: 'disabled');
      expect(nodes[1].canRequestFocus, isFalse, reason: 'focusable: false');
      expect(nodes[2].canRequestFocus, isTrue, reason: 'hold-OK alone is something to do');
    }, variant: screen);

    testWidgets('holding OK, or the Menu key, does its long press', (t) async {
      var taps = 0, longs = 0;
      await _show(t, Pressable(onTap: () => taps++, onLongPress: () => longs++, builder: (_, _, _) => const SizedBox(width: 100, height: 40)));
      _node(t, find.byType(FocusableWrapper).first).requestFocus();
      await _dpad(t);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(_tick);
      expect((taps, longs), (1, 0));
      await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 600));
      await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await t.pump(_tick);
      expect((taps, longs), (1, 1));
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      expect((taps, longs), (1, 2));
    }, variant: screen);

    testWidgets('a control that scales itself takes its ring with it', (t) async {
      await _show(t, Pressable(
        onTap: () {},
        builder: (_, hovered, _) => Transform.scale(scale: hovered ? 1.1 : 1, child: Container(width: 100, height: 60, decoration: BoxDecoration(color: Colors.white12, borderRadius: _r(10)))),
      ));
      final wrapper = find.byType(FocusableWrapper).first;
      _node(t, wrapper).requestFocus();
      await _dpad(t);
      final moved = t.widget<FocusChrome>(_chromeOf(wrapper)).shape!.transform!;
      expect(MatrixUtils.transformRect(moved, const Rect.fromLTWH(0, 0, 100, 60)), rectMoreOrLessEquals(const Rect.fromLTWH(-5, -3, 110, 66), epsilon: .01));
    }, variant: screen);
  });

  group('shared buttons', () {
    testWidgets('PillButton, primary and plain', (t) async {
      var n = 0;
      await _checkStop(t, PillButton(label: 'Play', icon: Icons.play_arrow_rounded, primary: true, onTap: () => n++), presses: () => n, shape: _r(12));
      n = 0;
      await _checkStop(t, PillButton(label: 'Trailer', icon: Icons.movie_outlined, onTap: () => n++), presses: () => n, shape: _r(12));
    }, variant: screen);

    testWidgets('GlassIconButton', (t) async {
      var n = 0;
      await _checkStop(t, GlassIconButton(icon: Icons.add_rounded, label: 'Add', onTap: () => n++), presses: () => n, shape: _r(22));
    }, variant: screen);

    testWidgets('SquareIconButton', (t) async {
      var n = 0;
      await _checkStop(t, SquareIconButton(icon: Icons.info_outline_rounded, label: 'Details', onTap: () => n++), presses: () => n, shape: _r(17));
    }, variant: screen);

    testWidgets('BackLink', (t) async {
      var n = 0;
      await _checkStop(t, BackLink(onTap: () => n++), presses: () => n, shape: _r(8));
    }, variant: screen);

    testWidgets('FilterChipPill, selected or not', (t) async {
      var n = 0;
      await _checkStop(t, FilterChipPill(label: 'Popular', selected: false, onTap: () => n++), presses: () => n, shape: _r(20));
      n = 0;
      await _checkStop(t, FilterChipPill(label: 'Popular', selected: true, icon: Icons.local_fire_department_rounded, onTap: () => n++), presses: () => n, shape: _r(20));
    }, variant: screen);

    testWidgets('ToolButton; with nothing to do it is not a stop', (t) async {
      var n = 0;
      await _checkStop(t, ToolButton(icon: Icons.refresh_rounded, label: 'Refresh', onTap: () => n++), presses: () => n, shape: _r(20));
      await _show(t, const ToolButton(icon: Icons.refresh_rounded, label: 'Refresh', onTap: null));
      expect(_node(t, find.byType(FocusableWrapper).first).canRequestFocus, isFalse);
    }, variant: screen);

    testWidgets('TagPill; with nothing to do it is not a stop', (t) async {
      var n = 0;
      await _checkStop(t, TagPill('Drama', onTap: () => n++), presses: () => n, shape: _r(14));
      await _show(t, const TagPill('Drama'));
      expect(_node(t, find.byType(FocusableWrapper).first).canRequestFocus, isFalse);
    }, variant: screen);

    testWidgets('PlayBubble', (t) async {
      var n = 0;
      await _checkStop(t, PlayBubble(onTap: () => n++), presses: () => n, shape: _r(21));
    }, variant: screen);

    testWidgets('the search box\'s clear button is a stop only while there is text', (t) async {
      final text = TextEditingController();
      addTearDown(text.dispose);
      await _show(t, SizedBox(width: 500, child: VyseSearchField(controller: text, hint: 'Search')));
      final clear = find.byType(FocusableWrapper).first;
      expect(_node(t, clear).canRequestFocus, isFalse, reason: 'nothing to clear, and it is scaled to nothing');
      text.text = 'batman';
      await t.pump(_tick);
      expect(_node(t, clear).canRequestFocus, isTrue);
    }, variant: screen);
  });

  group('cards', () {
    testWidgets('OutlineCard grows a little and wears a card\'s corners', (t) async {
      var n = 0;
      await _checkStop(
        t,
        SizedBox(width: 150, height: 225, child: OutlineCard(label: 'A card', onTap: () => n++, builder: (_) => const ColoredBox(color: Colors.teal))),
        presses: () => n,
        shape: _r(7),
        scale: 1.03,
      );
    }, variant: screen);

    testWidgets('OutlineCard: holding OK does the card\'s long press', (t) async {
      var longs = 0;
      await _show(t, SizedBox(width: 150, height: 225, child: OutlineCard(label: 'A card', onTap: () {}, onLongPress: () => longs++, builder: (_) => const ColoredBox(color: Colors.teal))));
      _node(t, find.byType(FocusableWrapper).first).requestFocus();
      await _dpad(t);
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      expect(longs, 1);
    }, variant: screen);

    testWidgets('PosterCard, LandscapeCard, Top10Card', (t) async {
      for (final (card, size) in [
        (PosterCard(media: film, heroTag: 't2/${film.key}') as Widget, const Size(150, 225)),
        (LandscapeCard(media: film), const Size(300, 169)),
        (Top10Card(media: film, rank: 3), const Size(240, 135)),
      ]) {
        await _show(t, SizedBox.fromSize(size: size, child: card));
        await _checkLook(t, find.byType(FocusableWrapper).first, shape: _r(7), scale: 1.03);
      }
    }, variant: screen);

    testWidgets('PlatformTile, StudioTile and the genre tiles', (t) async {
      await _show(t, const SizedBox(width: 172, height: 118, child: PlatformTile(provider: WatchProvider(8, 'Netflix', '/l8.jpg'))));
      await _checkLook(t, find.byType(FocusableWrapper).first, shape: _r(10), scale: 1.03);
      await _show(t, const SizedBox(width: 200, height: 160, child: StudioTile(studio: Studio(70, 'Northlight Pictures', '/c70.png', isNetwork: false))));
      await _checkLook(t, find.byType(FocusableWrapper).first, shape: _r(12), scale: 1.03);
      await _show(t, const SizedBox(width: 1000, child: GenreGrid()));
      expect(find.byType(FocusableWrapper), findsNWidgets(8));
      await _checkLook(t, find.byType(FocusableWrapper).at(2), shape: _r(10), scale: 1.03);
    }, variant: screen);

    testWidgets('a row\'s paging arrows are passed over; its cards are stops', (t) async {
      await _show(t, SizedBox(
        width: 1000,
        child: Shelf<Media>(title: 'A row', load: () async => Bed.catalogue.take(12).toList(), itemWidth: 150, itemHeight: 225, itemBuilder: (_, m, _) => PosterCard(media: m, heroTag: 't2row/${m.key}')),
      ));
      final chevrons = find.descendant(of: find.byType(ShelfHeader), matching: find.byType(FocusableWrapper));
      expect(chevrons, findsNWidgets(2));
      for (final e in chevrons.evaluate()) {
        expect(_node(t, find.byWidget(e.widget)).canRequestFocus, isFalse, reason: 'a D-pad pages a row by moving along it');
      }
      final card = find.descendant(of: find.byType(PosterCard).first, matching: find.byType(FocusableWrapper));
      expect(_node(t, card).canRequestFocus, isTrue);
      // the mouse still pages the row
      final list = t.state<ScrollableState>(find.descendant(of: find.byType(Shelf<Media>), matching: find.byType(Scrollable)));
      await t.tap(chevrons.last);
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(list.position.pixels, greaterThan(0));
    }, variant: screen);

    testWidgets('Continue watching: the card is a stop, holding OK opens its menu (mark watched, remove), the ✓ and × are passed over', (t) async {
      final before = WatchProgress.entries.value;
      addTearDown(() => WatchProgress.entries.value = before);
      await _show(t, const SizedBox(width: 1100, child: ContinueWatchingRow()));
      final cards = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ResumeCard');
      final shown = cards.evaluate().length;
      expect(shown, greaterThan(1));
      final wrappers = find.descendant(of: cards.first, matching: find.byType(FocusableWrapper));
      expect(wrappers, findsNWidgets(3), reason: 'the card, its ✓ and its ×');
      expect(_node(t, wrappers.at(1)).canRequestFocus, isFalse, reason: "the ✓ is the mouse's; hold OK is the D-pad's");
      expect(_node(t, wrappers.at(2)).canRequestFocus, isFalse, reason: 'and so is the ×');
      await _checkLook(t, wrappers.first, shape: _r(12));

      _node(t, wrappers.first).requestFocus();
      await _dpad(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 600));
      await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await Bed.settle(t, rounds: 2);
      expect(find.text('Mark as watched'), findsOneWidget, reason: 'held OK opens the menu a long press opens');
      expect(WatchProgress.entries.value.where((e) => e.hidden), isEmpty, reason: 'nothing is removed by the hold itself');
      await Bed.down(t);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      // (the row is lazy: another card slides in, so the number on screen says nothing)
      final gone = WatchProgress.entries.value.where((e) => e.hidden).toList();
      expect(gone, hasLength(1), reason: 'Remove from Continue watching, chosen with the D-pad');
      expect(gone.single.media.key, before.firstWhere((e) => e.inContinue).media.key, reason: 'the focused card, not another');
      expect(find.text(gone.single.media.title), findsNothing);
    }, variant: screen);

    testWidgets('the hero: Play, My List and Details are stops; the slide dots are passed over', (t) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await _show(t, SizedBox(
        height: 600,
        child: HeroCarousel(items: Bed.catalogue.take(5).toList(), scroll: scroll, immersive: false, height: 600),
      ));
      final wrappers = find.byType(FocusableWrapper);
      final stops = [for (final e in wrappers.evaluate()) _node(t, find.byWidget(e.widget)).canRequestFocus];
      expect(stops, [true, true, true, false, false, false, false, false], reason: 'three buttons, then five dots');
      await _checkLook(t, wrappers.at(0), shape: _r(21));
      await _checkLook(t, wrappers.at(1), shape: _r(17));
    }, variant: screen);
  });

  group('Material controls (not the app\'s own)', () {
    testWidgets('get the same ring, drawn for them, in D-pad mode only', (t) async {
      var presses = 0;
      var on = false;
      final nodes = List.generate(4, (i) => FocusNode(debugLabel: 'material $i'));
      addTearDown(() {
        for (final n in nodes) {
          n.dispose();
        }
      });
      await _show(t, StatefulBuilder(
        builder: (context, setState) => Column(mainAxisSize: MainAxisSize.min, children: [
          TextButton(focusNode: nodes[0], onPressed: () => presses++, child: const Text('Try again')),
          IconButton(focusNode: nodes[1], onPressed: () => presses++, icon: const Icon(Icons.replay_30_rounded)),
          Switch(focusNode: nodes[2], value: on, onChanged: (v) => setState(() => on = v)),
          SizedBox(width: 300, child: Slider(focusNode: nodes[3], value: .4, onChanged: (_) {})),
          Pressable(onTap: () {}, builder: (_, _, _) => const SizedBox(width: 100, height: 40)),
        ]),
      ));
      for (final node in nodes) {
        node.requestFocus();
        await t.pump(_tick);
        expect(DpadRoot.debugRinged, isNull, reason: '${node.debugLabel}: no ring while a pointer is in charge');
        await _dpad(t);
        expect(DpadRoot.debugRinged, node, reason: '${node.debugLabel}: ringed in D-pad mode');
        await _pointer(t);
        expect(DpadRoot.debugRinged, isNull);
      }
      // OK presses a Material button as it always has
      nodes[0].requestFocus();
      await _dpad(t);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(_tick);
      expect(presses, 1);
      nodes[2].requestFocus();
      await t.pump(_tick);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(_tick);
      expect(on, isTrue, reason: 'OK flips a switch');
      // focus moving to one of the app's own controls takes this ring away at once
      _node(t, find.byType(FocusableWrapper).first).requestFocus();
      await t.pump();
      expect(DpadRoot.debugRinged, isNull, reason: 'one ring, not two');
    }, variant: screen);

    testWidgets('a text box and a page-wide key handler are not ringed', (t) async {
      final field = FocusNode(), page = FocusNode();
      addTearDown(field.dispose);
      addTearDown(page.dispose);
      await _show(t, Focus(
        focusNode: page,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 300, child: TextField(focusNode: field)),
          TextButton(onPressed: () {}, child: const Text('Go')),
        ]),
      ));
      await _dpad(t);
      field.requestFocus();
      await t.pump(_tick);
      expect(DpadRoot.debugRinged, isNull, reason: 'a text box shows its own caret and border');
      page.requestFocus();
      await t.pump(_tick);
      expect(DpadRoot.debugRinged, isNull, reason: 'a handler around a whole page is not a control');
    }, variant: screen);
  });
}
