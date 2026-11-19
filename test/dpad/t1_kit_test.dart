// T1: the focus kit by itself (lib/dpad). Which key is which, when D-pad mode turns on
// and off, Back handled once, hold-OK, what rows remember, the ring, and scrolling into view.
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_navigator.dart';
import 'package:vyse_tv/dpad/dpad_reveal.dart';
import 'package:vyse_tv/dpad/dpad_select_long_press_controller.dart';
import 'package:vyse_tv/dpad/focus_chrome.dart';
import 'package:vyse_tv/dpad/focus_memory_tracker.dart';
import 'package:vyse_tv/dpad/focus_navigation_intent.dart';
import 'package:vyse_tv/dpad/focusable_wrapper.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/dpad/key_event_utils.dart';
import 'package:vyse_tv/dpad/key_repeat_helper.dart';
import 'package:vyse_tv/dpad/locked_hub_controller.dart';
import 'package:vyse_tv/dpad/transport_keys.dart';

const _keyboard = ui.KeyEventDeviceType.keyboard;
const _remote = ui.KeyEventDeviceType.directionalPad;
const _gamepad = ui.KeyEventDeviceType.gamepad;

KeyDownEvent _down(LogicalKeyboardKey key, [ui.KeyEventDeviceType device = _keyboard]) =>
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: key, timeStamp: Duration.zero, deviceType: device);
KeyUpEvent _up(LogicalKeyboardKey key, [ui.KeyEventDeviceType device = _keyboard]) =>
    KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: key, timeStamp: Duration.zero, deviceType: device);
KeyRepeatEvent _repeat(LogicalKeyboardKey key) => KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: key, timeStamp: Duration.zero);

/// The kit as the app mounts it, around [child].
Widget _host(Widget child, {EdgeInsets insets = EdgeInsets.zero}) => InputModeTracker(
  child: MaterialApp(
    home: DpadInsets(insets: insets, child: Scaffold(body: child)),
  ),
);

/// Puts the app in D-pad mode the way a controller does.
Future<void> _dpadMode(WidgetTester t) async {
  InputModeTracker.reportNonPointerInput();
  await t.pump();
}

class _Counter extends StatefulWidget {
  const _Counter();
  static int created = 0;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    _Counter.created++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 120, height: 80);
}

class _Repeater extends StatefulWidget {
  const _Repeater();
  @override
  State<_Repeater> createState() => _RepeaterState();
}

class _RepeaterState extends State<_Repeater> with KeyRepeatHelper {
  int steps = 0;
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  group('keys', () {
    test('arrows, OK, Back and Menu are told apart', () {
      for (final k in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight]) {
        expect(k.isDpadDirection, isTrue);
        expect(k.isSelectKey || k.isBackKey || k.isContextMenuKey, isFalse);
      }
      for (final k in [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter, LogicalKeyboardKey.select, LogicalKeyboardKey.gameButtonA]) {
        expect(k.isSelectKey, isTrue, reason: k.debugName);
      }
      for (final k in [LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack, LogicalKeyboardKey.browserBack, LogicalKeyboardKey.gameButtonB]) {
        expect(k.isBackKey, isTrue, reason: k.debugName);
      }
      expect(LogicalKeyboardKey.contextMenu.isContextMenuKey, isTrue);
      expect(LogicalKeyboardKey.gameButtonX.isContextMenuKey, isTrue);
      expect(LogicalKeyboardKey.space.isSelectKey, isFalse, reason: 'Space stays play/pause');
      expect(LogicalKeyboardKey.backspace.isBackKey, isFalse, reason: 'Backspace deletes text');
      expect(LogicalKeyboardKey.keyA.isReservedControlKey, isFalse);
      expect(LogicalKeyboardKey.tab.isReservedControlKey, isTrue);
    });

    test('media keys', () {
      expect(classifyTransportKey(LogicalKeyboardKey.mediaPlay), TransportCommand.play);
      expect(classifyTransportKey(LogicalKeyboardKey.mediaPause), TransportCommand.pause);
      expect(classifyTransportKey(LogicalKeyboardKey.mediaPlayPause), TransportCommand.toggle);
      expect(classifyTransportKey(LogicalKeyboardKey.space), isNull);
      expect(classifyMediaSeekKey(LogicalKeyboardKey.mediaFastForward), MediaSeekDirection.forward);
      expect(classifyMediaSeekKey(LogicalKeyboardKey.mediaRewind), MediaSeekDirection.backward);
      expect(classifyMediaTrackKey(LogicalKeyboardKey.mediaTrackNext), MediaSeekDirection.forward);
      expect(classifyPlayerSkipKey(LogicalKeyboardKey.mediaTrackPrevious), MediaSeekDirection.backward);
      expect(classifyPlayerSkipKey(LogicalKeyboardKey.arrowRight), isNull);
    });

    test('a remote\'s OK is told from a keyboard\'s Enter', () {
      expect(_down(LogicalKeyboardKey.enter).isPhysicalKeyboardEnter, isTrue);
      expect(_down(LogicalKeyboardKey.enter).isTvSelectEvent, isFalse);
      expect(_down(LogicalKeyboardKey.enter, _remote).isTvSelectEvent, isTrue);
      expect(_down(LogicalKeyboardKey.select).isTvSelectEvent, isTrue);
      expect(_down(LogicalKeyboardKey.gameButtonA, _gamepad).isTvSelectEvent, isTrue);
      expect(_down(LogicalKeyboardKey.arrowUp).isActionable, isTrue);
      expect(_repeat(LogicalKeyboardKey.arrowUp).isActionable, isTrue);
      expect(_up(LogicalKeyboardKey.arrowUp).isActionable, isFalse);
    });
  });

  group('what counts as wanting to navigate', () {
    test('arrows and Tab do; Enter and Escape on a keyboard do not', () {
      for (final k in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.tab, LogicalKeyboardKey.contextMenu]) {
        expect(eventRequestsFocusNavigation(_down(k)), isTrue, reason: k.debugName);
      }
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.enter)), isFalse, reason: 'Enter acts on what is focused');
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.escape)), isFalse, reason: 'Escape only dismisses');
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.browserBack)), isFalse);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.keyA)), isFalse);
      expect(eventRequestsFocusNavigation(_up(LogicalKeyboardKey.arrowDown)), isFalse, reason: 'only a press starts a session');
    });

    test('a remote or a controller does with any of its keys', () {
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.select, _remote)), isTrue);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.enter, _remote)), isTrue);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.gameButtonA, _gamepad)), isTrue);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.goBack, _remote)), isTrue);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.gameButtonB, _gamepad)), isTrue);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.escape, _remote)), isTrue);
    });

    test('an arrow the focused feature uses itself does not (the player seeks with it)', () {
      final player = DirectionalShortcutFocusNode(consumesDirectionalKeys: (k) => k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight);
      addTearDown(player.dispose);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.arrowRight), focused: player), isFalse);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.arrowUp), focused: player), isTrue, reason: 'it only owns left and right');
      final plain = FocusNode();
      addTearDown(plain.dispose);
      expect(eventRequestsFocusNavigation(_down(LogicalKeyboardKey.arrowRight), focused: plain), isTrue);
    });
  });

  group('D-pad mode', () {
    testWidgets('starts off, turns on at the first arrow, off at the first touch', (t) async {
      late BuildContext inside;
      await t.pumpWidget(_host(Builder(builder: (c) {
        inside = c;
        return const SizedBox.expand();
      })));
      expect(InputModeTracker.currentMode, InputMode.pointer);
      expect(InputModeTracker.isKeyboardMode(inside, listen: false), isFalse);

      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      // known at once, before any rebuild: focus listeners run during the key press
      expect(InputModeTracker.currentMode, InputMode.keyboard);
      await t.pump();
      expect(InputModeTracker.isKeyboardMode(inside, listen: false), isTrue);
      expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.alwaysTraditional);
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);

      await t.tapAt(const Offset(200, 200));
      await t.pump();
      expect(InputModeTracker.currentMode, InputMode.pointer);
      expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.automatic);
    });

    testWidgets('Enter, Escape and letters leave it off; Tab turns it on; moving the mouse turns it off', (t) async {
      await t.pumpWidget(_host(const SizedBox.expand()));
      for (final k in [LogicalKeyboardKey.enter, LogicalKeyboardKey.escape, LogicalKeyboardKey.keyK, LogicalKeyboardKey.space]) {
        await t.sendKeyEvent(k);
        expect(InputModeTracker.currentMode, InputMode.pointer, reason: k.debugName);
      }
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(InputModeTracker.currentMode, InputMode.keyboard);

      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 10));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(40, 40));
      await t.pump();
      expect(InputModeTracker.currentMode, InputMode.pointer);
    });

    testWidgets('a controller turns it on by reporting itself', (t) async {
      await t.pumpWidget(_host(const SizedBox.expand()));
      InputModeTracker.reportNonPointerInput();
      expect(InputModeTracker.currentMode, InputMode.keyboard);
      await t.pump();
    });

    testWidgets('the mouse cursor is hidden only while it is on', (t) async {
      await t.pumpWidget(_host(const SizedBox.expand()));
      bool hidden() => t.widgetList<MouseRegion>(find.byType(MouseRegion)).any((m) => m.cursor == SystemMouseCursors.none);
      expect(hidden(), isFalse);
      await _dpadMode(t);
      expect(hidden(), isTrue);
      await t.tapAt(const Offset(5, 5));
      await t.pump();
      expect(hidden(), isFalse);
    });
  });

  group('Back', () {
    test('acts once, when the key comes up', () {
      var backs = 0;
      KeyEventResult send(KeyEvent e) => handleBackKeyAction(e, () => backs++);
      expect(send(_down(LogicalKeyboardKey.escape)), KeyEventResult.handled);
      expect(send(_repeat(LogicalKeyboardKey.escape)), KeyEventResult.handled);
      expect(backs, 0, reason: 'holding Back must not act, or it would act on every page it passes');
      expect(send(_up(LogicalKeyboardKey.escape)), KeyEventResult.handled);
      expect(backs, 1);
      expect(send(_down(LogicalKeyboardKey.arrowDown)), KeyEventResult.ignored);
      expect(backs, 1);
    });

    testWidgets('a key-up left over from a page that just closed is swallowed, the next press is not', (t) async {
      BackKeyUpSuppressor.suppressBackUntilKeyUp();
      var backs = 0;
      KeyEventResult send(KeyEvent e) => handleBackKeyAction(e, () => backs++);
      expect(send(_up(LogicalKeyboardKey.goBack)), KeyEventResult.handled);
      expect(backs, 0, reason: 'this release belongs to the press that closed the page');
      send(_down(LogicalKeyboardKey.goBack));
      send(_up(LogicalKeyboardKey.goBack));
      expect(backs, 1);

      // armed, but the release never reached us: the next press is a new one and must work
      BackKeyUpSuppressor.suppressBackUntilKeyUp();
      expect(send(_down(LogicalKeyboardKey.goBack)), KeyEventResult.handled);
      send(_up(LogicalKeyboardKey.goBack));
      expect(backs, 2);
      BackKeyUpSuppressor.clearSuppression();
    });

    testWidgets('a page popped while Back is held arms that swallow by itself', (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(InputModeTracker(
        child: MaterialApp(navigatorKey: nav, navigatorObservers: [BackKeySuppressorObserver()], home: const SizedBox()),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await t.pumpAndSettle();

      await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
      expect(BackKeyPressTracker.isBackKeyDown, isTrue);
      nav.currentState!.pop();
      await t.pumpAndSettle();
      var backs = 0;
      // the release lands on the page underneath, whose own Back handler must not fire
      expect(handleBackKeyAction(_up(LogicalKeyboardKey.escape), () => backs++), KeyEventResult.handled);
      expect(backs, 0);
      await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
      expect(BackKeyPressTracker.isBackKeyDown, isFalse);
    });

    testWidgets('one press is never handled twice in a frame', (t) async {
      await t.pumpWidget(const SizedBox());
      expect(BackKeyCoordinator.consumeIfHandled(), isFalse);
      BackKeyCoordinator.markHandled();
      expect(BackKeyCoordinator.consumeIfHandled(), isTrue, reason: 'the system reporting the same Back');
      expect(BackKeyCoordinator.consumeIfHandled(), isFalse);
      BackKeyCoordinator.markHandled();
      await t.pump();
      await t.pump();
      expect(BackKeyCoordinator.consumeIfHandled(), isFalse, reason: 'the mark does not outlive its frame');
    });
  });

  group('holding OK', () {
    testWidgets('a short press presses, a long one long-presses and does not also press', (t) async {
      final c = DpadSelectLongPressController();
      addTearDown(c.dispose);
      var short = 0, long = 0;
      KeyEventResult send(KeyEvent e) => c.handleKeyEvent(e, isOwnerActive: () => true, onShortPress: () => short++, onLongPress: () => long++);

      send(_down(LogicalKeyboardKey.select));
      await t.pump(const Duration(milliseconds: 100));
      send(_up(LogicalKeyboardKey.select));
      expect((short, long), (1, 0));

      send(_down(LogicalKeyboardKey.select));
      send(_repeat(LogicalKeyboardKey.select));
      await t.pump(const Duration(milliseconds: 600));
      expect((short, long), (1, 1));
      // the release is swallowed wherever it lands (a menu may have taken focus)
      expect(SelectKeyUpSuppressor.consumeIfSuppressed(_up(LogicalKeyboardKey.select)), isTrue);
      send(_up(LogicalKeyboardKey.select));
      expect((short, long), (1, 1));
    });
  });

  group('what rows remember', () {
    test('each row keeps its own place; a new row starts under the last column', () {
      final m = HubFocusMemory();
      expect(m.getForHub('trending', 20), 0);
      m.setForHub('trending', 6);
      m.setForHub('top10', 2);
      expect(m.getForHub('trending', 20), 6, reason: 'back to where you were in that row');
      expect(m.getForHub('top10', 10), 2);
      expect(m.getForHub('never visited', 20), 2, reason: 'the column you came from');
      expect(m.getForHub('short row', 2), 1, reason: 'never past the end');
      expect(m.getForHubOnly('never visited', 20), 0);
      m.remapForHub('trending', 3);
      expect(m.getForHub('trending', 20), 3);
      expect(m.getForHub('never visited', 20), 2, reason: 'a reshuffle is not the user moving');
      expect(m.getForHub('empty', 0), 0);
    });

    testWidgets('the last focused item can be given focus back', (t) async {
      var changes = 0;
      final m = FocusMemoryTracker(onFocusChanged: () => changes++);
      addTearDown(m.dispose);
      await t.pumpWidget(MaterialApp(
        home: Column(children: [
          for (final k in ['a', 'b', 'c']) Focus(focusNode: m.get(k), child: const SizedBox(width: 50, height: 50)),
          const Focus(child: SizedBox(width: 50, height: 50)),
        ]),
      ));
      m.get('b').requestFocus();
      await t.pump();
      expect(m.lastFocusedKey, 'b');
      expect(m.isFocused('b'), isTrue);
      FocusManager.instance.primaryFocus!.unfocus();
      await t.pump();
      expect(m.isFocused('b'), isFalse);
      expect(m.restoreFocus(), isTrue);
      await t.pump();
      expect(m.isFocused('b'), isTrue);
      m.pruneExcept({'a', 'c'});
      expect(m.lastFocusedKey, isNull);
      expect(m.restoreFocus(fallbackKey: 'c'), isTrue);
      expect(changes, greaterThan(0));
    });
  });

  testWidgets('a held key repeats steadily after a pause, and stops', (t) async {
    await t.pumpWidget(const _Repeater());
    final s = t.state<_RepeaterState>(find.byType(_Repeater));
    s.startRepeat(() => s.steps++);
    expect(s.steps, 1);
    await t.pump(const Duration(milliseconds: 390));
    expect(s.steps, 1, reason: 'a tap is one step');
    await t.pump(const Duration(milliseconds: 20));
    await t.pump(const Duration(milliseconds: 300));
    expect(s.steps, 4);
    s.stopRepeat();
    await t.pump(const Duration(seconds: 1));
    expect(s.steps, 4);
  });

  group('a focusable control', () {
    const childKey = Key('child');
    Widget control({VoidCallback? onSelect, VoidCallback? onLongPress, FocusNode? node, bool glow = true, double scale = 1.05, VoidCallback? onLeft, VoidCallback? onBack}) => Center(
      child: FocusableWrapper(
        focusNode: node,
        onSelect: onSelect,
        onLongPress: onLongPress,
        enableLongPress: onLongPress != null,
        onNavigateLeft: onLeft,
        onBack: onBack,
        useFocusGlow: glow,
        focusScale: scale,
        borderRadius: 12,
        child: const SizedBox(key: childKey, width: 120, height: 80, child: _Counter()),
      ),
    );
    RenderFocusChrome chrome(WidgetTester t) => t.renderObject<RenderFocusChrome>(find.byType(FocusChrome));

    // One ring, on the control that has focus. A card used to keep its own ring (and its growth)
    // while focus was on a button inside it, and the two rings did not line up: "the misborder
    // alignments" of the sixth round from testers' TVs (docs/dpad/PLAN.md note 91).
    testWidgets('one with focus on something inside it draws no ring of its own; the ring is on what has focus', (t) async {
      final inner = FocusNode();
      addTearDown(inner.dispose);
      Widget page({required bool can}) => _host(
        FocusableWrapper(
          canRequestFocus: can,
          disableScale: true,
          child: Padding(padding: const EdgeInsets.all(40), child: FocusableWrapper(focusNode: inner, child: const SizedBox(width: 80, height: 40))),
        ),
      );
      RenderFocusChrome outer(WidgetTester t) => t.renderObject<RenderFocusChrome>(find.byType(FocusChrome).first);
      RenderFocusChrome within(WidgetTester t) => t.renderObject<RenderFocusChrome>(find.byType(FocusChrome).last);
      await t.pumpWidget(page(can: true));
      await _dpadMode(t);
      inner.requestFocus();
      await t.pumpAndSettle();
      expect(within(t).shown, 1);
      expect(outer(t).shown, 0, reason: 'a card and its star: the ring is on the star, never on both');
      // focus on the control itself: its own ring, and none left on what is inside it
      Focus.of(t.element(find.byType(FocusableWrapper).last)).requestFocus();
      await t.pumpAndSettle();
      expect(inner.hasFocus, isFalse);
      expect(outer(t).shown, 1);
      expect(within(t).shown, 0);
      // the same wrapper, now only a frame round what is inside it (a player that fills the window)
      inner.requestFocus();
      await t.pumpWidget(page(can: false));
      await t.pumpAndSettle();
      expect(inner.hasPrimaryFocus, isTrue);
      expect(outer(t).shown, 0, reason: 'no ring round something that is not a control');
      expect(within(t).shown, 1);
    });

    testWidgets('shows its ring only in D-pad mode, and never moves or resizes', (t) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(control(node: node)));
      final rect = t.getRect(find.byKey(childKey));

      // focused, but a pointer is in charge: nothing is drawn
      node.requestFocus();
      await t.pumpAndSettle();
      expect(node.hasPrimaryFocus, isTrue);
      expect(chrome(t).shown, 0);
      expect(find.byType(FocusChrome), isNot(paints..rrect()));
      expect(find.byType(FocusGlow), findsNothing);

      await _dpadMode(t);
      await t.pumpAndSettle();
      expect(chrome(t).shown, 1);
      expect(find.byType(FocusChrome), paints..rrect()..rrect());
      expect(find.byType(FocusGlow), findsOneWidget);
      expect(t.getRect(find.byKey(childKey)), rect, reason: 'the ring and the growth are paint only');
      expect(t.getSize(find.byType(FocusableWrapper)), rect.size);

      // the mouse moves: the ring goes, focus stays where it was
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(chrome(t).shown, 0);
      expect(find.byType(FocusGlow), findsNothing);
      expect(node.hasPrimaryFocus, isTrue);
      expect(t.getRect(find.byKey(childKey)), rect);
    });

    testWidgets('keeps what is inside it alive through focus and mode changes', (t) async {
      _Counter.created = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(control(node: node)));
      expect(_Counter.created, 1);
      await _dpadMode(t);
      node.requestFocus();
      await t.pumpAndSettle();
      node.unfocus();
      await t.pumpAndSettle();
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      node.requestFocus();
      await _dpadMode(t);
      await t.pumpAndSettle();
      expect(_Counter.created, 1, reason: 'the child was rebuilt from scratch: a poster would fade in again');
    });

    testWidgets('OK presses it in D-pad mode and does nothing while a pointer is in charge', (t) async {
      var presses = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(control(node: node, onSelect: () => presses++)));
      node.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(presses, 0, reason: 'the focus is not shown, so Enter must not press it');

      await _dpadMode(t);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(presses, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await t.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      expect(presses, 4);
      // holding it down is still one press
      await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(presses, 5);
    });

    testWidgets('holding OK, or the Menu key, long-presses', (t) async {
      var presses = 0, longs = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(control(node: node, onSelect: () => presses++, onLongPress: () => longs++)));
      await _dpadMode(t);
      node.requestFocus();
      await t.pump();

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect((presses, longs), (1, 0));
      await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 600));
      await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect((presses, longs), (1, 1));
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      expect((presses, longs), (1, 2));
      await t.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
      expect((presses, longs), (1, 3));
    });

    testWidgets('a control that cannot be pressed is not a stop', (t) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(Center(
        child: FocusableWrapper(focusNode: node, canRequestFocus: false, child: const SizedBox(width: 50, height: 50)),
      )));
      node.requestFocus();
      await t.pump();
      expect(node.hasFocus, isFalse);
    });

    testWidgets('an edge override and a Back override are called for their keys only', (t) async {
      var lefts = 0, backs = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(control(node: node, onLeft: () => lefts++, onBack: () => backs++)));
      await _dpadMode(t);
      node.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(lefts, 1);
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      expect(lefts, 3, reason: 'a held arrow keeps going');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(backs, 1);
      await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
      expect(backs, 2, reason: 'a held Back is one Back');
    });

    testWidgets('the ring follows the Appearance accent and the control\'s own corners', (t) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await t.pumpWidget(_host(control(node: node)));
      await _dpadMode(t);
      node.requestFocus();
      await t.pumpAndSettle();
      final w = t.widget<FocusChrome>(find.byType(FocusChrome));
      expect(w.color, const Color(0xFFFFA53A), reason: "Vyse's own amber, the default theme");
      expect(w.radius, BorderRadius.circular(12));
      expect(w.width, 2);
    });
  });

  group('coming into view', () {
    // every item is built (a lazy list would not have the far ones to focus)
    Widget list(Axis axis, List<FocusNode> nodes, {bool block = false}) => SingleChildScrollView(
      scrollDirection: axis,
      child: Flex(
        direction: axis,
        children: [
          for (final n in nodes)
            Builder(builder: (context) {
              final item = FocusableWrapper(
                focusNode: n,
                child: SizedBox(width: axis == Axis.horizontal ? 200 : 400, height: axis == Axis.vertical ? 100 : 300),
              );
              if (!block) return item;
              // a heading above the control: the two come into view together
              return DpadRevealBlock(child: Column(children: [const SizedBox(height: 60), item]));
            }),
        ],
      ),
    );
    List<FocusNode> nodes(int n) {
      final all = List.generate(n, (i) => FocusNode(debugLabel: 'item $i'));
      addTearDown(() {
        for (final n in all) {
          n.dispose();
        }
      });
      return all;
    }

    double offset(WidgetTester t) => t.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

    testWidgets('up and down: the focused control comes to the middle', (t) async {
      t.view.physicalSize = const Size(400, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final n = nodes(30);
      await t.pumpWidget(_host(list(Axis.vertical, n)));
      await _dpadMode(t);
      n[20].requestFocus();
      await t.pumpAndSettle();
      // item 20 spans 2000..2100; the middle of a 600 window puts its top at 250
      expect(offset(t), 1750);
      // one step down scrolls one row; the page follows the focus
      n[21].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 1850);
      // near the top the list simply rests at its start
      n[1].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 0);
      n[29].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 2400, reason: 'the end of the list');
    });

    testWidgets('nothing comes to rest under the app\'s bars', (t) async {
      t.view.physicalSize = const Size(400, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final n = nodes(30);
      await t.pumpWidget(_host(list(Axis.vertical, n), insets: const EdgeInsets.only(top: 100, bottom: 80)));
      await _dpadMode(t);
      for (final i in [20, 3, 28, 11]) {
        n[i].requestFocus();
        await t.pumpAndSettle();
        final rect = t.getRect(find.byWidgetPredicate((w) => w is FocusableWrapper && w.focusNode == n[i]));
        expect(rect.top, greaterThanOrEqualTo(100), reason: 'item $i is under the top bar');
        expect(rect.bottom, lessThanOrEqualTo(520), reason: 'item $i is under the bottom bar');
        expect(DpadReveal.visibleArea(n[i].context!).contains(rect.topLeft), isTrue);
        expect(DpadReveal.visibleArea(n[i].context!).contains(rect.bottomRight - const Offset(1, 1)), isTrue);
      }
      // 100..520 is what can be seen; item 20 (2000..2100) is centred in it: top at 260
      n[20].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 1740);
    });

    testWidgets('sideways: a row moves only as far as it must, and comes back to rest', (t) async {
      t.view.physicalSize = const Size(800, 300);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final n = nodes(12);
      await t.pumpWidget(_host(list(Axis.horizontal, n)));
      await _dpadMode(t);
      n[2].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 0, reason: 'already in view');
      n[5].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 412, reason: 'its right edge, and room for the ring, just inside');
      n[4].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 412, reason: 'still in view: the row stays put');
      n[2].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 388, reason: 'its left edge, and room for the ring, just inside');
      n[0].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 0, reason: 'back where the row started');
    });

    testWidgets('a row and its heading come into view together', (t) async {
      t.view.physicalSize = const Size(400, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final n = nodes(20);
      await t.pumpWidget(_host(list(Axis.vertical, n, block: true)));
      await _dpadMode(t);
      n[10].requestFocus();
      await t.pumpAndSettle();
      // blocks are 160 tall; block 10 spans 1600..1760 and is centred: top at 220
      expect(offset(t), 1380);
    });

    testWidgets('a pointer scrolling the page is never fought', (t) async {
      t.view.physicalSize = const Size(400, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final n = nodes(30);
      await t.pumpWidget(_host(list(Axis.vertical, n)));
      // pointer mode: focus arriving by program must not move the page
      n[20].requestFocus();
      await t.pumpAndSettle();
      expect(offset(t), 0);
    });
  });
}
