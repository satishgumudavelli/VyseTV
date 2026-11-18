// T3: the focus walk. It drives a page with nothing but arrow keys, the way a remote would,
// from wherever focus is, pressing every direction from every place it reaches until nothing
// new turns up. Along the way and at the end it checks the rules of docs/dpad/PLAN.md:
//
//   R1  after every press something focusable has focus
//   R2  every enabled control on the page was reached
//   R3  from every place reached, the navbar can be reached (no traps)
//   R4  the focused control is fully in view: not scrolled off, not under a bar
//
// A problem names the control by the app widget it is (and that widget's source file).
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_reveal.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';

const _arrows = [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowUp];

String _arrowName(LogicalKeyboardKey k) => switch (k) {
  LogicalKeyboardKey.arrowDown => 'Down',
  LogicalKeyboardKey.arrowUp => 'Up',
  LogicalKeyboardKey.arrowLeft => 'Left',
  _ => 'Right',
};

/// App widget classes and the files that define them, read once from the source.
final Map<String, String> _appClasses = () {
  final found = <String, String>{};
  for (final root in const ['lib/screens', 'lib/widgets']) {
    for (final f in Directory(root).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r'^class (\w+)', multiLine: true).allMatches(f.readAsStringSync())) {
        found.putIfAbsent(m.group(1)!, () => f.path.replaceAll('\\', '/'));
      }
    }
  }
  // the mechanism itself says nothing about which control this is
  found.remove('Pressable');
  return found;
}();

/// One place focus can be.
class Place {
  Place(this.id, this.label, this.rect);

  /// Stable for the same control even after a lazy list rebuilt it: what it is, and where it
  /// sits in its page (scrolling taken out).
  final String id;

  /// For people: "OutlineCard in PosterCard 'The Long Night' (lib/widgets/media_rows.dart)".
  final String label;

  /// On screen, when it was last focused.
  Rect rect;

  @override
  String toString() => label;
}

class WalkReport {
  final places = <String, Place>{};
  final moves = <String, Map<LogicalKeyboardKey, String>>{};
  final problems = <String>[];

  /// Layout overflows met on the way. They are the page's own (a row too wide for this
  /// window), not something focus did, so they are kept apart from [problems]; a test says
  /// how many it knows about.
  final overflows = <String>[];
  int presses = 0;
  bool finished = false;

  Iterable<Place> where(Pattern label) => places.values.where((p) => p.label.contains(label));

  /// Fails the test with every problem found, most useful first.
  void expectClean({String? reason, int knownOverflows = 0}) {
    expect(finished, isTrue, reason: 'the walk ran out of presses ($presses) before it had tried everything');
    expect(overflows.length, lessThanOrEqualTo(knownOverflows), reason: 'layout overflows on this page at this size: $overflows');
    if (problems.isNotEmpty) {
      fail('${reason == null ? '' : '$reason: '}${problems.length} problem(s) on a walk of ${places.length} places and $presses presses:\n${problems.take(40).map((p) => '  - $p').join('\n')}');
    }
  }
}

/// How a control is named and told apart.
(String id, String label) describeStop(FocusNode node) {
  final context = node.context!;
  final names = <String>[];
  String? file;
  context.visitAncestorElements((e) {
    final name = e.widget.runtimeType.toString();
    final base = name.split('<').first;
    if (_appClasses.containsKey(base)) {
      names.add(name);
      file ??= _appClasses[base];
    }
    return names.length < 2;
  });
  // the first words inside it
  String? text;
  void visit(Element e) {
    if (text != null) return;
    final w = e.widget;
    if (w is Text) {
      text = w.data ?? w.textSpan?.toPlainText();
    } else if (w is Icon && names.isEmpty) {
      text = 'icon ${w.icon?.codePoint.toRadixString(16)}';
    } else if (w is Tooltip) {
      text = w.message;
    }
    if (text == null) e.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);

  // where it sits in its page: on screen, plus how far every list around it has scrolled
  var rect = node.rect;
  var scrollable = Scrollable.maybeOf(context);
  while (scrollable != null) {
    final p = scrollable.position;
    final by = axisDirectionIsReversed(p.axisDirection) ? -p.pixels : p.pixels;
    rect = rect.shift(p.axis == Axis.vertical ? Offset(0, by) : Offset(by, 0));
    scrollable = Scrollable.maybeOf(scrollable.context);
  }
  // the row it is in, by the row's heading
  String? row;
  context.visitAncestorElements((e) {
    if (e.widget is! DpadRevealBlock) return true;
    void first(Element x) {
      if (row != null) return;
      final w = x.widget;
      if (w is Text) row = w.data ?? w.textSpan?.toPlainText();
      if (row == null) x.visitChildren(first);
    }

    e.visitChildren(first);
    return false;
  });
  final kind = names.isEmpty ? context.widget.runtimeType.toString() : names.join(' in ');
  final under = row == null || row == text ? '' : ' under "$row"';
  final shown = text == null ? '' : " '${text!.length > 28 ? '${text!.substring(0, 28)}…' : text}'";
  final where = '${rect.left.round()},${rect.top.round()} ${rect.width.round()}x${rect.height.round()}';
  // The id leaves the heading out: the hero's "heading" is the slide on show, which changes
  // by itself, and the button under it is the same button.
  return ('$kind$shown @$where', '$kind$under$shown${file == null ? '' : ' ($file)'}');
}

class Walker {
  Walker(this.t, {this.settle, this.isNavbar, this.ignore, this.within});

  final WidgetTester t;

  /// Called every few presses to let the page load what the walk scrolled into view.
  final Future<void> Function()? settle;

  /// Which places count as the navbar (for R3). Left out: any place in a `_RailItem`,
  /// `_RailProfile` or `_BottomItem`.
  final bool Function(Place place)? isNavbar;

  /// Controls on screen that this walk need not reach, with the reason given by the caller.
  final bool Function(String label)? ignore;

  /// For a walk of a menu that opens in place: only its own items count for R2. The page under
  /// such a menu can still take focus (it is not covered by a route), but the arrows stay in the
  /// menu until it closes, as they should.
  final FocusScopeNode? within;

  final report = WalkReport();

  /// The very controls that had focus (a rail entry is the same control open or closed,
  /// though its size, and so its id, differs).
  final _visited = Set<FocusNode>.identity();

  Place? _here() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || !Dpad.isStop(node)) return null;
    _visited.add(node);
    final (id, label) = describeStop(node);
    final place = report.places.putIfAbsent(id, () => Place(id, label, node.rect));
    place.rect = node.rect;
    return place;
  }

  Future<void> press(LogicalKeyboardKey key) async {
    report.presses++;
    await t.sendKeyEvent(key);
    // Past the pace a held arrow moves at. Then three frames, as a screen would draw them:
    // the one in which focus arrives (the page starts scrolling after it), the one in which
    // the scroll starts its clock, and one late enough for it to have finished.
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 20));
    await t.pump(const Duration(milliseconds: 300));
    // and until whatever the press set moving has come to rest (a card sliding in, the hero
    // growing into the spotlight), so a control is always looked at where it ends up
    for (var i = 0; i < 9 && t.binding.transientCallbackCount > 0; i++) {
      await t.pump(const Duration(milliseconds: 130));
    }
    if (report.presses % 12 == 0) await settle?.call();
  }

  bool _inView(FocusNode node) {
    final seen = DpadReveal.visibleArea(node.context!).inflate(1);
    final r = node.rect;
    return r.left >= seen.left && r.top >= seen.top && r.right <= seen.right && r.bottom <= seen.bottom;
  }

  Future<void> _check(Place? from, LogicalKeyboardKey key, Place? now) async {
    final how = '${_arrowName(key)} from ${from ?? 'nothing'}';
    final error = t.takeException();
    if (error != null) {
      final what = '$error'.split('\n').first;
      if (what.contains('overflowed')) {
        report.overflows.add('$what ($how)');
      } else {
        report.problems.add('$how threw: $what');
      }
    }
    if (now == null) {
      report.problems.add('R1 focus lost: $how left focus on ${FocusManager.instance.primaryFocus?.debugLabel ?? 'nothing'}');
      return;
    }
    final node = FocusManager.instance.primaryFocus!;
    if (!_inView(node)) {
      // A card a list has only just built slides in over two thirds of a second. Where it
      // comes to rest is what counts.
      await t.pump(const Duration(milliseconds: 20));
      await t.pump(const Duration(milliseconds: 700));
    }
    if (node.context != null && !_inView(node)) {
      final seen = DpadReveal.visibleArea(node.context!);
      final r = node.rect;
      String n(double v) => v.toStringAsFixed(0);
      report.problems.add('R4 not fully in view: $now at ${n(r.left)},${n(r.top)}..${n(r.right)},${n(r.bottom)}, visible is ${n(seen.left)},${n(seen.top)}..${n(seen.right)},${n(seen.bottom)} ($how)');
    }
  }

  /// The presses that lead from [from] to the nearest place that still has a direction to try.
  List<LogicalKeyboardKey>? _routeToUntried(String from) {
    final queue = Queue<String>()..add(from);
    final via = <String, (String, LogicalKeyboardKey)>{};
    final seen = {from};
    while (queue.isNotEmpty) {
      final at = queue.removeFirst();
      final tried = report.moves[at] ?? const {};
      if (tried.length < _arrows.length && at != from) {
        final path = <LogicalKeyboardKey>[];
        var step = at;
        while (step != from) {
          final (prev, key) = via[step]!;
          path.insert(0, key);
          step = prev;
        }
        return path;
      }
      for (final e in tried.entries) {
        if (seen.add(e.value)) {
          via[e.value] = (at, e.key);
          queue.add(e.value);
        }
      }
    }
    return null;
  }

  Future<WalkReport> run({int maxPresses = 2500}) async {
    // the press that picks the remote up
    if (_here() == null) {
      await press(LogicalKeyboardKey.arrowDown);
      if (_here() == null) await press(LogicalKeyboardKey.arrowDown);
    }
    var here = _here();
    if (here == null) {
      report.problems.add('R1 nothing took focus when an arrow was pressed');
      return report;
    }
    var stuck = 0;
    while (report.presses < maxPresses) {
      final tried = report.moves.putIfAbsent(here!.id, () => {});
      LogicalKeyboardKey? key;
      for (final k in _arrows) {
        if (!tried.containsKey(k)) {
          key = k;
          break;
        }
      }
      final exploring = key != null;
      if (key == null) {
        final route = _routeToUntried(here.id);
        if (route == null) {
          report.finished = true;
          break;
        }
        key = route.first;
      }
      final from = here;
      await press(key);
      final now = _here();
      await _check(from, key, now);
      if (now == null) {
        // try to carry on from wherever a second press lands
        await press(LogicalKeyboardKey.arrowDown);
        here = _here();
        if (here == null) break;
        continue;
      }
      if (exploring) {
        tried[key] = now.id;
        stuck = 0;
      } else if (tried[key] != now.id) {
        // the same press from the same place led somewhere else this time (a row remembered
        // a different item): note the new way and carry on from here
        tried[key] = now.id;
        if (++stuck > 200) {
          report.problems.add('the walk kept being led somewhere new by the same presses (last: ${_arrowName(key)} from $from)');
          break;
        }
      }
      here = now;
    }
    // everything at rest before it is counted
    await settle?.call();
    await t.pump(const Duration(milliseconds: 20));
    await t.pump(const Duration(milliseconds: 800));
    _afterwards();
    return report;
  }

  void _afterwards() {
    // R2: everything on screen that can be pressed was reached
    final reached = report.places.keys.toSet();
    final missed = <String>{};
    void visit(Element e) {
      final w = e.widget;
      if (w is Focus) {
        final node = w.focusNode;
        if (node != null && node.context != null && Dpad.isStop(node) && !node.rect.isEmpty && (within == null || node.ancestors.contains(within))) {
          final (id, label) = describeStop(node);
          if (!_visited.contains(node) && !reached.contains(id) && !(ignore?.call(label) ?? false)) missed.add('$label [$id]');
        }
      }
      e.visitChildren(visit);
    }

    t.binding.rootElement!.visitChildren(visit);
    for (final label in missed) {
      report.problems.add('R2 never reached: $label');
    }

    // R3: no traps. Work back from the navbar along the recorded moves.
    bool navbar(Place p) => isNavbar?.call(p) ?? RegExp(r'_RailItem|_RailProfile|_BottomItem').hasMatch(p.label);
    final back = <String, Set<String>>{};
    report.moves.forEach((from, tos) {
      for (final to in tos.values) {
        (back[to] ??= {}).add(from);
      }
    });
    final canLeave = <String>{for (final p in report.places.values) if (navbar(p)) p.id};
    if (canLeave.isEmpty) {
      report.problems.add('R3 the walk never reached the navbar at all');
      return;
    }
    final queue = Queue<String>.of(canLeave);
    while (queue.isNotEmpty) {
      for (final from in back[queue.removeFirst()] ?? const <String>{}) {
        if (canLeave.add(from)) queue.add(from);
      }
    }
    for (final p in report.places.values) {
      if (!canLeave.contains(p.id)) report.problems.add('R3 trap: no way from $p to the navbar with arrows');
    }
  }
}
