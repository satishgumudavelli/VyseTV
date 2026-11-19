// The video engine on an Android TV: Media3 unless Settings says mpv (PlayerEngine). What only
// mpv can do is out of the player's menus, Settings and the phone page while Media3 is the
// engine, and back with mpv. The tests run on a PC, so "an Android TV" is stood in for
// (PlayerEngine.debugOffered, Player.debugExoOnAnyPlatform); Media3's own channel is answered
// by the bed like mpv's (Bed.exoCalls).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/phone_edit/phone_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/subtitles/subtitle_style.dart';
import 'package:vyse_tv/mpv/mpv.dart' show Media, Player, SubtitleTrack;
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;

import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

Map<String, Map<String, Object?>> phoneItems() => {
  for (final s in phoneSections(fonts: const [SubtitleStyle.defaultFont]))
    for (final i in s.items) i.id: i.toJson(),
};

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  setUp(() {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
  });
  tearDown(() {
    PlayerEngine.debugOffered = null;
    Player.debugExoOnAnyPlatform = false;
    AppSettings.playerEngine.set('');
  });
  final tv = OnScreens([Screens.tv]);

  /// Opens one of the player's menus the way a TV does: Settings (which holds More) with S, the
  /// others from their own key on the controls.
  Future<void> openMenu(WidgetTester t, String menu) async {
    PlayerPanel panel() => t.widget<PlayerPanel>(find.byType(PlayerPanel));
    if (panel().open) await Bed.back(t);
    if (menu == 'More') {
      await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    } else {
      await Bed.down(t); // the controls
      await Bed.focus(t, find.byWidgetPredicate((w) => w is Pressable && w.tooltip == menu));
      await Bed.ok(t);
    }
    await Bed.settle(t, rounds: 3);
    expect(panel().open, isTrue);
  }

  test('nothing chosen: Media3 on an Android TV, mpv everywhere else', () {
    expect(PlayerEngine.current, PlayerEngine.media3);
    PlayerEngine.choose(PlayerEngine.mpv);
    expect(PlayerEngine.current, PlayerEngine.mpv);
    PlayerEngine.choose(PlayerEngine.media3);
    expect(PlayerEngine.isMedia3, isTrue);
    PlayerEngine.debugOffered = false; // a phone, a desktop
    expect(PlayerEngine.current, PlayerEngine.mpv, reason: 'only an Android TV has the choice');
    AppSettings.playerEngine.set('media3');
    expect(PlayerEngine.current, PlayerEngine.mpv, reason: 'whatever was saved');
  });

  testWidgets('the player on a TV is a Media3 one; ambient lighting, upscaling and the 5.1 limit are not in its menus', (t) async {
    AppSettings.upscaler.set('nvscaler'); // picked while mpv was the engine
    addTearDown(() => AppSettings.upscaler.set('none'));
    Bed.exoCalls.clear();
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    expect(Bed.exoCalls, isNotEmpty, reason: 'the player talks to Media3');
    expect(Bed.videoCalls.where((c) => c.startsWith('initialize') || c.startsWith('open')), isEmpty, reason: 'and mpv was not started');
    expect(Bed.exoCalls.where((c) => c.contains('glsl-shaders')), isEmpty, reason: 'no shader is asked of Media3');

    await openMenu(t, 'More');
    expect(find.text('Zoom'), findsOneWidget, reason: 'what Media3 can do is there');
    expect(find.text('Ambient lighting'), findsNothing);
    expect(find.text('UPSCALING'), findsNothing);
    expect(find.text('NVIDIA Image Scaling'), findsNothing, reason: 'nor named as in use');
    await Bed.picture(t, 'engine/media3_more');

    await openMenu(t, 'Audio');
    await t.scrollUntilVisible(find.text('Channels'), 120, scrollable: find.descendant(of: find.byType(PlayerPanel), matching: find.byType(Scrollable)).last);
    expect(find.text('Stereo'), findsOneWidget);
    expect(find.text('5.1'), findsNothing, reason: 'Media3 has no 5.1 limit');
    await Bed.closePlayer(t);
    expect(find.byType(PlayerPage), findsNothing);
  }, variant: tv);

  testWidgets('with mpv chosen the player is an mpv one and all of them are back', (t) async {
    PlayerEngine.choose(PlayerEngine.mpv);
    Bed.exoCalls.clear();
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    expect(Bed.exoCalls, isEmpty, reason: 'Media3 is not used');
    expect(Bed.videoCalls, isNotEmpty);

    await openMenu(t, 'More');
    expect(find.text('Ambient lighting'), findsOneWidget);
    expect(find.text('UPSCALING'), findsOneWidget);
    expect(find.text('NVIDIA Image Scaling'), findsOneWidget);
    await openMenu(t, 'Audio');
    await t.scrollUntilVisible(find.text('Channels'), 120, scrollable: find.descendant(of: find.byType(PlayerPanel), matching: find.byType(Scrollable)).last);
    expect(find.text('5.1'), findsOneWidget);
    await Bed.closePlayer(t);
  }, variant: tv);

  test('a Media3 player takes a subtitle file with the video, another one later, and the look in one call', () async {
    final player = Player(useExoPlayer: true);
    expect(player.playerType, 'exoplayer');
    expect(player.mpvCore, isFalse, reason: 'Media3 is playing until it hands a video over');
    Bed.exoCalls.clear();
    await player.open(
      Media('https://files.example/film.mkv'),
      externalSubtitles: [SubtitleTrack.uri('file:///subs/film.en.srt', title: 'English', language: 'en', isDefault: true)],
    );
    final open = Bed.exoCalls.firstWhere((c) => c.startsWith('open '));
    expect(open, contains('uri: file:///subs/film.en.srt'), reason: 'the file goes in with the open');
    expect(open, contains('isDefault: true'), reason: 'and is put on');

    // another file, picked while the video plays
    Bed.exoCalls.clear();
    expect(await player.addSubtitleFile('file:///subs/film.fr.srt', title: 'French', language: 'fr'), isTrue);
    expect(Bed.exoCalls.single, 'addSubtitleTrack {uri: file:///subs/film.fr.srt, title: French, language: fr, select: true}');

    // the look: what Media3 can draw, in its own words; mpv's properties still go out, for the
    // mpv its plugin falls back to
    final saved = [AppSettings.subtitleSize.value, AppSettings.subtitleBackground.value, AppSettings.subtitleLift.value];
    addTearDown(() {
      AppSettings.subtitleSize.set(saved[0]);
      AppSettings.subtitleBackground.set(saved[1]);
      AppSettings.subtitleLift.set(saved[2]);
      AppSettings.subtitleTop.set(false);
      AppSettings.subtitleOnPicture.set(false);
    });
    AppSettings.subtitleSize.set(30);
    AppSettings.subtitleBackground.set(0);
    AppSettings.subtitleLift.set(10);
    AppSettings.subtitleTop.set(false);
    AppSettings.subtitleOnPicture.set(true);
    Bed.exoCalls.clear();
    await SubtitleStyle.apply(player);
    final style = Bed.exoCalls.lastWhere((c) => c.startsWith('setSubtitleStyle '));
    expect(style, contains('fontSize: 26.0'), reason: '30 in Settings is 26 in the units mpv uses, which Media3 takes too');
    expect(style, contains('textColor: #FFFFFF'));
    expect(style, contains('borderSize: 2.5'), reason: 'no box: the outline is on');
    expect(style, contains('bgOpacity: 0'));
    expect(style, contains('subtitlePosition: 90'), reason: '10% up from the bottom');
    expect(style, contains('anchorToScreen: false'), reason: 'kept on the picture');
    expect(Bed.exoCalls.where((c) => c.startsWith('setMpvProperty') && c.contains('sub-font-size')), isNotEmpty);
    // a box turns the outline off, as on mpv; at the top, the distance counts from the top
    AppSettings.subtitleBackground.set(75);
    AppSettings.subtitleTop.set(true);
    Bed.exoCalls.clear();
    await SubtitleStyle.apply(player);
    final boxed = Bed.exoCalls.lastWhere((c) => c.startsWith('setSubtitleStyle '));
    expect(boxed, contains('borderSize: 0'));
    expect(boxed, contains('bgOpacity: 75'));
    expect(boxed, contains('subtitlePosition: 10'));
    await player.dispose();
  });

  testWidgets('Settings on a TV: Playback has the Player engine, Media3 first; Subtitles leaves out what only mpv draws', (t) async {
    await openSettings(t, 'Playback');
    expect(find.text('Player engine'), findsOneWidget);
    expect(find.textContaining("Media3 is Android's own player"), findsOneWidget);
    await Bed.picture(t, 'engine/settings_playback');
    // picking mpv saves it; the words under the row follow
    await t.ensureVisible(find.widgetWithText(Pressable, 'mpv').first);
    await t.tap(find.widgetWithText(Pressable, 'mpv').first);
    await Bed.settle(t, rounds: 2);
    expect(AppSettings.playerEngine.value, PlayerEngine.mpv);
    expect(find.textContaining('mpv has upscaling'), findsOneWidget);
    await t.tap(find.widgetWithText(Pressable, 'Media3').first);
    await Bed.settle(t, rounds: 2);
    expect(PlayerEngine.isMedia3, isTrue);
  }, variant: tv);

  testWidgets('Settings > Subtitles on a TV: font, spacing, shadow and styled subtitles show with mpv only', (t) async {
    await openSettings(t, 'Subtitles');
    const mpvOnly = ['Font', 'Letter spacing', 'Shadow', 'Shadow strength', 'Soft edges', 'Styled subtitles'];
    const both = ['Bold', 'Text size', 'Text colour', 'Box', 'Outline', 'Outline colour', 'Place at', 'Keep on the picture'];
    for (final title in mpvOnly) {
      expect(find.text(title), findsNothing, reason: '$title is not offered while Media3 is the engine');
    }
    for (final title in both) {
      expect(find.text(title), findsWidgets, reason: '$title works on Media3 too');
    }
    await Bed.picture(t, 'engine/settings_subtitles_media3');
    PlayerEngine.choose(PlayerEngine.mpv);
    await Bed.settle(t, rounds: 2);
    for (final title in [...mpvOnly, ...both]) {
      expect(find.text(title), findsWidgets, reason: '$title is there with mpv');
    }
  }, variant: tv);

  test('the phone page lists what the engine can do, and can change the engine', () async {
    var items = phoneItems();
    expect(items['device.engine']?['value'], PlayerEngine.media3);
    for (final id in const ['play.upscaler', 'play.ambient', 'subs.font', 'subs.spacing', 'subs.shadow', 'subs.shadowColor', 'subs.blur', 'subs.ass']) {
      expect(items.containsKey(id), isFalse, reason: '$id is not on the page while Media3 is the engine');
    }
    expect([for (final o in items['device.channels']!['options'] as List) (o as Map)['v']], ['original', 'stereo']);
    expect(items.containsKey('subs.size'), isTrue);
    expect(items.containsKey('subs.outline'), isTrue);

    // the phone picks mpv
    final engine = phoneSections(fonts: const [SubtitleStyle.defaultFont]).expand((s) => s.items).firstWhere((i) => i.id == 'device.engine');
    expect(await engine.take({'id': 'device.engine', 'v': 'vlc'}), isNull, reason: 'not an engine');
    final took = await engine.take({'id': 'device.engine', 'v': 'mpv'});
    expect(took?.what, 'Player engine: mpv');
    items = phoneItems();
    for (final id in const ['play.upscaler', 'play.ambient', 'subs.font', 'subs.spacing', 'subs.shadow', 'subs.shadowColor', 'subs.blur', 'subs.ass']) {
      expect(items.containsKey(id), isTrue, reason: '$id is back with mpv');
    }
    expect([for (final o in items['device.channels']!['options'] as List) (o as Map)['v']], ['original', 'surround51', 'stereo']);

    // not an Android TV: no engine to choose, and everything mpv does is there
    PlayerEngine.debugOffered = false;
    items = phoneItems();
    expect(items.containsKey('device.engine'), isFalse);
    expect(items.containsKey('play.upscaler'), isTrue);
  });
}
