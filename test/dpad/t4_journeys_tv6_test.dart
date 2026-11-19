// The sixth round of feedback from testers' TVs (2026-11-19), item by item. docs/dpad/PLAN.md
// note 91 has the round.
import 'dart:ui' show PointerDeviceKind;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/live_tv/live_favorites.dart';
import 'package:vyse_tv/data/live_tv/live_tv.dart';
import 'package:vyse_tv/data/live_tv/portal_names.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/dpad/focus_chrome.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_player_page.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_widgets.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/section_chrome.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  var starred = 0;

  /// A portal's card, as Live TV > Portals draws it: the card opens the portal, and it has two
  /// buttons of its own.
  Widget portals() => Bed.app(Scaffold(
    body: Center(
      child: SizedBox(
        width: 860,
        height: 98, // (88 in the page's grid, and 5 of padding each side here)
        child: Row(
          children: [
            for (final name in const ['EELAKQP8D53GQWT', '521112044872436'])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: InfoTile(
                    title: name,
                    lines: const ['http://portal.test', 'Expires Unlimited  ·  0/1 connections'],
                    onTap: () {},
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(tooltip: 'Copy login', visualDensity: VisualDensity.compact, onPressed: () {}, icon: const Icon(Icons.copy_rounded, size: 18)),
                        IconButton(tooltip: 'Favorite', visualDensity: VisualDensity.compact, onPressed: () => starred++, icon: const Icon(Icons.star_border_rounded, size: 20)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  ));

  RenderFocusChrome chromeOf(WidgetTester t, String name) =>
      t.renderObject<RenderFocusChrome>(find.descendant(of: find.widgetWithText(InfoTile, name), matching: find.byType(FocusChrome)).first);

  /// Whether the card draws itself as under a pointer (its outline goes white).
  bool lit(WidgetTester t, String name) {
    final box = t.widget<AnimatedContainer>(find.descendant(of: find.widgetWithText(InfoTile, name), matching: find.byType(AnimatedContainer)).first);
    return ((box.foregroundDecoration! as BoxDecoration).border! as Border).top.color == Colors.white;
  }

  // "my green border is highlighted over my selection, but a white border selection shows
  // across from it like a shadow? And it hovers favorite when not hovered/selected". A remote
  // with a touchpad leaves a mouse pointer on the screen; the card under it stayed lit and
  // its button's tooltip stayed up, beside the card the remote was on.
  testWidgets('a TV: a pointer parked on the screen lights nothing up and opens no tooltip; a click still lands', (t) async {
    PlatformDetector.debugSetIsDesktopOSOverride(false); // a TV box, not the PC the tests run on
    addTearDown(() => PlatformDetector.debugSetIsDesktopOSOverride(null));
    await t.pumpWidget(portals());
    await Bed.settle(t, rounds: 2);
    await Bed.dpadMode(t);
    await Bed.focus(t, find.descendant(of: find.widgetWithText(InfoTile, '521112044872436'), matching: find.byType(Pressable)).first);

    final star = t.getCenter(find.descendant(of: find.widgetWithText(InfoTile, 'EELAKQP8D53GQWT'), matching: find.byIcon(Icons.star_border_rounded)));
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: star - const Offset(60, 0));
    await mouse.moveTo(star);
    await t.pump(const Duration(seconds: 2));
    expect(lit(t, 'EELAKQP8D53GQWT'), isFalse, reason: 'the card under the pointer is not drawn as hovered');
    expect(lit(t, '521112044872436'), isTrue, reason: 'the card the remote is on is');
    expect(find.text('Favorite'), findsNothing, reason: 'no tooltip from a parked pointer');
    expect(find.byTooltip('Favorite'), findsNWidgets(2), reason: 'the tooltip is still the button’s name, for a screen reader');
    expect(chromeOf(t, '521112044872436').shown, 1, reason: 'the ring stays where the remote put it');

    starred = 0;
    await mouse.down(star);
    await mouse.up();
    await t.pump(const Duration(milliseconds: 300));
    expect(starred, 1, reason: 'pointing and clicking still works');
    await mouse.removePointer();
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  // On a PC the arrow keys put the D-pad in charge until the mouse moves again.
  testWidgets('a PC: the control under a still mouse is not lit while the arrows are in charge, and is again when the mouse moves', (t) async {
    await t.pumpWidget(portals());
    await Bed.settle(t, rounds: 2);
    final card = t.getCenter(find.widgetWithText(InfoTile, '521112044872436')) - const Offset(120, 0);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: card - const Offset(30, 0));
    await mouse.moveTo(card);
    await t.pump(const Duration(milliseconds: 300));
    expect(lit(t, '521112044872436'), isTrue, reason: 'a mouse in charge: hover as ever');
    await Bed.dpadMode(t); // (the remote's focus lands on the first card, not this one)
    await t.pump(const Duration(milliseconds: 300));
    expect(lit(t, '521112044872436'), isFalse);
    await mouse.moveTo(card + const Offset(4, 0));
    await t.pump(const Duration(milliseconds: 300));
    expect(lit(t, '521112044872436'), isTrue);
    await mouse.removePointer();
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  // "the misborder alignments": with focus on a card's star the card kept its own ring and its
  // growth, and the star's ring was drawn where the growth had not moved the star.
  testWidgets('a card is not ringed, or grown, while focus is on a button inside it; the ring is on the button', (t) async {
    await t.pumpWidget(portals());
    await Bed.settle(t, rounds: 2);
    await Bed.dpadMode(t);
    const name = 'EELAKQP8D53GQWT';
    await Bed.focus(t, find.descendant(of: find.widgetWithText(InfoTile, name), matching: find.byType(Pressable)).first);
    expect(chromeOf(t, name).shown, 1);

    final star = find.descendant(of: find.widgetWithText(InfoTile, name), matching: find.byIcon(Icons.star_border_rounded));
    Focus.of(t.element(star)).requestFocus();
    await Bed.settle(t, rounds: 4);
    expect(chromeOf(t, name).shown, 0, reason: 'the card gives its ring up to its button');
    expect(chromeOf(t, name).isRepaintBoundary, isFalse);
    expect(lit(t, name), isTrue, reason: 'it stays lit, as it does under a pointer on one of its buttons');
    final ring = DpadRoot.debugRingRect!;
    expect((ring.center - t.getCenter(star)).distance, lessThan(1.5), reason: 'the ring is round the star: $ring');
    await Bed.picture(t, 'tv6/card_star');

    // back on the card: its ring again, and none left on the star
    await Bed.focus(t, find.descendant(of: find.widgetWithText(InfoTile, name), matching: find.byType(Pressable)).first);
    expect(chromeOf(t, name).shown, 1);
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  // "And it lags? Right?" on a playlist of 11,557 channels. The grid's columns were worked out
  // in a builder that runs again whenever the scroll offset changes, so every cell on screen
  // was built again for every frame of a scroll.
  testWidgets('a grid of channels is not built again as it scrolls, and is laid out as before', (t) async {
    var built = 0;
    final scroll = ScrollController();
    await t.pumpWidget(Bed.app(Scaffold(
      body: SizedBox(
        width: 800,
        height: 400,
        child: CustomScrollView(controller: scroll, slivers: [
          captionedGrid(
            maxWidth: 160,
            aspect: .62,
            caption: 26,
            itemCount: 400,
            itemBuilder: (context, i) {
              built++;
              return SizedBox.expand(key: ValueKey(i));
            },
          ),
        ]),
      ),
    )));
    await t.pump();
    // 800 wide, tiles of at most 160 with 12 between: five to a row, 150.4 by 150.4 * .62 + 26
    final first = t.getRect(find.byKey(const ValueKey(0))), sixth = t.getRect(find.byKey(const ValueKey(5)));
    expect(first.width, closeTo(150.4, .01));
    expect(first.height, closeTo(150.4 * .62 + 26, .01));
    expect(t.getRect(find.byKey(const ValueKey(1))).left - first.left, closeTo(162.4, .01));
    expect(sixth.left, first.left, reason: 'the sixth starts the second row');
    expect(sixth.top - first.top, closeTo(first.height + 16, .01));

    final before = built;
    for (var i = 1; i <= 6; i++) {
      scroll.jumpTo(i * 3.0);
      await t.pump();
    }
    expect(built, before, reason: 'six frames of a short scroll build no cell again');
    scroll.dispose();
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  // "It crashed when I browsed in there for an HBO channel icon". Channel logos come in any
  // size (some thousands of pixels wide) and were decoded as large as their file.
  testWidgets("a channel's logo is decoded as wide as its tile", (t) async {
    await t.pumpWidget(Bed.app(Scaffold(
      body: Center(child: SizedBox(width: 160, height: 125, child: StreamCard(name: 'HBO HD', image: 'http://portal.test/hbo.png', onTap: () {}))),
    )));
    await t.pump();
    final logo = t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(logo.memCacheWidth, isNotNull);
    expect(logo.memCacheWidth!, lessThanOrEqualTo((160 * t.view.devicePixelRatio).ceil() + 96));
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  group('favorites', () {
    const channel = LiveItem(title: '4ever Music (1080p)', subtitle: 'Buddy  ·  Music', url: 'http://list.test/4ever.m3u8', favoriteKey: 'm3u|http://list.test/4ever.m3u8');

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      LiveFavorites.debugReset();
      PortalNames.debugReset();
    });

    test('a starred channel is kept with what it takes to play it, newest first, and comes back after a restart', () async {
      await LiveFavorites.load();
      LiveFavorites.toggleChannel(const FavoriteChannel(key: 'a', title: 'One', url: 'http://x/1.ts', from: 'My portal'));
      LiveFavorites.toggleChannel(const FavoriteChannel(key: 'b', title: 'Two', url: 'http://x/2.ts', logo: 'http://x/2.png'));
      expect(LiveFavorites.saved.value.map((c) => c.title), ['Two', 'One']);
      expect(LiveFavorites.ids.value, {'a', 'b'});
      await Future<void>.delayed(Duration.zero);

      LiveFavorites.debugReset(); // the app closed and opened again
      await LiveFavorites.load();
      expect(LiveFavorites.saved.value.map((c) => (c.title, c.url, c.from, c.logo)), [('Two', 'http://x/2.ts', null, 'http://x/2.png'), ('One', 'http://x/1.ts', 'My portal', null)]);
      final item = LiveItem.favorite(LiveFavorites.saved.value.last);
      expect((item.title, item.url, item.subtitle, item.favoriteKey), ('One', 'http://x/1.ts', 'My portal', 'a'));

      LiveFavorites.toggleChannel(const FavoriteChannel(key: 'a', title: 'One', url: 'http://x/1.ts'));
      expect(LiveFavorites.saved.value.map((c) => c.title), ['Two'], reason: 'starred again: off the list');
      expect(LiveFavorites.ids.value, {'b'});
    });

    // "Live tv channels favorite option missing" ... "the star comes only when play channel
    // from portals but when from playlist no star option".
    testWidgets('the channel player has a star for a playlist\'s channel: OK stars it, OK again takes it off', (t) async {
      await Bed.pumpShell(t);
      rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => const LiveTvPlayerPage(items: [channel], index: 0)));
      await Bed.settle(t, rounds: 4);
      final add = find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Add to favorites');
      expect(add, findsOneWidget);
      await Bed.dpadMode(t);
      await Bed.focus(t, add);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect(LiveFavorites.saved.value.single.title, '4ever Music (1080p)');
      expect(LiveFavorites.saved.value.single.from, 'Buddy  ·  Music');
      final remove = find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Remove from favorites');
      expect(remove, findsOneWidget);
      await Bed.focus(t, remove);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect(LiveFavorites.saved.value, isEmpty);
      rootNavigatorKey.currentState!.pop();
      await Bed.settle(t, rounds: 4);
    }, variant: tv);

    // "IPTV favorite option as all in one place is missing" ... "favorite Live channels tab
    // will add fast jump to already marked channels".
    testWidgets('Live TV opens on Favorites when there are some: every starred channel in one list', (t) async {
      await LiveFavorites.load();
      LiveFavorites.toggleChannel(const FavoriteChannel(key: 'a', title: 'beIN Sports 1', url: 'http://x/1.ts', from: 'My portal'));
      LiveFavorites.toggleChannel(FavoriteChannel(key: channel.favoriteKey!, title: channel.title, url: channel.url, from: channel.subtitle));
      await Bed.pumpShell(t);
      await Bed.openSection(t, 'live');
      await Bed.settle(t, rounds: 4);
      expect(find.text('Favorites · 2'), findsOneWidget);
      expect(find.text('4ever Music (1080p)'), findsOneWidget);
      expect(find.text('beIN Sports 1'), findsOneWidget);
      expect(find.text('My portal'), findsOneWidget, reason: 'each says where it is from');
      await Bed.dpadMode(t);
      await Bed.picture(t, 'tv6/favorites');

      // its star takes one off the list
      final star = find.descendant(of: find.ancestor(of: find.text('beIN Sports 1'), matching: find.byType(Pressable)).first, matching: find.byIcon(Icons.star_rounded));
      await t.tap(star);
      await Bed.settle(t, rounds: 2);
      expect(find.text('beIN Sports 1'), findsNothing);
      expect(find.text('Favorites · 1'), findsOneWidget);
    }, variant: tv);

    test('a portal can be given a name of your own, and given its own back', () async {
      await PortalNames.load();
      expect(PortalNames.of('k1'), isNull);
      var changes = 0;
      void count() => changes++;
      PortalNames.changes.addListener(count);
      PortalNames.set('k1', '  Sports box  ');
      expect(PortalNames.of('k1'), 'Sports box');
      PortalNames.set('k1', 'Sports box');
      expect(changes, 1, reason: 'the same name again changes nothing');
      await Future<void>.delayed(Duration.zero);
      PortalNames.debugReset();
      await PortalNames.load();
      expect(PortalNames.of('k1'), 'Sports box', reason: 'kept for the next run');
      PortalNames.set('k1', '');
      expect(PortalNames.of('k1'), isNull);
      PortalNames.changes.removeListener(count);
    });
  });
}
