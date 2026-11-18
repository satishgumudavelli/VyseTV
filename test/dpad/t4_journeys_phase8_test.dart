// T4 for phase 8: journeys through Profile and settings with arrows, OK and Back only.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/nav_sections.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/screens/profile/avatar_picker.dart';
import 'package:vyse_tv/screens/profile/profile_page.dart';

import 'bed/phase8_pages.dart';
import 'harness.dart';

bool _inBox() => FocusManager.instance.primaryFocus?.nearestScope?.debugLabel?.contains('Modal') ?? false;

/// The row of a setting, found by its title: the control the test wants is to its right.
Rect _row(WidgetTester t, String title) => t.getRect(find.text(title));

/// Moves focus with Down until it is on the line of [title] (its switch or its choices).
Future<void> _downTo(WidgetTester t, String title) async {
  for (var i = 0; i < 30; i++) {
    final at = FocusManager.instance.primaryFocus?.rect;
    final row = _row(t, title);
    if (at != null && at.center.dy > row.top - 30 && at.center.dy < row.bottom + 60) return;
    await Bed.down(t);
  }
  fail('Down never reached the row of "$title"; focus is on ${Bed.focused()}');
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('settings start on the tab that is showing; OK shows another; Left from what it shows comes back to its tab', (t) async {
    await openProfile(t);
    await Bed.down(t);
    expect(Bed.focused(), allOf(contains('_SideItem'), contains('Account')), reason: 'settings start on the tab that is showing');
    for (var i = 0; i < 12 && !Bed.focused().contains('Playback'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('Playback'));
    expect(find.text('Streaming mode'), findsNothing, reason: 'moving along the tabs does not switch them');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Streaming mode'), findsOneWidget, reason: 'OK shows the tab');
    expect(Bed.focused(), contains('Playback'), reason: 'and focus stays on it');
    await Bed.right(t);
    expect(Bed.focused(), isNot(contains('_SideItem')), reason: 'Right goes into what the tab shows');
    await Bed.down(t, times: 3);
    for (var i = 0; i < 4 && !Bed.focused().contains('_SideItem'); i++) {
      await Bed.left(t);
    }
    expect(Bed.focused(), allOf(contains('_SideItem'), contains('Playback')), reason: 'Left comes back to the tab that is showing, wherever you were beside the list');
    await Bed.back(t);
    expect(find.byType(ProfilePage), findsNothing, reason: 'Back leaves settings');
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  testWidgets('a switch flips with OK and a choice is picked with OK; both stick', (t) async {
    await openSettings(t, 'Playback');
    await Bed.right(t);
    final was = AppSettings.autoNext.value;
    await _downTo(t, 'Auto next episode');
    expect(Bed.focused(), contains('_Switch'));
    await Bed.ok(t);
    expect(AppSettings.autoNext.value, !was, reason: 'OK flips the switch');
    expect(Bed.focused(), contains('_Switch'), reason: 'and focus stays on it');
    await Bed.ok(t);
    expect(AppSettings.autoNext.value, was);

    await _downTo(t, 'Seek amount');
    expect(Bed.focused(), contains('_Choice'), reason: 'Down from the switches reaches the row of choices');
    final seek = AppSettings.seekSeconds.value;
    for (var i = 0; i < 4; i++) {
      await Bed.left(t);
      if (!Bed.focused().contains('_Choice')) {
        await Bed.right(t);
        break;
      }
    }
    expect(Bed.focused(), allOf(contains('_Choice'), contains('5s')), reason: 'Left walks the choices to the first');
    await Bed.ok(t);
    expect(AppSettings.seekSeconds.value, 5);
    await Bed.right(t);
    await Bed.ok(t);
    expect(AppSettings.seekSeconds.value, 10);
    AppSettings.seekSeconds.value = seek;
  }, variant: screen);

  testWidgets('the navbar’s order: Move down moves the row and focus goes with it', (t) async {
    await openSettings(t, 'Appearance');
    final first = NavLayout.all.first;
    final second = NavLayout.all[1];
    await Bed.dpadMode(t);
    await Bed.focus(t, find.byTooltip('Move down').first);
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(NavLayout.all[1], first, reason: 'the first section moved down one');
    expect(NavLayout.all.first, second);
    expect(Bed.focused(), contains('_NavRow'), reason: 'R1: focus is still on a button of the list');
    final node = FocusManager.instance.primaryFocus!;
    expect(node.rect.center.dy, greaterThan(t.getRect(find.text(second.label).first).center.dy - 10), reason: 'on the row that moved (now second), not on the row that took its place');
    // and back up
    await Bed.left(t);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(NavLayout.all.first, first, reason: 'Move up, one step to the left, puts it back');
    NavLayout.reset();
    await Bed.settle(t, rounds: 2);
  }, variant: screen);

  testWidgets('a question box (Danger Zone) opens on the safe answer and Back answers nothing', (t) async {
    await openSettings(t, 'Danger Zone');
    await Bed.right(t);
    expect(Bed.focused(), contains('_SmallButton'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(_inBox(), isTrue, reason: 'the reset asks first');
    final opened = Bed.focused();
    await Bed.right(t);
    await Bed.left(t, times: 2);
    expect(_inBox(), isTrue, reason: 'arrows stay in the box');
    await Bed.back(t);
    expect(_inBox(), isFalse);
    expect(Bed.focused(), contains('_SmallButton'), reason: 'Back closes it and focus is on the button that asked');
    expect(opened, isNot('nothing'));
  }, variant: screen);

  testWidgets('connecting a tracker: each Connect button either opens its box, which keeps the arrows and closes with Back, or says why not', (t) async {
    // Closing a sign-in that never finished ends its wait with an error ("cancelled") that the
    // app leaves unheard, with a mouse too. An error nobody hears fails a test, so this one
    // journey runs where it is heard, and passes only if that is the one error there was.
    final unheard = <Object>[];
    var boxes = 0, count = 0;
    final done = Completer<void>();
    runZonedGuarded(() async {
      await openSettings(t, 'Account');
      final connects = find.descendant(of: find.byType(ProfilePage), matching: find.text('Connect'));
      count = connects.evaluate().length;
      expect(count, greaterThan(0), reason: 'the trackers are listed with a Connect button each');
      for (var i = 0; i < count; i++) {
        await Bed.dpadMode(t);
        final button = find.ancestor(of: connects.at(i), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SmallButton')).first;
        await Bed.focus(t, button);
        final from = FocusManager.instance.primaryFocus!;
        await Bed.ok(t);
        await Bed.settle(t, rounds: 4);
        expect(t.takeException(), isNull);
        if (_inBox()) {
          boxes++;
          expect(Bed.focused(), isNot('nothing'), reason: 'something in the box has focus');
          for (final arrow in [Bed.down, Bed.right, Bed.up, Bed.left]) {
            await arrow(t, times: 2);
            expect(_inBox(), isTrue, reason: 'arrows stay in the box');
          }
          for (var b = 0; b < 3 && _inBox(); b++) {
            await Bed.back(t);
            await Bed.settle(t, rounds: 2);
          }
          expect(_inBox(), isFalse, reason: 'Back closes the box');
          // (the sign-in listens on this machine for the browser to come back, with a real
          // socket: closing it takes a moment of real time, not of the test's clock)
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
          await Bed.settle(t, rounds: 2);
        }
        expect(from.hasPrimaryFocus, isTrue, reason: 'focus is on the Connect button that was pressed');
      }
      if (!done.isCompleted) done.complete();
    }, (e, stack) {
      if ('$e'.contains('cancelled')) {
        unheard.add(e);
      } else if (!done.isCompleted) {
        done.completeError(e, stack);
      }
    });
    await done.future;
    debugPrint('tracker boxes opened: $boxes of $count; sign-ins that ended "cancelled": ${unheard.length}');
  }, variant: screen);

  testWidgets('the subtitle font box: opens with the caret in its search, the fonts are under it, Back closes', (t) async {
    await openSettings(t, 'Subtitles');
    await Bed.dpadMode(t);
    final font = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_FontButton');
    expect(font, findsOneWidget);
    await Bed.focus(t, font);
    expect(Bed.focusInView(), isTrue);
    final from = FocusManager.instance.primaryFocus!;
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(_inBox(), isTrue);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull, reason: 'the caret is in the search field');
    await Bed.down(t, times: 3);
    expect(_inBox(), isTrue);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNull, reason: 'Down leaves the field for the list of fonts');
    await Bed.back(t);
    if (_inBox()) await Bed.back(t);
    expect(_inBox(), isFalse);
    expect(from.hasPrimaryFocus, isTrue, reason: 'focus is back on the font button');
  }, variant: screen);

  testWidgets('the avatar picker opens over settings, keeps the arrows, and Back closes it', (t) async {
    await openProfile(t);
    await Bed.dpadMode(t);
    showAvatarPicker(t.element(find.byType(ProfilePage))).ignore();
    await Bed.settle(t, rounds: 5);
    expect(_inBox(), isTrue);
    expect(Bed.focused(), isNot('nothing'), reason: 'something in the picker has focus');
    for (final press in [Bed.down, Bed.right, Bed.down, Bed.left, Bed.up, Bed.up, Bed.right]) {
      await press(t, times: 3);
      expect(_inBox(), isTrue, reason: 'arrows stay in the picker');
      expect(Bed.focused(), isNot('nothing'));
    }
    await Bed.back(t);
    if (_inBox()) await Bed.back(t);
    expect(_inBox(), isFalse, reason: 'Back closes it (after stepping off its search box, if focus was there)');
    expect(find.byType(ProfilePage), findsOneWidget);
  }, variant: screen);
}
