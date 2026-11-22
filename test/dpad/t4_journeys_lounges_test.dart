// T4 for lounges (public chat rooms in Party) on an Android TV and a phone: the remote's arrows,
// OK and Back only. The server is made up (bed/fake_lounges.dart). Pictures of each step go to
// docs/dpad/pictures/lounges, to look at.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/screens/party/chat_view.dart';
import 'package:vyse_tv/screens/party/lounge_page.dart';
import 'package:vyse_tv/screens/party/lounges_view.dart';
import 'package:vyse_tv/screens/party/party_page.dart';

import 'bed/fake_lounges.dart';
import 'bed/phase9_pages.dart';
import 'harness.dart';

bool _inBox() => FocusManager.instance.primaryFocus?.nearestScope?.debugLabel?.contains('Modal') ?? false;
bool _typing() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
String? _tip() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<IconButton>()?.tooltip;
bool _onMessage() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<PartyChatList>() != null;

late FakeLounges server;

Future<void> _party(WidgetTester t) async {
  signIn();
  server = FakeLounges()..install();
  await Bed.pumpShell(t);
  await Bed.openSection(t, 'party');
  await Bed.settle(t, rounds: 5);
  expect(find.byType(PartyPage), findsOneWidget);
  await Bed.dpadMode(t);
}

void _done() {
  FakeLounges.uninstall();
  signOut();
}

/// Arrows (Down, then Up) until [ok] holds; false if it never does.
Future<bool> _walk(WidgetTester t, bool Function() ok, {int tries = 14}) async {
  for (var i = 0; i < tries && !ok(); i++) {
    await Bed.down(t);
  }
  for (var i = 0; i < tries * 2 && !ok(); i++) {
    await Bed.up(t);
  }
  return ok();
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  final screens = OnScreens(Screens.android);

  testWidgets('Lounges: OK on a lounge opens it; a reply to you is lit; Reply from a message\'s menu sends what it answers; Back returns to the lounge', (t) async {
    addTearDown(_done);
    final problems = await Bed.overflows(() async {
      await _party(t);
      await Bed.picture(t, 'lounges/1-party');
      final general = find.widgetWithText(LoungeRow, 'General');
      expect(general, findsOneWidget, reason: 'the official lounges are listed in Party');
      await Bed.focus(t, general);
      expect(Bed.focusInView(), isTrue);
      final row = FocusManager.instance.primaryFocus!;
      await Bed.ok(t);
      await Bed.settle(t, rounds: 5);
      expect(find.byType(LoungePage), findsOneWidget);
      expect(find.text('Anyone else watching Severance this week?'), findsOneWidget, reason: 'with a seat, the messages are there');
      final lit = find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == replyGlow);
      expect(lit, findsOneWidget, reason: 'the reply to you is highlighted');
      await Bed.picture(t, 'lounges/2-general');

      expect(await _walk(t, _onMessage), isTrue, reason: 'the messages are D-pad stops');
      await Bed.picture(t, 'lounges/2b-on-a-message');
      expect(Bed.focusInView(), isTrue, reason: 'the message with focus is in view (${Bed.focused()})');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(_inBox(), isTrue, reason: 'OK on a message opens its menu');
      expect(find.text('Reply'), findsOneWidget);
      await Bed.picture(t, 'lounges/3-menu');
      // Reply is the first line of the menu
      for (var i = 0; i < 6 && !Bed.focused().contains('Reply'); i++) {
        await Bed.up(t);
      }
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(_inBox(), isFalse);
      expect(find.byType(ReplyBar), findsOneWidget, reason: 'the box says what it answers');
      expect(_typing(), isTrue, reason: 'and has the caret (focus: ${Bed.focused()}, ${FocusManager.instance.primaryFocus})');
      await Bed.picture(t, 'lounges/4-replying');

      final box = find.descendant(of: find.byType(PartyChatInput), matching: find.byType(TextField));
      await t.enterText(box, 'Same here');
      await Bed.press(t, LogicalKeyboardKey.enter);
      await Bed.settle(t, rounds: 3);
      expect(server.sent, hasLength(1));
      expect(server.sent.single['replyTo'], isNotNull, reason: 'the reply goes with the message it answers');
      expect(find.text('Same here'), findsOneWidget);
      expect(find.byType(ReplyBar), findsNothing, reason: 'sent: the box is plain again');
      expect(find.byType(ChatQuoteView), findsNWidgets(3), reason: 'the new reply shows what it answers');
      await Bed.picture(t, 'lounges/5-sent');

      for (var i = 0; i < 3 && find.byType(LoungePage).evaluate().isNotEmpty; i++) {
        await Bed.back(t);
      }
      expect(find.byType(LoungePage), findsNothing, reason: 'Back leaves the lounge');
      expect(row.hasPrimaryFocus, isTrue, reason: 'R6: back on the lounge you opened');
    });
    expect(problems, isEmpty);
  }, variant: screens);

  testWidgets('Lounges: without a seat a lounge shows Take a seat, OK takes one and the chat opens; a full one says so', (t) async {
    addTearDown(_done);
    final problems = await Bed.overflows(() async {
      await _party(t);
      await Bed.focus(t, find.widgetWithText(LoungeRow, 'Films & Series'));
      await Bed.ok(t);
      await Bed.settle(t, rounds: 5);
      expect(find.text('Take a seat'), findsOneWidget);
      expect(find.byType(PartyChatList), findsNothing, reason: 'no seat, no messages');
      await Bed.picture(t, 'lounges/6-preview');
      expect(await _walk(t, () => Bed.focused().contains('Take a seat') || Bed.focused().contains('FilledButton')), isTrue,
          reason: 'Take a seat is reachable (focus: ${Bed.focused()})');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 5);
      expect(server.seats['films'], 'member');
      expect(find.byType(PartyChatList), findsOneWidget, reason: 'with a seat the chat opens');
      await Bed.picture(t, 'lounges/7-joined');
      await Bed.back(t);
      await Bed.back(t);
      expect(find.byType(LoungePage), findsNothing);

      await Bed.focus(t, find.widgetWithText(LoungeRow, 'Anime'));
      await Bed.ok(t);
      await Bed.settle(t, rounds: 5);
      expect(find.textContaining('Full'), findsOneWidget, reason: 'a full lounge says so instead of offering a seat');
      expect(find.text('Take a seat'), findsNothing);
      expect(Bed.focused(), isNot('nothing'), reason: 'something still has focus (Back, More)');
      await Bed.picture(t, 'lounges/8-full');
    });
    expect(problems, isEmpty);
  }, variant: screens);

  testWidgets('Lounges: Find lounges lists them; the cards are stops; OK opens one; Make a lounge is a box that keeps the arrows', (t) async {
    addTearDown(_done);
    final problems = await Bed.overflows(() async {
      await _party(t);
      // up from the first lounge to the list's buttons, then along them
      await Bed.focus(t, find.widgetWithText(LoungeRow, 'General'));
      await Bed.up(t);
      for (var i = 0; i < 3 && _tip() != 'Find lounges'; i++) {
        await Bed.left(t);
      }
      expect(_tip(), 'Find lounges', reason: 'Find lounges is reachable with the arrows (focus: ${Bed.focused()})');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 5);
      expect(find.byType(LoungesPage), findsOneWidget);
      expect(find.widgetWithText(LoungeCard, 'JRPG nights'), findsOneWidget);
      await Bed.picture(t, 'lounges/9-find');
      expect(await _walk(t, () => Bed.focused().contains('LoungeCard'), tries: 20), isTrue, reason: 'the cards are D-pad stops');
      expect(Bed.focusInView(), isTrue);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 5);
      expect(find.byType(LoungePage), findsOneWidget);
      await Bed.back(t);
      expect(find.byType(LoungesPage), findsOneWidget);

      showMakeLoungeDialog(Bed.sectionNavigator(t).context).ignore();
      await Bed.settle(t, rounds: 4);
      expect(_inBox(), isTrue);
      await Bed.picture(t, 'lounges/10-make');
      for (final arrow in [Bed.down, Bed.down, Bed.right, Bed.up, Bed.left]) {
        await arrow(t, times: 2);
        expect(_inBox(), isTrue, reason: 'arrows stay in the box');
      }
      for (var i = 0; i < 3 && _inBox(); i++) {
        await Bed.back(t);
      }
      expect(_inBox(), isFalse);
      expect(Bed.focused(), isNot('nothing'));
    });
    expect(problems, isEmpty);
  }, variant: screens);

  testWidgets('Lounges: a message arriving live joins the chat without taking focus', (t) async {
    addTearDown(_done);
    await _party(t);
    await Bed.focus(t, find.widgetWithText(LoungeRow, 'Horror club'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 5);
    expect(await _walk(t, _onMessage), isTrue);
    final on = FocusManager.instance.primaryFocus!;
    server.live!({
      'lounge': 'horror',
      'type': 'message',
      'message': {'id': 'h2', 'lounge': 'horror', 'user': 'u2', 'name': 'Tobias Reed', 'body': 'Count me in', 'created': DateTime(2026, 11, 20, 21).toUtc().toIso8601String()},
    });
    await Bed.settle(t, rounds: 3);
    expect(find.text('Count me in'), findsOneWidget);
    expect(on.hasPrimaryFocus, isTrue, reason: 'reading stays where it was');
  }, variant: screens);
}
