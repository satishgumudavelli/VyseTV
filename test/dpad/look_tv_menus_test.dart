// A TV's player menus (lib/screens/player/tv_menus.dart): each one drawn at a TV's size over a
// made-up picture with made-up contents, for the pictures in docs/dpad/pictures/tvmenus, and
// walked with a remote. The menus are the panel's own (PlayerPanel and its panes); only the
// player behind them is left out, so a menu can be full of subtitles, tracks and links.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/subtitles/subtitles.dart' as sub;
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/tv_menus.dart';

import 'harness.dart';

sub.SubtitleTrack _track(String id, String language, String release, {String provider = 'OpenSubtitles', String format = 'srt', bool translated = false}) =>
    sub.SubtitleTrack(id: id, provider: provider, lang: language.substring(0, 2).toLowerCase(), language: language, release: release, url: 'http://subs.test/$id.$format', format: format, translated: translated);

final _tracks = [
  _track('en0', 'English', 'English', provider: 'Built in', format: 'ass'),
  _track('en1', 'English', 'The.Long.Night.2024.2160p.UHD.BluRay.REMUX.HDR.TrueHD.7.1-FGT'),
  _track('en2', 'English', 'The.Long.Night.2024.1080p.WEB-DL.DDP5.1.H.264-NTb.SDH'),
  _track('en3', 'English', 'The.Long.Night.2024.720p.BluRay.x264-SPARKS'),
  _track('en4', 'English', 'The.Long.Night.2024.HDCAM.x264-NoGRP'),
  _track('ar1', 'Arabic', 'The.Long.Night.2024.1080p.BluRay.x264-SPARKS'),
  _track('ar2', 'Arabic', 'The.Long.Night.2024.WEB-DL.NF'),
  _track('fr1', 'French', 'The.Long.Night.2024.MULTi.1080p.BluRay.x264-Ulysse'),
  _track('fr2', 'French', 'The.Long.Night.2024.FRENCH.WEBRip'),
  _track('es1', 'Spanish', 'La.Noche.Larga.2024.1080p.BluRay'),
  _track('de1', 'German', 'German', translated: true),
];

/// What stands for the film: something bright, with a line of subtitles on it, to see how much
/// of the picture a menu leaves.
class _Picture extends StatelessWidget {
  const _Picture();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2B5F8A), Color(0xFFE0A458), Color(0xFFB5462F), Color(0xFF3C2A4D)],
        stops: [0, .45, .7, 1],
      ),
    ),
    child: Align(
      alignment: Alignment(0, .86),
      child: Text('I told you we would make it by morning.', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
    ),
  );
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  final region = DpadRegionNode();
  sub.SubtitleTrack? active = _tracks[1];
  var speed = 1.0;
  final opened = <String>[];
  // (the player builds its menus again when a choice is made: so does this)
  void Function() again = () {};

  Widget pane(MenuTab tab, PanelFit fit) => switch (tab) {
    MenuTab.subtitles => SubtitlesPane(
      fit: fit,
      offset: 0,
      tracks: _tracks,
      loading: false,
      active: active,
      onTrack: (t) {
        active = t;
        again();
      },
      onSync: () => opened.add('sync'),
    ),
    MenuTab.audio => AudioPane(
      tracks: [
        MenuAudio(title: 'English', detail: 'Dolby TrueHD · 7.1 · Atmos', current: true, onTap: () {}),
        MenuAudio(title: 'English', detail: 'Dolby Digital · 5.1', onTap: () {}),
        MenuAudio(title: 'French', detail: 'DTS · 5.1', onTap: () {}),
        MenuAudio(title: 'Commentary', detail: 'AAC · Stereo', onTap: () {}),
      ],
      sound: [
        MenuStepper(title: 'Audio sync', detail: 'Fixes lip-sync · + plays the sound later', label: '0 ms', onMinus: () {}, onPlus: () {}, onReset: () {}),
        MenuChoice<String>(title: 'Channels', detail: 'Stereo folds surround down for headphones and TV speakers', value: 'original', options: const [('original', 'Original'), ('stereo', 'Stereo')], onChanged: (_) {}),
        MenuToggle(title: 'Volume levelling', detail: 'Evens out quiet talk and loud action', value: false, onChanged: (_) {}),
        MenuToggle(title: 'Passthrough', detail: 'Sends Dolby and DTS untouched to a receiver', value: true, onChanged: (_) {}),
      ],
    ),
    MenuTab.sources => FilmSourcesPane(
      sources: [
        MenuFilmSource(
          id: 'movy',
          name: 'Movy',
          note: '17 servers, some in other languages',
          servers: true,
          state: SourceState.ready,
          links: [
            MenuLink(name: 'Miami', quality: '1080p', format: 'HLS', state: SourceState.ready, current: true, onTap: () {}),
            MenuLink(name: 'Tokyo', quality: '4K', format: 'HLS', onTap: () {}),
            MenuLink(name: 'Paris', format: 'HLS', audio: 'French', onTap: () {}),
            MenuLink(name: 'Oslo', state: SourceState.dead, onTap: () {}),
          ],
          onOpen: () => opened.add('movy'),
        ),
        MenuFilmSource(id: 'cno', name: 'CNO', note: 'Films and series', state: SourceState.dead, onOpen: () => opened.add('cno')),
        MenuFilmSource(
          id: '111477',
          name: '111477',
          note: 'Large files, original sound',
          state: SourceState.ready,
          links: [
            MenuLink(name: 'Link 1', quality: '4K', format: 'MKV', onTap: () {}),
            MenuLink(name: 'Link 2', quality: '1080p', format: 'MKV', onTap: () {}),
          ],
          onOpen: () => opened.add('111477'),
        ),
        MenuFilmSource(id: 'vidlink', name: 'VidLink', note: 'Films and series', onOpen: () => opened.add('vidlink')),
      ],
    ),
    MenuTab.quality => QualityPane(
      auto: MenuQuality(label: 'Auto', detail: 'Highest this server has (2160p)', onTap: () {}),
      items: [
        MenuQuality(label: '2160p', detail: '3840×2160 · 16.4 Mbps', onTap: () {}),
        MenuQuality(label: '1080p', detail: '1920×1080 · 5.2 Mbps', selected: true, onTap: () {}),
        MenuQuality(label: '720p', detail: '1280×720 · 2.8 Mbps', onTap: () {}),
      ],
    ),
    MenuTab.speed => SpeedPane(
      speeds: const [(.75, '0.75×'), (1.0, 'Normal'), (1.25, '1.25×'), (1.5, '1.5×'), (2.0, '2×')],
      more: const [(.25, '0.25×'), (.5, '0.5×'), (3.0, '3×')],
      value: speed,
      onChanged: (s) {
        speed = s;
        again();
      },
      position: ValueNotifier(const Duration(minutes: 31)),
      duration: ValueNotifier(const Duration(minutes: 118)),
    ),
    MenuTab.more => MorePane(
      sections: [
        ('PICTURE', [MenuStepper(title: 'Zoom', detail: 'Crop the black bars, or shrink the picture', label: '100%', onMinus: () {}, onPlus: () {}, onReset: () {})]),
        ('SLEEP TIMER', [MenuChoice<int>(title: 'Stop playing in', value: 0, options: const [(0, 'Off'), (15, '15m'), (30, '30m'), (60, '1h'), (-1, 'Episode')], onChanged: (_) {})]),
        ('DISPLAY', [MenuToggle(title: 'Match refresh rate', detail: "Switches the screen to the video's frame rate", value: true, onChanged: (_) {})]),
        ('OPEN', [MenuRow(title: 'Copy link', detail: 'The stream address, to paste into another app', onTap: () {})]),
      ],
    ),
    // (Stream info is drawn in look_tv_info_test.dart)
    MenuTab.info => const SizedBox.shrink(),
  };

  Future<void> show(WidgetTester t, MenuTab tab) async {
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(Bed.app(Scaffold(
      backgroundColor: Colors.black,
      body: StatefulBuilder(
        builder: (context, rebuild) {
          again = () => rebuild(() {});
          return Stack(
          fit: StackFit.expand,
          children: [
            const _Picture(),
            DpadRegion(
              node: region,
              child: PlayerPanel(
                open: true,
                tab: tab,
                onTab: (_) {},
                side: 32,
                top: 0,
                dockH: 118,
                body: (fit) => pane(tab, fit),
                bodyOf: pane,
                value: (m) => switch (m) {
                  MenuTab.subtitles => active?.language ?? 'Off',
                  MenuTab.audio => 'English · TrueHD 7.1',
                  MenuTab.sources => 'Movy · Miami · 1080p',
                  _ => '',
                },
              ),
            ),
          ],
        );
        },
      ),
    )));
    await Bed.settle(t, rounds: 3);
    await Bed.dpadMode(t);
    final start = Dpad.firstStop(region);
    expect(start, isNotNull, reason: 'the menu has somewhere to start');
    Dpad.giveFocus(start!);
    await Bed.settle(t, rounds: 2);
  }

  /// The row the ring is on (its title), or the tooltip of a smaller control.
  String ring() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return '';
    final row = context.findAncestorWidgetOfExactType<MenuRow>();
    return row?.title ?? Bed.focused();
  }

  /// The column the ring is in, by its name.
  String rail() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.findAncestorWidgetOfExactType<TvRail>()?.title ?? '';
  }

  setUp(() {
    active = _tracks[1];
    speed = 1.0;
    opened.clear();
    AppSettings.subtitleBackground.set(0);
  });

  testWidgets('Subtitles: three columns; it opens on the subtitle in use, a language shows its subtitles as the ring reaches it, Right goes on to Style', (t) async {
    final errors = await Bed.overflows(() async {
      await show(t, MenuTab.subtitles);
      expect(find.byType(TvRail), findsNWidgets(3));
      expect(rail(), 'English', reason: 'the subtitle in use, in the middle column');
      expect(ring(), contains('REMUX'));
      await Bed.picture(t, 'tvmenus/subtitles_1_open');

      await Bed.left(t);
      expect((rail(), ring()), ('Languages', 'English'), reason: 'Left: the language whose subtitles are showing');
      await Bed.down(t, times: 2);
      expect(ring(), 'French');
      await Bed.settle(t, rounds: 1);
      expect(find.widgetWithText(TvRail, 'FRENCH'), findsOneWidget, reason: 'its subtitles show beside it at once');
      expect(find.textContaining('Ulysse'), findsOneWidget);
      await Bed.picture(t, 'tvmenus/subtitles_2_another_language');

      await Bed.ok(t); // OK on a language goes on into its subtitles
      await Bed.settle(t, rounds: 2);
      expect(rail(), 'French');
      expect(ring(), contains('Ulysse'));
      await Bed.ok(t);
      expect(active?.id, 'fr1', reason: 'OK on a subtitle uses it');

      await Bed.right(t);
      expect(rail(), 'Style');
      await Bed.picture(t, 'tvmenus/subtitles_3_style');
      await Bed.ok(t);
      expect(opened, ['sync'], reason: 'Sync is the first thing in Style');

      await Bed.left(t);
      expect(rail(), 'French');
      await Bed.left(t);
      expect((rail(), ring()), ('Languages', 'French'));
      await Bed.up(t, times: 6);
      expect(ring(), 'Off');
      await Bed.settle(t, rounds: 1);
      expect(find.textContaining('Off turns subtitles off'), findsOneWidget);
      await Bed.ok(t);
      expect(active, isNull);
    });
    expect(errors, isEmpty, reason: 'nothing runs off its column at a TV\'s size');
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('Audio: tracks and how they sound, side by side', (t) async {
    final errors = await Bed.overflows(() async {
      await show(t, MenuTab.audio);
      expect((rail(), ring()), ('Tracks', 'English'));
      await Bed.picture(t, 'tvmenus/audio');
      await Bed.down(t, times: 2);
      expect(ring(), 'French');
      await Bed.right(t);
      expect(rail(), 'Sound');
      await Bed.left(t);
      expect((rail(), ring()), ('Tracks', 'English'), reason: 'back into a column: onto the one in use');
    });
    expect(errors, isEmpty);
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('Sources: the sources, and beside them the links of the one opened', (t) async {
    final errors = await Bed.overflows(() async {
      await show(t, MenuTab.sources);
      expect((rail(), ring()), ('In your order', 'Movy'), reason: 'it opens on the source that is playing, with its links beside it');
      expect(find.widgetWithText(TvRail, 'MOVY'), findsOneWidget);
      await Bed.picture(t, 'tvmenus/sources_1_open');
      await Bed.right(t);
      expect((rail(), ring()), ('Movy', 'Tokyo'), reason: 'into its links: the first there is something to do with (Miami is playing)');
      await Bed.left(t);
      expect((rail(), ring()), ('In your order', 'Movy'));
      await Bed.down(t, times: 2);
      expect(ring(), '111477');
      expect(find.widgetWithText(TvRail, 'MOVY'), findsOneWidget, reason: 'moving down the sources looks nothing up: the links stay the opened source\'s');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect((rail(), ring()), ('111477', 'Link 1'), reason: 'OK opens a source and goes on into its links');
      await Bed.picture(t, 'tvmenus/sources_2_another');
      await Bed.left(t);
      await Bed.down(t);
      expect(ring(), 'VidLink');
      await Bed.ok(t);
      expect(opened, contains('vidlink'), reason: 'a source not looked up yet is looked up when it is opened');
    });
    expect(errors, isEmpty);
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('Settings: quality, speed and the rest side by side; it opens in the one asked for', (t) async {
    final errors = await Bed.overflows(() async {
      await show(t, MenuTab.speed);
      expect(find.text('Settings'), findsOneWidget);
      expect((rail(), ring()), ('Speed', 'Normal'));
      await Bed.picture(t, 'tvmenus/settings');
      await Bed.left(t);
      expect((rail(), ring()), ('Quality', '1080p'));
      await Bed.right(t, times: 2);
      expect(rail(), 'More');
      await Bed.left(t);
      expect((rail(), ring()), ('Speed', 'Normal'));
      await Bed.down(t);
      await Bed.ok(t);
      expect(speed, 1.25);

      await show(t, MenuTab.quality);
      expect((rail(), ring()), ('Quality', '1080p'), reason: 'Settings by itself opens on Quality');
    });
    expect(errors, isEmpty);
    await t.pumpWidget(const SizedBox());
  }, variant: tv);
}
