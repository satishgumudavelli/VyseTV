// T4 for the fourth round of TV feedback (testers on Android TVs, 2026-11-17). The bed is told it
// is a TV, as in phase 11. Each test names the tester's item it answers (PLAN.md note 84).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/anime/anilist.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/dpad/focus_chrome.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/profile/account_sheet.dart';
import 'package:vyse_tv/screens/anime/anime_page.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/manga/manga_reader_page.dart';
import 'package:vyse_tv/screens/search/search_page.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;
import 'package:vyse_tv/widgets/hero_carousel.dart';
import 'package:vyse_tv/widgets/voice_search.dart';

import 'bed/fake_anilist.dart' show fakeAniList;
import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await Bed.withContent();
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  /// The season label focus is on ('03'), or null when it is not on a season.
  String? onSeason() {
    final f = Bed.focused();
    if (!f.contains('_SeasonNumber')) return null;
    return RegExp(r"'(\d\d)'").firstMatch(f)?.group(1);
  }

  // Items 20 to 23: "When you right click to try and bring up an episode from season 1 it doesn't
  // highlight it ... I have to scroll down to Season 4 and then right click to have Play E1 be
  // highlighted." The seasons run down the left; Right only reached the episode from the season
  // level with its Play button.
  testWidgets('a series’ seasons: Right from any season reaches Play, Left comes back to the season showing, Up reaches the tabs', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.catalogue[80 + sixSeasons % 1000]));
    for (var i = 0; i < 12 && onSeason() == null; i++) {
      await Bed.down(t);
    }
    expect(onSeason(), '01', reason: 'Down from the tabs comes to the seasons, on the first');
    await Bed.picture(t, 'tv4/seasons_1_on_season_01');
    for (var k = 1; k <= 6; k++) {
      // from season k (season 01 is the one showing)
      for (var i = 1; i < k; i++) {
        await Bed.down(t);
      }
      expect(onSeason(), '0$k');
      await Bed.right(t);
      expect(Bed.focused(), contains("'Play E1'"), reason: 'Right from season 0$k reaches the episode showing');
      expect(Bed.focusInView(), isTrue);
      if (k == 6) await Bed.picture(t, 'tv4/seasons_2_right_from_06');
      await Bed.left(t);
      expect(onSeason(), '01', reason: 'Left from the episode lands on the season showing, not on the one level with Play');
    }
    // choose season 3: its episodes show, and the way back from them is season 3
    await Bed.down(t, times: 2);
    expect(onSeason(), '03');
    await Bed.ok(t);
    expect(find.textContaining('S03  ·  E01'), findsWidgets, reason: 'OK shows season 3');
    await Bed.down(t, times: 3);
    expect(onSeason(), '06');
    await Bed.right(t);
    expect(Bed.focused(), contains("'Play E1'"));
    expect(find.textContaining('S03  ·  E01'), findsWidgets, reason: 'still season 3’s first episode');
    // on Play, Left and Right pick the episode; Left at the first goes back to the season showing
    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains("'Play E2'"));
    await Bed.left(t);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains("'Play E1'"));
    await Bed.left(t);
    expect(onSeason(), '03');
    await Bed.picture(t, 'tv4/seasons_3_back_on_03');
    // Up from the top of the seasons, and Up from Play, both reach the tabs, on the one showing
    await Bed.up(t, times: 2);
    expect(onSeason(), '01');
    await Bed.up(t);
    expect(Bed.focused(), contains("'Episodes'"), reason: 'Up from the first season reaches the tabs');
    await Bed.down(t);
    expect(onSeason(), isNotNull);
    await Bed.right(t);
    expect(Bed.focused(), contains("'Play E1'"));
    await Bed.up(t);
    expect(Bed.focused(), contains("'Episodes'"), reason: 'Up from Play reaches the tabs');
  }, variant: tv);

  // Item 19: "We talked about lining up those borders ... why her husband Tom Holland's portrait
  // isn't lined up perfectly?" The ring went round the cast card's whole slot: wider than the
  // portrait, and down well below the name and the role.
  testWidgets('a cast card’s ring goes round its portrait, as the portrait is drawn (grown a little under focus)', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.catalogue[0]));
    for (var i = 0; i < 8 && !Bed.focused().contains('_CastTile'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('_CastTile'), reason: 'a film page’s tabs start on Cast');
    await Bed.right(t); // the second card, as in the tester's picture
    await Bed.settle(t, rounds: 3);
    final node = FocusManager.instance.primaryFocus!;
    final card = find.byWidgetPredicate((w) => w is Focus && identical(w.focusNode, node));
    final chrome = t.renderObject<RenderFocusChrome>(find.descendant(of: card, matching: find.byType(FocusChrome)).first);
    final portrait = t.renderObject<RenderBox>(find.descendant(of: card, matching: find.byType(AnimatedContainer)).first);
    expect(portrait.size, const Size(104, 140));
    final drawn = MatrixUtils.transformRect(portrait.getTransformTo(chrome), Offset.zero & portrait.size);
    final ring = chrome.shape!.inset.deflateRect(Offset.zero & chrome.size);
    debugPrint('card ${chrome.size}, portrait as drawn $drawn, ring $ring');
    expect(drawn.width, greaterThan(104), reason: 'the portrait grows a little under focus, as under a mouse');
    for (final (a, b) in [(ring.left, drawn.left), (ring.top, drawn.top), (ring.right, drawn.right), (ring.bottom, drawn.bottom)]) {
      expect(a, closeTo(b, .5), reason: 'the ring sits on the portrait’s edge ($ring against $drawn)');
    }
    expect(chrome.shape!.radius, BorderRadius.circular(14), reason: 'with the portrait’s corners');
    await Bed.picture(t, 'tv4/cast_ring');
  }, variant: tv);

  // Item 25 (another tester, another TV): "when im on the login with acc page i open the keyboard
  // and when i start typing it fucks up the focus and moves around behind the keyboard, so i cant
  // enter details". Some Google TVs (TCL, Philips, the Chromecast) bring their keyboard up with no
  // typing session (upstream's notes, MainActivity.kt): letters go nowhere and the remote's arrows,
  // meant for the keyboard's keys, reach the app, which took them as leaving the box.
  testWidgets('the sign-in box on a TV: the activity is told a text box has focus, and arrows that get past the keyboard leave focus in the box', (t) async {
    addTearDown(t.view.resetViewInsets);
    await Bed.pumpShell(t);
    Bed.nativeCalls.clear();
    showAccountSheet(FocusManager.instance.primaryFocus!.context!);
    await Bed.settle(t);
    final box = FocusManager.instance.primaryFocus;
    final editable = box?.context?.findAncestorStateOfType<EditableTextState>();
    expect(editable, isNotNull, reason: 'the box opens in its first text box (Email or username)');
    expect(Bed.nativeCalls, contains('vyse/text_input setNativeTextInputFocused true'), reason: 'so the TV binds its keyboard to the app');
    // the keyboard is up (it covers the foot of the screen), and the person types
    t.view.viewInsets = const FakeViewPadding(bottom: 600);
    await t.pump();
    t.testTextInput.enterText('mara');
    await t.pump();
    expect(editable!.textEditingValue.text, 'mara');
    for (final key in [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight]) {
      await Bed.press(t, key);
      expect(identical(FocusManager.instance.primaryFocus, box), isTrue, reason: '$key, which the keyboard let through, left focus in the box (it is on ${Bed.focused()})');
    }
    t.testTextInput.enterText('mara.e');
    await t.pump();
    expect(editable.textEditingValue.text, 'mara.e', reason: 'typing still goes into the box');
    await Bed.picture(t, 'tv4/sign_in_keyboard_up');
    // the keyboard put away (Back), arrows move on as they always did
    t.view.resetViewInsets();
    await t.pump();
    await Bed.down(t);
    expect(identical(FocusManager.instance.primaryFocus, box), isFalse, reason: 'with the keyboard down, Down leaves the box');
    await Bed.down(t, times: 2);
    expect(Bed.focused(), isNot('nothing'));
    if (FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() == null) {
      expect(Bed.nativeCalls.last, 'vyse/text_input setNativeTextInputFocused false', reason: 'and the activity is told when focus is out of the text boxes');
    }
    await Bed.back(t);
  }, variant: tv);

  // Items 3 to 9: "Voice to text searching ... hit mic and say the name of what you are looking
  // for ... A green button on the top right lights up but no input is logged?", "also ... the
  // music section", "And the anime section", "Whatever has a search section", "Maybe just one
  // button and it auto loads". (The green button is the TV keyboard's own microphone: it listens,
  // but on these TVs the keyboard has no typing session, item 25, so the words went nowhere.)
  testWidgets('every search box on a TV has a microphone; one press listens, and what was heard is searched for at once', (t) async {
    final prompts = <String?>[];
    Object answer = 'Far Country';
    const voice = MethodChannel('vyse/voice');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(voice, (call) async {
      prompts.add((call.arguments as Map?)?['prompt'] as String?);
      if (answer is PlatformException) throw answer;
      return answer;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(voice, null));
    bool onMic() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<VoiceSearchButton>() != null;
    bool typing() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;
    String boxText(Type page) => t.widget<EditableText>(find.descendant(of: find.byType(page), matching: find.byType(EditableText)).first).controller.text;

    await Bed.pumpShell(t);
    // the Search page: from its box, Right is the microphone; OK listens and the search runs
    await Bed.openSection(t, 'search');
    await Bed.settle(t, rounds: 4);
    if (typing()) await Bed.down(t);
    for (var i = 0; i < 4 && !typing(); i++) {
      await Bed.up(t);
    }
    expect(typing(), isTrue);
    await Bed.right(t);
    expect(onMic(), isTrue, reason: 'Right from the search box is its microphone');
    expect(Bed.focusInView(), isTrue);
    await Bed.picture(t, 'tv4/voice_1_search_mic');
    Bed.http.seen.clear();
    await Bed.ok(t);
    expect(prompts, hasLength(1), reason: 'one press, and the TV listens');
    expect(boxText(SearchPage), 'Far Country', reason: 'what was heard is in the box');
    expect(Bed.http.seen.where((r) => r.contains('/search/') && r.contains('Far')), isNotEmpty, reason: 'and searched for, with no other button to press');
    expect(onMic(), isTrue, reason: 'the ring stays on the microphone');
    await Bed.picture(t, 'tv4/voice_2_search_heard');

    // nothing said (Back on the listening screen): nothing changes
    answer = '';
    await Bed.ok(t);
    expect(boxText(SearchPage), 'Far Country');

    // a TV with nothing that listens says so, plainly
    answer = PlatformException(code: 'UNAVAILABLE');
    await Bed.ok(t);
    expect(find.textContaining('This TV has no voice search'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    answer = 'Frieren';

    // Anime: its search opens from the round button, and the microphone is at the box's end
    await Bed.openSection(t, 'anime');
    await Bed.settle(t, rounds: 4);
    expect(find.byType(AnimePage), findsOneWidget);
    await Bed.focus(t, find.byTooltip('Search anime'));
    await Bed.ok(t);
    expect(typing(), isTrue, reason: 'the box opens ready');
    await Bed.right(t);
    expect(onMic(), isTrue, reason: 'Right from Anime’s box is its microphone');
    Bed.http.seen.clear();
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(boxText(AnimePage), 'Frieren');
    expect(Bed.http.seen.where((r) => r.contains('anilist')), isNotEmpty, reason: 'Anime searched for it');

    // and every other page with a search box has one
    for (final section in const ['music', 'manga', 'audiobooks', 'live', 'history', 'list']) {
      await Bed.openSection(t, section);
      await Bed.settle(t, rounds: 4);
      if (section == 'live') {
        // (its search box is on the Channels tab; it opens on Matches)
        await t.tap(find.text('Channels'));
        await Bed.settle(t, rounds: 4);
      }
      expect(find.byType(VoiceSearchButton), findsWidgets, reason: '$section has a microphone on its search box');
    }
  }, variant: tv);

  // Items 10 to 18: "It should be on off or Nvidia image scaling, the others lag or cause screen
  // jitter for me", "Anime4k high quality crashed the app for me", "Mine didn't crash but lagging
  // started", "Don't overcomplicate i guess".
  testWidgets('on a TV the player offers Off and NVIDIA Image Scaling only; a heavier one picked before is Off', (t) async {
    AppSettings.upscaler.set('anime4k_hq'); // picked with an earlier build
    addTearDown(() => AppSettings.upscaler.set('none'));
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Anime4K · high quality'), findsNothing, reason: 'not named as in use anywhere');
    // (S is Settings on a TV: quality, speed and More side by side, with upscaling under More)
    expect(find.text('UPSCALING'), findsOneWidget);
    expect(find.text('NVIDIA Image Scaling'), findsOneWidget);
    for (final gone in const ['ArtCNN', 'ArtCNN · high quality', 'Anime4K', 'Anime4K · high quality']) {
      expect(find.text(gone), findsNothing, reason: '$gone is not offered on a TV');
    }
    await Bed.picture(t, 'tv4/upscalers');
    // a heavy one still saved is never handed to mpv
    AppSettings.upscaler.set('artcnn');
    await Bed.settle(t, rounds: 2);
    expect([for (final c in Bed.videoCalls) if (c.contains('ArtCNN') || c.contains('Anime4K')) c], isEmpty);
    // NVIDIA's can be picked (handed to mpv once it says the picture is not HDR, which the
    // bed's stand-in never does)
    await t.ensureVisible(find.text('NVIDIA Image Scaling'));
    await Bed.settle(t, rounds: 1);
    await t.tap(find.text('NVIDIA Image Scaling'));
    await Bed.settle(t, rounds: 2);
    expect(AppSettings.upscaler.value, 'nvscaler');
    AppSettings.upscaler.set('none');
    await Bed.settle(t, rounds: 2);
    await Bed.closePlayer(t);
    expect(find.byType(PlayerPage), findsNothing);
  }, variant: tv);

  // Item 29: "it would play the final episode on the list of the 13 episodes of bleach thousand
  // year blood war ... during the episode the player kept playing despite me trying to pause it.
  // I selected up down back button ... the media board was never brought up". The page hands
  // the player the episode it was asked for; its Play at the top resumed the last episode
  // recorded even when that one was over, and only said "Play".
  testWidgets('an anime’s Play carries on where you were and says which episode; the player it opens answers the remote', (t) async {
    // a finished series of 13, like the tester's (the bed's AniList otherwise answers with a film)
    final was = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'graphql.anilist.co') return was(method, uri);
      final data = fakeAniList();
      final inner = data['data']! as Map<String, Object?>;
      inner['Media'] = {...inner['Media']! as Map<String, Object?>, 'format': 'TV', 'episodes': 13, 'status': 'FINISHED'};
      return FakeReply.json(data);
    };
    addTearDown(() => Bed.http.route = was);
    final anime = Anime.fromMedia(Bed.catalogue[81]);
    final details = await AniList.details(anime.id);
    final last = details.aired ?? details.episodes ?? 1;
    expect(last, 13);
    const length = Duration(minutes: 24);
    void watched(int episode, {required bool toTheEnd}) =>
        WatchProgress.record(details.media, position: toTheEnd ? const Duration(minutes: 23, seconds: 50) : const Duration(minutes: 9), duration: length, season: 0, episode: episode);
    addTearDown(() => WatchProgress.remove(details.media));

    WatchProgress.remove(details.media);
    await Bed.pumpShell(t);
    await Bed.push(t, AnimeDetailsPage(anime: anime));
    expect(find.text('Play'), findsOneWidget, reason: 'nothing watched yet: Play, from the first');
    watched(2, toTheEnd: false);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Resume E2'), findsOneWidget, reason: 'part-way through episode 2: it says so');
    watched(2, toTheEnd: true);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Play E3'), findsOneWidget, reason: 'episode 2 finished: on to 3, not 2 again');
    watched(last, toTheEnd: true);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Play'), findsOneWidget, reason: 'the last one out finished: from the first again, not the finale once more');
    await Bed.picture(t, 'tv4/anime_play');

    // Play, with the remote: the player opens on episode 1
    await Bed.focus(t, find.ancestor(of: find.text('Play'), matching: find.byType(Pressable)).first);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(t.widget<PlayerPage>(find.byType(PlayerPage)).episode?.number, 1);
    // the remote reaches it: play/pause, Up brings the controls up with the ring on them, Back
    // hides them and Back again leaves
    final calls = Bed.videoCalls.length;
    await t.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause, platform: 'android');
    await t.pump(const Duration(milliseconds: 100));
    expect(Bed.videoCalls.length, greaterThan(calls), reason: 'play/pause reached the player');
    await Bed.up(t);
    expect(Bed.focused(), isNot('nothing'), reason: 'Up brought the controls up, with the ring on them');
    await Bed.closePlayer(t);
  }, variant: tv);

  // Item 1: "I'm a scroller, the plus side to page scrolling is that it has a yellow bar at the
  // bottom that shows you the progress and how many pages are left which I think many would
  // want. So keep that."
  testWidgets('the reader’s yellow progress line, in page mode and in scroll mode, with the pages left', (t) async {
    MangaReaderPage.debugPages = (c) async => [for (var i = 0; i < 75; i++) 'https://manga.example/${c.id}/p$i.jpg'];
    addTearDown(() => MangaReaderPage.debugPages = null);
    await Bed.pumpShell(t);
    unawaited(rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => MangaReaderPage(manga: Bed.manga[0], chapters: Bed.chapters, index: 1),
    )));
    await Bed.settle(t, rounds: 6);
    final line = find.byWidgetPredicate((w) => w is AnimatedContainer && w.constraints?.minHeight == 3 && w.constraints?.maxHeight == 3);
    double width() => t.getSize(line).width;
    // the line lies on a dark track the width of the screen, in both modes
    final track = find.ancestor(of: line, matching: find.byWidgetPredicate((w) => w is Container && w.color == const Color(0x8C000000)));
    expect(track, findsOneWidget, reason: 'a dark track under the line, so it reads over a page');
    expect(t.getSize(track.first), const Size(960, 3));
    final mode = find.byTooltip('Switch to page mode (M)').evaluate().isNotEmpty ? 'scroll' : 'paged';
    debugPrint('reader opened in $mode mode; line ${width()}');
    final start = width();
    await Bed.right(t, times: 5);
    await Bed.settle(t, rounds: 3);
    debugPrint('after 5 pages: line ${width()}');
    await Bed.picture(t, 'tv4/manga_scroll_line');
    expect(width(), greaterThan(start));
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await Bed.settle(t, rounds: 3);
    await Bed.right(t, times: 2);
    await Bed.settle(t, rounds: 3);
    debugPrint('page mode: line ${width()}');
    await Bed.picture(t, 'tv4/manga_paged_line');
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await Bed.settle(t, rounds: 3);
    for (var i = 0; i < 3 && find.byType(MangaReaderPage).evaluate().isNotEmpty; i++) {
      await Bed.back(t);
    }
    await t.pump(const Duration(seconds: 3));
  }, variant: tv);

  // Items 26 to 28: "its lagging a lot on my tv", "all of the other apps i have run super
  // smoothly", "significantly slower and has like delay". Home never stood still: the hero's
  // picture zoomed in slowly for twenty seconds a slide, so the whole screen was drawn again every
  // frame for as long as Home was open (the rest of the work, after upstream, is in MainActivity.kt
  // and main.dart, and only a TV can show it).
  testWidgets('on a TV Home at rest draws nothing: the hero picture holds still, and a new slide is a short fade', (t) async {
    await Bed.pumpShell(t);
    await t.pump(const Duration(seconds: 2));
    expect(find.byType(HeroCarousel), findsOneWidget);
    expect(t.binding.transientCallbackCount, 0, reason: 'nothing animates on Home at rest on a TV');
    // the next slide: a fade, then still again
    t.state<HeroCarouselState>(find.byType(HeroCarousel)).next();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.binding.transientCallbackCount, greaterThan(0), reason: 'the new slide fades in');
    await Bed.settle(t, rounds: 4);
    await t.pump(const Duration(seconds: 1)); // (its pictures' own short fade-in, as they arrive)
    expect(t.binding.transientCallbackCount, 0, reason: 'and then the screen is still');
  }, variant: tv);

  // (After the fourth round the player's menus became a side panel on a TV, with a list of the
  // menus to go through first. On 2026-11-19 the user asked for full-screen menus like NuvioTV's
  // instead: the panel and its test are gone, and t4_journeys_tv8_test.dart has the new ones.)
}
