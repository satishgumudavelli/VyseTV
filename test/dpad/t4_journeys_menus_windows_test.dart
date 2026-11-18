// T4 for menus that open in place, on a desktop (2026-11-17; the TV side is
// t4_journeys_menus_test.dart). With a mouse nothing about them changed: a click opens one
// and leaves focus be, a click on an item chooses it. A menu a click opened takes the first
// arrow (it is what is on top) and the page behind it stays put; Enter chooses, Escape closes
// it, and either way focus ends on the menu's button, brought into view as any focus is.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'harness.dart';

/// The words on the focused control (the first text inside it), or '' with focus on nothing.
String _label() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return '';
  String? found;
  void down(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Text) {
      found = w.data ?? w.textSpan?.toPlainText();
      return;
    }
    e.visitChildren(down);
  }

  context.visitChildren(down);
  return found ?? '';
}

ScrollPosition _home(WidgetTester t) => t
    .state<ScrollableState>(find.descendant(of: find.byType(HomePage), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).first)
    .position;

/// The "If you like" title, which the row's menu hangs from.
Finder get _button => find.descendant(of: find.byType(MenuAnchor), matching: find.byType(Pressable)).first;

FocusNode? get _focus => FocusManager.instance.primaryFocus;
bool _inMenu() => _focus != null && Dpad.menuOf(_focus!) != null;
bool _menuShown() => find.byType(MenuItemButton).evaluate().isNotEmpty;
bool _onChoiceInUse() => _focus?.context?.findAncestorWidgetOfExactType<DpadStart>()?.start ?? false;
String _seed(WidgetTester t) => t.widget<Text>(find.descendant(of: _button, matching: find.byType(Text)).first).data!;

/// Home from its start, with the "If you like" title on screen and clicked: its menu open.
Future<double> _clickOpen(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await Bed.pumpShell(t);
  await t.ensureVisible(_button);
  await Bed.settle(t, rounds: 2);
  final page = _home(t).pixels;
  final was = _focus;
  await t.tap(_button);
  await Bed.settle(t, rounds: 3);
  expect(_menuShown(), isTrue, reason: 'a click opens the menu');
  expect(_inMenu(), isFalse, reason: 'and leaves focus where it was, as before');
  expect(identical(_focus, was), isTrue);
  return page;
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final desktop = OnScreens([Screens.desktop]);

  testWidgets('with a mouse the menu is as it was: a click on a title chooses it', (t) async {
    await _clickOpen(t);
    final third = find.byType(MenuItemButton).at(2);
    final title = t.widget<Text>(find.descendant(of: third, matching: find.byType(Text)).first).data!;
    await t.tap(third);
    await Bed.settle(t, rounds: 3);
    expect(_menuShown(), isFalse);
    expect(_seed(t), title);
  }, variant: desktop);

  testWidgets('a menu a click opened takes the first arrow, on the title in use; Enter chooses; focus ends on its button', (t) async {
    final page = await _clickOpen(t);
    await Bed.down(t);
    expect(_inMenu(), isTrue, reason: 'the first arrow went into the menu (it went on down the page, which closed the menu)');
    expect(_onChoiceInUse(), isTrue);
    await Bed.down(t);
    expect(_home(t).pixels, page, reason: 'the page behind the open menu stayed put');
    final pick = _label();
    expect(pick, isNot(_seed(t)));
    await Bed.ok(t);
    expect(_menuShown(), isFalse);
    expect(_seed(t), pick, reason: 'Enter chose it');
    expect(identical(_focus, Bed.nodeOf(t, _button)), isTrue, reason: "focus is on the menu's button");
    expect(Bed.focusInView(), isTrue);
  }, variant: desktop);

  testWidgets('Escape closes it without choosing, focus on its button', (t) async {
    final page = await _clickOpen(t);
    final was = _seed(t);
    await Bed.down(t, times: 3);
    expect(_inMenu(), isTrue);
    expect(_home(t).pixels, page);
    await Bed.back(t);
    expect(_menuShown(), isFalse);
    expect(_seed(t), was);
    expect(identical(_focus, Bed.nodeOf(t, _button)), isTrue);
    expect(Bed.focusInView(), isTrue);
  }, variant: desktop);
}
