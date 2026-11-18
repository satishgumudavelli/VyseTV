// T3 as one crawl of the whole app (phase 10). The walks of the earlier phases each open pages
// somebody listed; this one lists nothing. On every section it walks the page (R1 to R4), then
// presses OK on one control of every kind the walk found. Whatever that opens (a page, a box,
// a sheet, a menu) is walked as well, the first time that kind of thing opens, and closed with
// Back, after which focus must be on the control that opened it (R6).
//
// Not pressed: controls that start something playing. A player opened in one test leaves
// lookups behind that the next test's player waits on for ever (see the plan's notes), and
// every player has walks and journeys of its own (phases 5 to 7, and 9 for a room's).
//
// What it prints is the map of the app as a D-pad finds it: section, control, what opened.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';

import 'bed/phase7_pages.dart' show quiet;
import 'bed/phase9_pages.dart' show signIn, signOut;
import 'bed/walker.dart';
import 'harness.dart';

const _sections = ['home', 'discover', 'search', 'movies', 'tv', 'top', 'list', 'history', 'anime', 'live', 'downloads', 'servers', 'manga', 'music', 'audiobooks', 'party'];

/// What a kind of control is: its label without its words and the row it is in.
String _kind(String label) => label.replaceAll(RegExp(r" '[^']*'"), '').replaceAll(RegExp(r' under "[^"]*"'), '');

/// Why OK is not pressed on a control, if it is not.
String? _notPressed(String label) {
  if (RegExp(r'_RailItem|_RailProfile|_BottomItem').hasMatch(label)) return 'the navbar (each section is crawled by itself)';
  if (label.contains('WindowBar')) return 'the window’s own buttons';
  if (RegExp(r"'(Play|Resume|Watch|Listen|Read|Start|Continue)\b|PlayKey|ContinueWatching|_Continue|ChannelTile|_MatchCard|_TrackRow|_SongRow|SongTile|TrackTile|_QueueRow|_EpisodeCard|_ChapterRow|_DownloadRow|DownloadCard|_BookCard|AudiobookCard|_Recent|RecentTile|PlayBubble|_Deck|_ResumeCard").hasMatch(label)) {
    return 'starts something playing (its player is walked by its own phase’s tests)';
  }
  return null;
}

/// Kinds of things already walked in this run (a title's page opens from every section).
final _walked = <String>{};

/// What focus is in: its route, and the scope inside it.
(Route<dynamic>?, FocusScopeNode?) _where() {
  final node = FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (node == null || context == null) return (null, null);
  return (ModalRoute.of(context), node is FocusScopeNode ? node : node.nearestScope);
}

/// The app's own widget classes (not Flutter's), read once from the source.
final Set<String> _appClasses = {
  for (final root in const ['lib/screens', 'lib/widgets'])
    for (final f in Directory(root).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
      for (final m in RegExp(r'^class (\w+)', multiLine: true).allMatches(f.readAsStringSync())) m.group(1)!,
};

/// A name for what opened: the outermost of the app's own widgets around focus inside its
/// route, preferring one named like a page, a sheet, a box or a menu. A menu that opens in place
/// sits inside its page, so it is named by the nearest of those instead (what it hangs from).
String _name() {
  final node = FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (node == null || context == null) return 'nothing';
  final inMenu = Dpad.menuOf(node) != null;
  String? named, outer;
  context.visitAncestorElements((e) {
    if (e.widget is Navigator) return false;
    final n = e.widget.runtimeType.toString().split('<').first;
    if (_appClasses.contains(n)) {
      outer = n;
      if (RegExp(r'(Page|Shell|Sheet|Dialog|Menu|Picker|Panel|Box|View)$').hasMatch(n)) {
        named = n;
        if (inMenu) return false;
      }
    }
    return true;
  });
  // a Material dialog or menu round the app's own content
  if (named == null && outer == null) {
    context.visitAncestorElements((e) {
      if (e.widget is Navigator) return false;
      final n = e.widget.runtimeType.toString().split('<').first;
      if (RegExp(r'^(AlertDialog|Dialog|SimpleDialog|BottomSheet|_PopupMenu)$').hasMatch(n)) named = n.replaceAll('_', '');
      return true;
    });
  }
  // else the kind of route it is (a sheet or a box built by a function, not a class)
  return named ?? outer ?? ModalRoute.of(context)?.runtimeType.toString().split('<').first ?? describeStop(FocusManager.instance.primaryFocus!).$2;
}

FocusNode? _find(WidgetTester t, bool Function(String id, String label) wanted) {
  FocusNode? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Focus) {
      final node = w.focusNode;
      if (node != null && node.context != null && Dpad.isStop(node) && !node.rect.isEmpty) {
        final (id, label) = describeStop(node);
        if (wanted(id, label)) found = node;
      }
    }
    e.visitChildren(visit);
  }

  t.binding.rootElement!.visitChildren(visit);
  return found;
}

Future<void> _open(WidgetTester t, String section) async {
  await Bed.pumpShell(t);
  if (section != 'home') await Bed.openSection(t, section);
  await Bed.settle(t, rounds: 5);
  await Bed.dpadMode(t);
  await Bed.settle(t, rounds: 2);
}

Future<void> _crawl(WidgetTester t, String section, List<String> problems, List<String> map) async {
  await _open(t, section);

  final walk = await Walker(t, settle: () => Bed.settle(t, rounds: 1)).run(maxPresses: 4000);
  for (final p in walk.problems) {
    problems.add('$section: $p');
  }
  map.add('$section: walked ${walk.places.length} places in ${walk.presses} presses${walk.finished ? '' : ' (not to the end)'}');

  // one control of every kind
  final kinds = <String, Place>{};
  for (final p in walk.places.values) {
    final why = _notPressed(p.label);
    if (why != null) {
      if (!why.startsWith('the navbar') && !why.startsWith('the window')) kinds.putIfAbsent('skip ${_kind(p.label)}', () => p);
      continue;
    }
    kinds.putIfAbsent(_kind(p.label), () => p);
  }

  for (final entry in kinds.entries) {
    final place = entry.value;
    if (entry.key.startsWith('skip ')) {
      map.add('$section:   not pressed: ${place.label}: ${_notPressed(place.label)}');
      continue;
    }
    var node = _find(t, (id, _) => id == place.id) ?? _find(t, (_, label) => _kind(label) == entry.key);
    if (node == null) {
      // a long page builds only what is near the screen: back to where the walk found it
      final y = double.tryParse(RegExp(r'@-?\d+,(-?\d+) ').firstMatch(place.id)?.group(1) ?? '');
      if (y != null) {
        for (final s in t.stateList<ScrollableState>(find.byType(Scrollable))) {
          final p = s.position;
          if (p.axis == Axis.vertical && p.hasContentDimensions) p.jumpTo((y - 200).clamp(p.minScrollExtent, p.maxScrollExtent));
        }
        await Bed.settle(t, rounds: 3);
        node = _find(t, (id, _) => id == place.id) ?? _find(t, (_, label) => _kind(label) == entry.key);
      }
    }
    if (node == null) {
      // something pressed before it changed the page (a mode, a filter, a search): the section
      // afresh (a new tree, not the old one rebuilt), and once more
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 2);
      await _open(t, section);
      node = _find(t, (id, _) => id == place.id) ?? _find(t, (_, label) => _kind(label) == entry.key);
    }
    if (node == null) {
      map.add('$section:   gone before its turn: ${place.label}');
      continue;
    }
    node.requestFocus();
    await Bed.settle(t, rounds: 2);
    if (!node.hasPrimaryFocus) {
      map.add('$section:   could not be given focus: ${place.label}');
      continue;
    }
    if (node.context?.findAncestorWidgetOfExactType<EditableText>() != null) continue; // a text box: OK is the text's
    final from = describeStop(node).$2;
    final (routeWas, scopeWas) = _where();
    final sectionNav = Bed.sectionNavigator(t); // (noted now: a page over the whole window hides it)

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 100));
    await Bed.settle(t, rounds: 4);
    final threw = t.takeException();
    if (threw != null) problems.add('$section: OK on $from threw: ${'$threw'.split('\n').first}');

    var (routeNow, scopeNow) = _where();
    if (identical(routeNow, routeWas) && identical(scopeNow, scopeWas)) {
      map.add('$section:   OK on $from: did its work where it is');
      continue;
    }
    final what = _name();
    final inside = FocusManager.instance.primaryFocus; // where Back is pressed from, as a person would
    final page = !identical(routeNow, routeWas) && routeNow?.navigator != null && identical(routeNow!.navigator, sectionNav);
    if (_walked.add(what)) {
      // a page in the section has the navbar beside it; anything over the window or over the
      // page (a box, a sheet, a menu) is left with Back, so R3 does not apply to it; a menu that
      // opens in place is walked for its own items (the page under it can still take focus)
      final menu = inside == null ? null : Dpad.menuOf(inside);
      final sub = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: page ? null : (_) => true, within: menu).run(maxPresses: 1500);
      map.add('$section:   OK on $from: opened $what, walked ${sub.places.length} places${sub.finished ? '' : ' (not to the end)'}, ${sub.problems.length} problem(s)');
      for (final p in sub.problems) {
        if (sub.finished || !p.startsWith('R2')) problems.add('$section > $what (OK on $from): $p');
      }
    } else {
      map.add('$section:   OK on $from: opened $what (walked before)');
    }

    // out again with Back, from inside what opened (the walk may have left it for the navbar or
    // a bar beside it), as many as it takes (the walk may have opened a menu inside it)
    if (inside != null && (inside.context?.mounted ?? false) && inside.canRequestFocus) {
      inside.requestFocus();
      await Bed.settle(t, rounds: 2);
    }
    for (var i = 0; i < 6; i++) {
      (routeNow, scopeNow) = _where();
      if (identical(routeNow, routeWas)) break;
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 100));
      await Bed.settle(t, rounds: 3);
      final e = t.takeException();
      if (e != null) problems.add('$section > $what: Back threw: ${'$e'.split('\n').first}');
    }
    (routeNow, scopeNow) = _where();
    if (!identical(routeNow, routeWas)) {
      problems.add('$section > $what (OK on $from): six presses of Back did not return to the page it was opened from (focus is on ${Bed.focused()})');
      return;
    }
    if (!identical(scopeNow, scopeWas)) {
      // the page's own box closed by itself only on Back (a menu over the page): once more
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await Bed.settle(t, rounds: 3);
    }
    final back = FocusManager.instance.primaryFocus;
    if (back == null || !Dpad.isRest(back)) {
      problems.add('$section > $what: R1 after Back, focus is on nothing');
    } else if (!identical(back, node)) {
      final now = Dpad.isStop(back) ? describeStop(back).$2 : (back.debugLabel ?? 'a surface');
      if (node.context?.mounted ?? false) {
        problems.add('$section > $what: R6 Back returned to $now, not to $from');
      } else {
        map.add('$section:     (the control it opened from is gone after Back; focus is on $now)');
      }
    }
  }
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
    await Bed.withContent();
  });

  for (final section in _sections) {
    testWidgets('crawl: $section', (t) async {
      if (section == 'party') {
        signIn();
        addTearDown(signOut);
      }
      Bed.watchdog.clear();
      final problems = <String>[];
      final map = <String>[];
      await _crawl(t, section, problems, map);
      for (final line in map) {
        debugPrint('CRAWL $line', wrapWidth: 4000);
      }
      for (final line in Bed.watchdog) {
        debugPrint('CRAWL WATCHDOG $section: $line', wrapWidth: 4000);
      }
      for (final p in problems) {
        debugPrint('CRAWL PROBLEM $p', wrapWidth: 4000);
      }
      await t.pumpWidget(const SizedBox());
      await quiet(t);
      expect(problems, isEmpty, reason: 'the crawl of $section');
    }, variant: OnScreens([Screens.laptop]));
  }
}
