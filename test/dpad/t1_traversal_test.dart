// T1, continued: where an arrow key takes focus (lib/dpad/dpad_traversal.dart and
// dpad_root.dart), on small made-up layouts where the right answer is plain to see.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/dpad/focusable_wrapper.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';

int _backs = 0;

Widget _host(Widget child) => InputModeTracker(
  child: MaterialApp(
    builder: (context, app) => DpadRoot(onBack: () => _backs++, child: app!),
    home: Scaffold(body: child),
  ),
);

/// A labelled focusable box.
Widget _box(String name, {double w = 100, double h = 60, VoidCallback? onSelect}) => Padding(
  padding: const EdgeInsets.all(5),
  child: FocusableWrapper(
    semanticLabel: name,
    excludeChildSemantics: false,
    onSelect: onSelect ?? () {},
    child: SizedBox(width: w, height: h, child: Text(name)),
  ),
);

String _focused() => FocusManager.instance.primaryFocus?.debugLabel ?? 'nothing';

Future<void> _press(WidgetTester t, LogicalKeyboardKey key, [int times = 1]) async {
  for (var i = 0; i < times; i++) {
    await t.sendKeyEvent(key);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 20));
    await t.pump(const Duration(milliseconds: 250));
  }
}

const _down = LogicalKeyboardKey.arrowDown, _up = LogicalKeyboardKey.arrowUp, _left = LogicalKeyboardKey.arrowLeft, _right = LogicalKeyboardKey.arrowRight;

void main() {
  setUp(() => _backs = 0);

  testWidgets('the first arrow lands on the top-left control; a grid keeps its column', (t) async {
    await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var r = 0; r < 3; r++) Row(mainAxisSize: MainAxisSize.min, children: [for (var c = 0; c < (r == 2 ? 2 : 3); c++) _box('r${r}c$c')]),
    ])));
    expect(_focused(), isNot(startsWith('r')));
    await _press(t, _right);
    expect(_focused(), 'r0c0', reason: 'the first press shows where the page starts; it does not also move');
    await _press(t, _right, 2);
    expect(_focused(), 'r0c2');
    await _press(t, _right);
    expect(_focused(), 'r0c2', reason: 'nothing to the right: stay');
    await _press(t, _down);
    expect(_focused(), 'r1c2', reason: 'straight down the column');
    await _press(t, _down);
    expect(_focused(), 'r2c1', reason: 'the last row is short: its nearest item');
    await _press(t, _up);
    expect(_focused(), 'r1c1');
    await _press(t, _left, 3);
    expect(_focused(), 'r1c0');
  });

  testWidgets('a sideways move never jumps to another line', (t) async {
    await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [_box('play'), _box('add')]),
      const SizedBox(height: 40),
      Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 5; i++) _box('card$i')]),
    ])));
    await _press(t, _right, 2);
    expect(_focused(), 'add');
    await _press(t, _right);
    expect(_focused(), 'add', reason: 'card2 is further right but on another line');
    await _press(t, _down);
    expect(_focused(), 'card1', reason: 'down goes to what is under it');
  });

  testWidgets('rows remember their place; Up and Down give it back', (t) async {
    await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final row in ['a', 'b', 'c'])
        DpadRail(child: Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 6; i++) _box('$row$i')])),
    ])));
    await _press(t, _right);
    expect(_focused(), 'a0');
    await _press(t, _right, 4);
    expect(_focused(), 'a4');
    await _press(t, _down);
    expect(_focused(), 'b4', reason: 'a row never visited: the item under you');
    await _press(t, _left, 3);
    expect(_focused(), 'b1');
    await _press(t, _up);
    expect(_focused(), 'a4', reason: 'back in the first row: where you were, not above b1');
    await _press(t, _down);
    expect(_focused(), 'b1');
    await _press(t, _down);
    expect(_focused(), 'c1');
    await _press(t, _up, 2);
    expect(_focused(), 'a4');
  });

  testWidgets('buttons on a list row: Right steps in, Left steps out, Down keeps to the same button', (t) async {
    Widget row(String name) => FocusableWrapper(
      semanticLabel: name,
      excludeChildSemantics: false,
      onSelect: () {},
      child: SizedBox(
        width: 500,
        height: 70,
        child: Row(children: [Expanded(child: Text(name)), _box('$name play', w: 40, h: 40), _box('$name delete', w: 40, h: 40)]),
      ),
    );
    await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_box('filter'), row('one'), row('two'), row('three')])));
    await _press(t, _down);
    expect(_focused(), 'filter');
    await _press(t, _down);
    expect(_focused(), 'one', reason: 'the row itself, not a button inside it');
    await _press(t, _down);
    expect(_focused(), 'two');
    await _press(t, _right);
    expect(_focused(), 'two play', reason: 'Right steps onto the row\'s first button');
    await _press(t, _right);
    expect(_focused(), 'two delete');
    await _press(t, _right);
    expect(_focused(), 'two delete');
    await _press(t, _down);
    expect(_focused(), 'three delete', reason: 'the same button on the next row');
    await _press(t, _up, 2);
    expect(_focused(), 'one delete');
    await _press(t, _up);
    expect(_focused(), 'filter', reason: 'above the first row: what is there');
    await _press(t, _down);
    await _press(t, _right, 2);
    await _press(t, _left);
    expect(_focused(), 'one play');
    await _press(t, _left);
    expect(_focused(), 'one', reason: 'Left off the first button is back on the row');
  });

  testWidgets('a region keeps arrows in; its exits lead out and back to where you were', (t) async {
    late final DpadRegionNode nav, page;
    nav = DpadRegionNode(debugLabel: 'nav', onExit: (d) => d == TraversalDirection.right && Dpad.enter(page));
    page = DpadRegionNode(debugLabel: 'page', onExit: (d) => d == TraversalDirection.left && Dpad.enter(nav));
    addTearDown(nav.dispose);
    addTearDown(page.dispose);
    await t.pumpWidget(_host(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DpadRegion(node: nav, child: Column(children: [_box('home'), _box('search'), _box('list')])),
      const SizedBox(width: 30),
      DpadRegion(node: page, child: Column(children: [
        Row(mainAxisSize: MainAxisSize.min, children: [_box('p00'), _box('p01')]),
        Row(mainAxisSize: MainAxisSize.min, children: [_box('p10'), _box('p11')]),
      ])),
    ])));
    Dpad.enter(page);
    await t.pump();
    await _press(t, _down);
    await _press(t, _down);
    await _press(t, _right);
    expect(_focused(), 'p11');
    await _press(t, _left, 2);
    expect(_focused(), 'home', reason: 'off the page\'s left edge: the navbar');
    await _press(t, _down, 5);
    expect(_focused(), 'list', reason: 'Down at the last entry stays in the navbar');
    await _press(t, _left);
    expect(_focused(), 'list');
    await _press(t, _right);
    expect(_focused(), 'p10', reason: 'back in the page, on what you left');
    await _press(t, _left);
    expect(_focused(), 'list', reason: 'and the navbar gives back its own place too');
  });

  testWidgets('a held arrow steps no faster than the kit\'s pace', (t) async {
    await t.pumpWidget(_host(Row(children: [for (var i = 0; i < 20; i++) _box('n$i', w: 20)])));
    await _press(t, _right);
    expect(_focused(), 'n0');
    await t.sendKeyDownEvent(_right);
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 10));
      await t.sendKeyRepeatEvent(_right);
    }
    await t.sendKeyUpEvent(_right);
    await t.pump(const Duration(milliseconds: 300));
    // 200 ms of holding at 80 ms a step
    expect(_focused(), anyOf('n3', 'n4'));
  });

  testWidgets('when the focused control goes away, its neighbour takes focus', (t) async {
    final items = ValueNotifier(['a', 'b', 'c', 'd', 'e']);
    addTearDown(items.dispose);
    await t.pumpWidget(_host(ValueListenableBuilder(
      valueListenable: items,
      builder: (_, list, _) => Row(children: [for (final n in list) KeyedSubtree(key: ValueKey(n), child: _box(n))]),
    )));
    await _press(t, _right, 4);
    expect(_focused(), 'd');
    await _press(t, _left, 3);
    await _press(t, _right, 2);
    expect(_focused(), 'c');
    // c is removed (a card taken off a row): d slides into its place and gets focus, not a,
    // which is merely what was focused before
    items.value = ['a', 'b', 'd', 'e'];
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(_focused(), 'd');
    items.value = ['a', 'b', 'd'];
    await t.pump(const Duration(milliseconds: 200));
    expect(_focused(), 'd');
    items.value = ['a', 'b'];
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(_focused(), 'b', reason: 'the end of the row went: the new end');
  });

  testWidgets('a page with nothing to focus yet gets its first focus when something appears', (t) async {
    final loaded = ValueNotifier(false);
    addTearDown(loaded.dispose);
    await t.pumpWidget(_host(ValueListenableBuilder(
      valueListenable: loaded,
      builder: (_, ready, _) => ready ? Column(children: [_box('first'), _box('second')]) : const Center(child: Text('Loading')),
    )));
    InputModeTracker.reportNonPointerInput();
    await t.pump(const Duration(milliseconds: 300));
    expect(Dpad.isStop(FocusManager.instance.primaryFocus), isFalse);
    loaded.value = true;
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 200));
    expect(_focused(), 'first', reason: 'R1: in D-pad mode something has focus as soon as there is something');
  });

  // A box its page starts on ([start]), or starts on when nothing else says so ([orElse]).
  Widget mark(String name, {bool start = false, bool orElse = false}) => Padding(
    padding: const EdgeInsets.all(5),
    child: FocusableWrapper(
      semanticLabel: name,
      autofocus: start,
      autofocusFallback: orElse,
      onSelect: () {},
      child: SizedBox(width: 100, height: 60, child: Text(name)),
    ),
  );

  testWidgets('a first focus nobody chose gives way to the page\'s start when it arrives late; not once a key was pressed', (t) async {
    for (final pressedFirst in [false, true]) {
      final loaded = ValueNotifier(false);
      final menu = DpadRegionNode(debugLabel: 'menu');
      await t.pumpWidget(_host(Column(children: [
        _box('outside'),
        DpadRegion(
          key: ValueKey(pressedFirst),
          node: menu,
          child: ValueListenableBuilder(
            valueListenable: loaded,
            builder: (_, ready, _) => Column(children: [_box('close'), if (ready) _box('row 1'), if (ready) mark('row 2', start: true)]),
          ),
        ),
      ])));
      InputModeTracker.reportNonPointerInput();
      await t.pump(const Duration(milliseconds: 300));
      Dpad.enter(menu);
      await t.pump();
      expect(_focused(), 'close', reason: 'the list is still loading: the only stop there is');
      if (pressedFirst) await _press(t, _down);
      loaded.value = true;
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(_focused(), pressedFirst ? 'close' : 'row 2', reason: pressedFirst ? 'a key was pressed: focus is where the viewer left it' : 'the start arrived: focus moves to it');
      await t.pumpWidget(const SizedBox());
      loaded.dispose();
      menu.dispose();
    }
  });

  testWidgets('a menu starts on its marked control; with none, on its selected tab; with neither, top-left', (t) async {
    Future<String> opensOn({required bool tab, required bool row}) async {
      final menu = DpadRegionNode(debugLabel: 'menu');
      await t.pumpWidget(_host(Column(children: [
        _box('outside'),
        DpadRegion(
          node: menu,
          child: Column(children: [
            Row(mainAxisSize: MainAxisSize.min, children: [_box('tab 1'), mark('tab 2', orElse: tab)]),
            _box('row 1'),
            mark('row 2', start: row),
          ]),
        ),
      ])));
      InputModeTracker.reportNonPointerInput();
      await t.pump(const Duration(milliseconds: 300));
      Dpad.enter(menu);
      await t.pump();
      final on = _focused();
      await t.pumpWidget(const SizedBox());
      menu.dispose();
      return on;
    }

    expect(await opensOn(tab: true, row: true), 'row 2');
    expect(await opensOn(tab: true, row: false), 'tab 2');
    expect(await opensOn(tab: false, row: false), 'tab 1');
  });

  testWidgets('coming into a tab strip from its content lands on the tab that is showing, not the nearest', (t) async {
    await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DpadRail(child: Row(mainAxisSize: MainAxisSize.min, children: [_box('tab 1'), _box('tab 2'), mark('tab 3', orElse: true)])),
      _box('row 1'),
      _box('row 2'),
    ])));
    await _press(t, _down);
    await _press(t, _down);
    expect(_focused(), 'row 1', reason: 'the first arrow shows the ring on tab 1, the second goes down');
    await _press(t, _up);
    expect(_focused(), 'tab 3', reason: 'tab 1 is straight above and was the last one focused: the showing tab still wins');
    await _press(t, _left);
    expect(_focused(), 'tab 2', reason: 'along the strip, arrows move as anywhere');
  });

  testWidgets('a start inside a region is only a mark: built with a mouse in charge, it takes no focus', (t) async {
    final menu = DpadRegionNode(debugLabel: 'menu');
    addTearDown(menu.dispose);
    await t.pumpWidget(_host(Column(children: [
      _box('outside'),
      DpadRegion(node: menu, child: Column(children: [_box('row 1'), mark('row 2', start: true)])),
    ])));
    await t.pump(const Duration(milliseconds: 500));
    expect(_focused(), isNot('row 2'));
    expect(menu.hasFocus, isFalse);
  });

  testWidgets('a row of tabs that wraps onto two lines: Up and Down reach its other line', (t) async {
    await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 240,
        child: DpadRail(child: Wrap(children: [_box('tab 1'), _box('tab 2'), mark('tab 3', orElse: true), _box('tab 4')])),
      ),
      _box('row 1'),
    ])));
    await _press(t, _down);
    expect(_focused(), 'tab 3', reason: 'the page starts on the tab that is showing (second line)');
    await _press(t, _up);
    expect(_focused(), 'tab 1', reason: 'Up reaches the first line of the same row of tabs');
    await _press(t, _right);
    expect(_focused(), 'tab 2');
    await _press(t, _right);
    expect(_focused(), 'tab 2', reason: 'Right at the end of a line does not jump to the next line');
    await _press(t, _down);
    expect(_focused(), 'tab 4');
    await _press(t, _down);
    expect(_focused(), 'row 1');
    await _press(t, _up);
    expect(_focused(), 'tab 3', reason: 'coming back up lands on the tab that is showing');
  });

  testWidgets('DpadStart marks a Material button as where a page starts', (t) async {
    final menu = DpadRegionNode(debugLabel: 'menu');
    addTearDown(menu.dispose);
    final play = FocusNode(debugLabel: 'play');
    addTearDown(play.dispose);
    await t.pumpWidget(_host(Column(children: [
      _box('outside'),
      DpadRegion(
        node: menu,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _box('previous'),
          DpadStart(child: IconButton(focusNode: play, onPressed: () {}, icon: const Icon(Icons.play_arrow))),
          _box('next'),
        ]),
      ),
    ])));
    await t.pump(const Duration(milliseconds: 300));
    expect(play.hasFocus, isFalse, reason: 'it is only a mark: with a mouse in charge nothing takes focus');
    InputModeTracker.reportNonPointerInput();
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(play.hasPrimaryFocus, isTrue, reason: 'with a D-pad the page starts on the marked button, not on its top-left control');
    Dpad.enter(menu);
    await t.pump();
    expect(play.hasPrimaryFocus, isTrue);
    await _press(t, _left);
    expect(_focused(), 'previous');
  });

  testWidgets('the ring round a Material button fades without error when its page closes under it', (t) async {
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await t.pumpWidget(_host(Column(children: [
      _box('stays'),
      ValueListenableBuilder(
        valueListenable: shown,
        builder: (_, on, _) => on ? IconButton(onPressed: () {}, icon: const Icon(Icons.play_arrow)) : const SizedBox(),
      ),
    ])));
    await _press(t, _down);
    await _press(t, _down);
    expect(_focused(), isNot('stays'), reason: 'focus is on the Material button, which gets the ring of the app drawn round it');
    shown.value = false;
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    await t.pump(const Duration(milliseconds: 200));
    expect(t.takeException(), isNull);
    expect(_focused(), 'stays', reason: 'R1: focus moved to what is left');
  });

  testWidgets('with a pointer in charge nothing is given focus', (t) async {
    await t.pumpWidget(_host(Column(children: [_box('first'), _box('second')])));
    await t.pump(const Duration(milliseconds: 500));
    expect(Dpad.isStop(FocusManager.instance.primaryFocus), isFalse);
  });

  testWidgets('Back: once per press, whatever is held; a dialog that closes on Escape closes first', (t) async {
    await t.pumpWidget(_host(Builder(
      builder: (context) => _box('open', onSelect: () => showDialog<void>(context: context, builder: (_) => AlertDialog(content: _box('inside')))),
    )));
    await _press(t, _down);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(_backs, 1);
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    expect(_backs, 2, reason: 'a held Back is one Back');

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await _press(t, _down);
    expect(_focused(), 'inside', reason: 'focus is inside the dialog');
    await _press(t, _up, 3);
    await _press(t, _left, 3);
    expect(_focused(), 'inside', reason: 'and cannot leave it');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: 'Back closed the dialog');
    expect(_backs, 2, reason: 'and did nothing else');
    expect(_focused(), 'open', reason: 'focus is back on what opened it');
  });

  testWidgets('a text box: arrows with nothing left to do in it move on', (t) async {
    final text = TextEditingController(text: 'abc');
    addTearDown(text.dispose);
    final field = FocusNode(debugLabel: 'field');
    addTearDown(field.dispose);
    await t.pumpWidget(_host(Column(children: [
      _box('above'),
      Row(mainAxisSize: MainAxisSize.min, children: [_box('before'), SizedBox(width: 200, child: TextField(controller: text, focusNode: field)), _box('after')]),
      _box('below'),
    ])));
    InputModeTracker.reportNonPointerInput();
    field.requestFocus();
    await t.pump(const Duration(milliseconds: 200));
    text.selection = const TextSelection.collapsed(offset: 3);
    await _press(t, _left);
    expect(field.hasPrimaryFocus, isTrue, reason: 'the caret moves, not the focus');
    expect(text.selection.baseOffset, 2);
    await _press(t, _left, 2);
    expect(text.selection.baseOffset, 0);
    await _press(t, _left);
    expect(_focused(), 'before', reason: 'Left with the caret at the start leaves the box');
    field.requestFocus();
    await t.pump(const Duration(milliseconds: 200));
    text.selection = const TextSelection.collapsed(offset: 3);
    await _press(t, _right);
    expect(_focused(), 'after', reason: 'Right with the caret at the end leaves the box');
    field.requestFocus();
    await t.pump(const Duration(milliseconds: 200));
    await _press(t, _up);
    expect(_focused(), 'above');
    field.requestFocus();
    await t.pump(const Duration(milliseconds: 200));
    await _press(t, _down);
    expect(_focused(), 'below');
  });

  group('phase 10', () {
    testWidgets('a row of tabs is entered on the showing tab, and the page still starts where it starts', (t) async {
      var showing = 1;
      await t.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _box('start'),
          DpadRail(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.all(5),
                  child: FocusableWrapper(
                    semanticLabel: 'tab$i',
                    excludeChildSemantics: false,
                    railEntry: i == showing,
                    onSelect: () => setState(() => showing = i),
                    child: SizedBox(width: 100, height: 40, child: Text('tab$i')),
                  ),
                ),
            ]),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [for (var c = 0; c < 4; c++) _box('item$c')]),
        ]),
      )));
      await _press(t, _down);
      expect(_focused(), 'start', reason: 'a mark on a tab is not where the page starts');
      await _press(t, _down);
      expect(_focused(), 'tab1', reason: 'into the row of tabs on the showing one');
      await _press(t, _right, 2);
      expect(_focused(), 'tab3', reason: 'along the tabs: nothing changes without OK');
      await _press(t, _down);
      expect(_focused(), startsWith('item'));
      await _press(t, _up);
      expect(_focused(), 'tab1', reason: 'back up: the showing tab, not the one last passed over');
      await _press(t, _right);
      await _press(t, LogicalKeyboardKey.enter);
      await _press(t, _down);
      await _press(t, _left, 2);
      await _press(t, _up);
      expect(_focused(), 'tab2', reason: 'OK on another tab moves the mark with it');
    });

    testWidgets('backBindings: Escape, a remote’s Back, the browser’s Back and B each act once a press, held or not', (t) async {
      var closed = 0;
      await t.pumpWidget(_host(CallbackShortcuts(bindings: backBindings(() => closed++), child: _box('only'))));
      await _press(t, _down);
      expect(_focused(), 'only');
      // each as the platform it comes from (the simulator needs that platform's key codes)
      const keys = [
        (LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape, 'windows'),
        (LogicalKeyboardKey.goBack, PhysicalKeyboardKey.escape, 'android'), // a remote's Back
        (LogicalKeyboardKey.browserBack, PhysicalKeyboardKey.browserBack, 'windows'),
        (LogicalKeyboardKey.gameButtonB, PhysicalKeyboardKey.gameButtonB, 'android'),
      ];
      for (final (logical, physical, platform) in keys) {
        await t.sendKeyDownEvent(logical, physicalKey: physical, platform: platform);
        for (var i = 0; i < 5; i++) {
          await t.sendKeyRepeatEvent(logical, physicalKey: physical, platform: platform);
        }
        await t.sendKeyUpEvent(logical, physicalKey: physical, platform: platform);
        await t.pump();
      }
      expect(closed, 4, reason: 'each key once, its repeats nothing');
      expect(_backs, 0, reason: 'and none of them also reached the app as a Back');
    });

    testWidgets('a page opened from outside its navigator gives focus back to its opener when it closes', (t) async {
      final inner = GlobalKey<NavigatorState>();
      final returns = DpadReturnObserver();
      Widget side(String name) => _box(name, onSelect: () => inner.currentState!.push(MaterialPageRoute<void>(builder: (_) => Column(children: [_box('page of $name')]))));
      await t.pumpWidget(_host(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [side('side1'), side('side2')]),
        Expanded(
          child: Navigator(
            key: inner,
            observers: [returns],
            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => Column(children: [_box('home1'), _box('home2')])),
          ),
        ),
      ])));
      await _press(t, _down);
      await _press(t, _down);
      expect(_focused(), 'home2', reason: 'the navigator’s first page takes the first focus');
      // over to the side column (a route is a wall to arrows unless a region says where to
      // cross, as Music's do: here focus is simply put there)
      t.widget<Focus>(find.descendant(of: find.widgetWithText(FocusableWrapper, 'side2'), matching: find.byType(Focus)).first).focusNode!.requestFocus();
      await t.pump(const Duration(milliseconds: 200));
      expect(_focused(), 'side2');
      await _press(t, LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(_focused(), 'page of side2', reason: 'the page opened, and took focus');
      inner.currentState!.pop();
      await t.pumpAndSettle();
      expect(_focused(), 'side2', reason: 'closed: back on the row that opened it, not on the page underneath');
      // opened from inside the navigator, the navigator's own restore is left alone
      t.widget<Focus>(find.descendant(of: find.widgetWithText(FocusableWrapper, 'home1'), matching: find.byType(Focus)).first).focusNode!.requestFocus();
      await t.pump(const Duration(milliseconds: 200));
      expect(_focused(), 'home1');
      final opener = _focused();
      inner.currentState!.push(MaterialPageRoute<void>(builder: (_) => Column(children: [_box('inner page')])));
      await t.pumpAndSettle();
      inner.currentState!.pop();
      await t.pumpAndSettle();
      expect(_focused(), opener);
    });

    testWidgets('on a phone or a TV, arrows onto a text box leave the on-screen keyboard down; OK brings it up', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final text = TextEditingController();
      addTearDown(text.dispose);
      await t.pumpWidget(_host(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _box('above'),
        SizedBox(width: 300, child: TextField(controller: text)),
        _box('below'),
      ])));
      await _press(t, _down);
      expect(_focused(), 'above');
      t.testTextInput.log.clear();
      await _press(t, _down);
      bool typing() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;
      expect(typing(), isTrue, reason: 'the arrow went onto the text box');
      expect(t.testTextInput.hasAnyClients, isFalse, reason: 'with the keyboard down');
      expect(t.testTextInput.log.map((c) => c.method), isNot(contains('TextInput.show')));
      // OK (a remote's centre button): the keyboard, not an empty "send"
      await t.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await t.pump();
      expect(t.testTextInput.hasAnyClients, isTrue);
      expect(t.testTextInput.log.map((c) => c.method), contains('TextInput.show'));
      t.testTextInput.enterText('kite');
      await t.pump();
      expect(text.text, 'kite');
      // the keyboard put away (Back on it): OK brings it back
      t.testTextInput.log.clear();
      t.testTextInput.hide();
      await t.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
      await t.pump();
      expect(t.testTextInput.log.map((c) => c.method), contains('TextInput.show'));
      await _press(t, _down);
      expect(_focused(), 'below', reason: 'arrows still leave the box');
      // on a desktop nothing changed: the box takes the keyboard as focus arrives
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await _press(t, _up);
      expect(typing(), isTrue);
      expect(t.testTextInput.hasAnyClients, isTrue);
      debugDefaultTargetPlatformOverride = null; // (a test must put it back itself)
    });

    testWidgets('a page still loading: the first focus waits for something in view, not a control far below', (t) async {
      t.view.physicalSize = const Size(800, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final loaded = ValueNotifier(false);
      addTearDown(loaded.dispose);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await t.pumpWidget(_host(SingleChildScrollView(
        controller: scroll,
        child: ValueListenableBuilder<bool>(
          valueListenable: loaded,
          builder: (_, l, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // the rows, still loading (as tall as they will be)
            for (var i = 0; i < 6; i++) SizedBox(height: 200, child: l ? _box('row$i') : const SizedBox()),
            _box('footer'),
          ]),
        ),
      )));
      // a TV: D-pad mode before any key
      InputModeTracker.reportNonPointerInput();
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 120));
      }
      expect(_focused(), isNot('footer'), reason: 'not the one control there is yet, far below');
      expect(scroll.offset, 0, reason: 'the page did not run to its bottom');
      loaded.value = true;
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 120));
      }
      expect(_focused(), 'row0', reason: 'the page loaded: its top');
      expect(scroll.offset, 0);
    });

    testWidgets('a page with nothing in view for good: after a moment, focus still goes below', (t) async {
      t.view.physicalSize = const Size(800, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(SingleChildScrollView(
        child: Column(children: [const SizedBox(height: 900), _box('below')]),
      )));
      InputModeTracker.reportNonPointerInput();
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 120));
      }
      expect(_focused(), 'below', reason: 'about a second and a half on, the control there is');
    });

    testWidgets('a held arrow keeps its steady pace for a second, then speeds up through a long list', (t) async {
      t.view.physicalSize = const Size(800, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(ListView.builder(itemCount: 600, itemExtent: 60, itemBuilder: (_, i) => _box('row$i', h: 50))));
      await _press(t, _down);
      expect(_focused(), 'row0');
      int at() => int.parse(_focused().substring(3));
      await t.sendKeyDownEvent(_down);
      await t.pump(const Duration(milliseconds: 33));
      var afterOne = 0;
      for (var i = 0; i < 150; i++) {
        await t.sendKeyRepeatEvent(_down);
        await t.pump(const Duration(milliseconds: 33));
        if (i == 29) afterOne = at();
      }
      await t.sendKeyUpEvent(_down);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100)); // (the list catching up with the last step)
      }
      final afterFive = at();
      expect(afterOne, inInclusiveRange(10, 16), reason: 'the first second: the steady pace (about twelve a second)');
      expect(afterFive, greaterThan(120), reason: 'five seconds held: far further than the steady pace (about 60) would go');
      final r = FocusManager.instance.primaryFocus!.rect;
      expect(r.top >= 0 && r.bottom <= 600, isTrue, reason: 'and the list kept up: the row is on screen ($r)');
    });

    group('the watchdog', () {
      late List<String> lines;
      setUp(() {
        lines = [];
        DpadRoot.watchdogLog = lines.add;
      });
      tearDown(() => DpadRoot.watchdogLog = (line) => debugPrint(line));

      testWidgets('a page with nothing to focus for a while is named in the log, with how long', (t) async {
        final ready = ValueNotifier(true);
        addTearDown(ready.dispose);
        await t.pumpWidget(_host(ValueListenableBuilder<bool>(valueListenable: ready, builder: (_, r, _) => LoadingPage(ready: r))));
        await _press(t, _down);
        expect(_focused(), 'ready');
        ready.value = false; // its one control goes, and nothing takes its place yet
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(lines, isEmpty, reason: 'said when it is over, not while it goes on');
        ready.value = true; // loaded
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 130));
        }
        expect(_focused(), 'ready');
        expect(lines, hasLength(1));
        expect(lines.single, allOf(startsWith('D-pad: no focus for '), contains('frames'), contains('LoadingPage')));
      });

      testWidgets('focus put back within the frame is not news; nor is anything with a mouse in charge', (t) async {
        final first = ValueNotifier(true);
        addTearDown(first.dispose);
        await t.pumpWidget(_host(ValueListenableBuilder<bool>(
          valueListenable: first,
          builder: (_, f, _) => Column(children: [
            if (f) KeyedSubtree(key: const ValueKey('a'), child: _box('a')),
            KeyedSubtree(key: const ValueKey('b'), child: _box('b')),
          ]),
        )));
        await _press(t, _down);
        expect(_focused(), 'a');
        first.value = false;
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(_focused(), 'b', reason: 'the neighbour took its place');
        expect(lines, isEmpty);
        // a mouse in charge: focus on nothing is normal there
        await t.tapAt(const Offset(700, 500));
        await t.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(lines, isEmpty);
      });
    });
  });
}

/// A page whose one control comes and goes, as a page's content does while it loads.
class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key, required this.ready});
  final bool ready;
  @override
  Widget build(BuildContext context) => Center(child: ready ? _box('ready') : const Text('Loading'));
}

