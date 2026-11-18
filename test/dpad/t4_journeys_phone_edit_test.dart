// Edit on your phone, on a TV: Settings shows a QR code, a phone changes settings through the
// account server, and the TV applies them at once. The server is FakeRelay (bed/fake_relay.dart,
// the same rules as the real one); the phone is FakePhone, which does what the phone page does.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/phone_edit/phone_code.dart';
import 'package:vyse_tv/data/phone_edit/phone_session.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;

import 'bed/fake_relay.dart';
import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openProfile;
import 'harness.dart';

final relay = FakeRelay();

/// The code the TV is showing.
String shownCode(WidgetTester t) {
  final code = find.byWidgetPredicate((w) => w is Text && RegExp(r'^[0-9A-Z]{4}(-[0-9A-Z]{4}){3}$').hasMatch(w.data ?? ''));
  expect(code, findsOneWidget, reason: 'the code shows under the QR code');
  return (t.widget<Text>(code).data!).replaceAll('-', '');
}

/// Lets the TV ask the server a few times.
Future<void> ticks(WidgetTester t, [int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(seconds: 1));
  }
}

Future<void> openPhoneEdit(WidgetTester t) async {
  await openProfile(t);
  await pressOn(t, find.widgetWithText(Pressable, 'Edit on your phone').first);
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
    PhoneSession.testFactory = () => PhoneSession(server: 'https://relay.test', client: relay.client, random: Random(7));
  });
  tearDownAll(() => PhoneSession.testFactory = null);
  final tv = OnScreens([Screens.tv]);

  test('the code and its key are the ones the phone page works out with WebCrypto', () {
    // Made in a browser with the page's own code (crypto.subtle): a box the TV must open.
    final code = PhoneCode.of('0123456789ABCDEF');
    expect(code.id, '409b3f756921c36aa8ed6b2e3d914c943d9bc94c999993ac13cd9ccaa42c62cc');
    expect(code.open('change', 'AQIDBAUGBwgJCgsM.Iy3PEfK4-oU0wdn2z6HXWRc1brdVr5XF73lmeZCG546z51F7mY5Hsw4'), {'id': 'subs.size', 'v': 30});
    expect(() => code.open('state', 'AQIDBAUGBwgJCgsM.Iy3PEfK4-oU0wdn2z6HXWRc1brdVr5XF73lmeZCG546z51F7mY5Hsw4'), throwsA(anything), reason: 'a box only opens as the kind it was sealed as');
    expect(() => PhoneCode.of('0123456789ABCDEG').open('change', 'AQIDBAUGBwgJCgsM.Iy3PEfK4-oU0wdn2z6HXWRc1brdVr5XF73lmeZCG546z51F7mY5Hsw4'), throwsA(anything), reason: 'and only with its own code');
    expect(PhoneCode.parse('o123-4567-89ab-cdef')?.code, '0123456789ABCDEF', reason: 'typed codes: case, dashes and O for 0 do not matter');
    expect(PhoneCode.parse('0123-4567-89AB-CDEU'), isNull, reason: 'U is not in the alphabet');
  });

  testWidgets('Settings on a TV: Edit on your phone shows a code, and what the phone changes applies here at once', (t) async {
    final size = AppSettings.subtitleSize.value;
    final bold = AppSettings.subtitleBold.value;
    await openPhoneEdit(t);
    expect(find.byType(QrImageView), findsOneWidget, reason: 'a QR code for the camera');
    expect(Bed.focused(), contains('Close'), reason: 'the remote lands on Close');
    expect(find.text('Waiting for your phone'), findsOneWidget);
    final code = shownCode(t);
    final qr = t.widget<QrImageView>(find.byType(QrImageView));
    expect(qr, isNotNull);

    final phone = FakePhone(relay, code);
    expect(await phone.poll(), isTrue, reason: 'the phone finds the session from the code alone');
    expect(phone.item('subs.size')['value'], size, reason: 'and reads the settings the TV sealed for it');
    await ticks(t, 2);
    expect(find.textContaining('Your phone is connected'), findsOneWidget);

    final seq = await phone.send({'id': 'subs.size', 'v': size + 2});
    await ticks(t, 2);
    expect(AppSettings.subtitleSize.value, size + 2, reason: 'the change applies on the TV');
    expect(find.text('Last change: Text size: ${size + 2}'), findsOneWidget, reason: 'and the TV says what changed');
    // The box grew by those lines and Close moved down with it, with no scroll and no move of
    // focus: the ring goes with it (it stayed where Close had been, before the kit looked after
    // each frame).
    final ring = DpadRoot.debugRingRect;
    final close = t.getRect(find.widgetWithText(TextButton, 'Close'));
    expect(ring, isNotNull);
    expect((ring!.center - close.center).distance, lessThan(2), reason: 'the ring is on Close ($ring, Close at $close)');
    await phone.poll();
    expect(phone.acked, greaterThanOrEqualTo(seq));
    expect(phone.item('subs.size')['value'], size + 2, reason: 'the phone hears back');

    // a change made on the TV reaches the phone too
    AppSettings.subtitleBold.set(!bold);
    await ticks(t, 2);
    await phone.poll();
    expect(phone.item('subs.bold')['value'], !bold);

    // what the TV doesn't offer changes nothing
    await phone.send({'id': 'subs.size', 'v': 999});
    await phone.send({'id': 'device.update.skipped', 'v': '9.9.9'});
    await ticks(t, 2);
    expect(AppSettings.subtitleSize.value, size + 2);
    expect(AppSettings.updateSkipped.value, isNot('9.9.9'));

    await Bed.back(t);
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(QrImageView), findsNothing, reason: 'Back closes it');
    expect(await phone.poll(), isFalse, reason: 'and the code ends for the phone');
    AppSettings.subtitleSize.set(size);
    AppSettings.subtitleBold.set(bold);
  }, variant: tv);

  testWidgets('no server to reach: it says so, and Try again makes a code once there is', (t) async {
    relay.up = false;
    await openPhoneEdit(t);
    expect(find.textContaining("Couldn't reach the VyseTV server"), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(Bed.focused(), contains('Try again'), reason: 'the remote lands on Try again');
    relay.up = true;
    await Bed.ok(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Waiting for your phone'), findsOneWidget);
    await Bed.back(t);
    await t.pump(const Duration(milliseconds: 500));
  }, variant: tv);

  testWidgets('a code nobody uses ends; New code makes another', (t) async {
    await openPhoneEdit(t);
    final first = shownCode(t);
    relay.sessions.clear(); // what the server does with a session left unused
    await ticks(t, 2);
    expect(find.textContaining('This code has ended'), findsOneWidget);
    expect(Bed.focused(), contains('New code'));
    await Bed.ok(t);
    await t.pump(const Duration(milliseconds: 300));
    expect(shownCode(t), isNot(first));
    await Bed.back(t);
    await t.pump(const Duration(milliseconds: 500));
  }, variant: tv);
}
