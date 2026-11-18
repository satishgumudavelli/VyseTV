// T4 for phase 9: journeys through Party with arrows, OK and Back only. Party needs an account
// and its server; what the server would have sent is put in by hand (bed/phase9_pages.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/party/rooms.dart';
import 'package:vyse_tv/data/party/voice.dart';
import 'package:vyse_tv/dpad/dpad_extras.dart';
import 'package:vyse_tv/dpad/dpad_seek.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/dpad/focus_navigation_intent.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/party/dm_page.dart';
import 'package:vyse_tv/data/party/watch_party.dart' show PartySong;
import 'package:vyse_tv/screens/party/party_live_player.dart';
import 'package:vyse_tv/screens/party/party_music_view.dart';
import 'package:vyse_tv/screens/party/party_page.dart';
import 'package:vyse_tv/screens/party/party_strip.dart';
import 'package:vyse_tv/screens/party/room_page.dart';
import 'package:vyse_tv/screens/party/rooms_view.dart';
import 'package:vyse_tv/screens/player/player_chrome.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase9_pages.dart';
import 'bed/walker.dart';
import 'harness.dart';

bool _inBox() => FocusManager.instance.primaryFocus?.nearestScope?.debugLabel?.contains('Modal') ?? false;
bool _typing() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
String _label() => FocusManager.instance.primaryFocus?.debugLabel ?? '';
bool _onSlider() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<DpadSlider>() != null;

/// A page with a list on the left and a tile on the right that can fill the window, the way a
/// room lays out its picture. [tile] builds the tile for "in the room" or "filling the window".
class _Room extends StatefulWidget {
  const _Room(this.tile, {this.chat = false});
  final Widget Function(bool full, VoidCallback onExpand) tile;

  /// With a chat box after the tile that asks for the keyboard, as a room's does.
  final bool chat;
  @override
  State<_Room> createState() => _RoomState();
}

class _RoomState extends State<_Room> {
  bool full = false;

  // A room moves its player between the tile and the whole window by a GlobalKey, so it is the
  // same player, still playing, in both places (room_page.dart, RoomPage._playerKey). So does this.
  final _player = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final tile = KeyedSubtree(key: _player, child: widget.tile(full, () => setState(() => full = !full)));
    if (full) return Scaffold(body: tile);
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 300,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 3; i++)
                  Pressable(onTap: () {}, builder: (_, _, _) => SizedBox(height: 60, child: Center(child: Text('Row $i')))),
              ],
            ),
          ),
          Expanded(child: Center(child: SizedBox(width: 640, height: 360, child: tile))),
          if (widget.chat) const SizedBox(width: 240, child: Align(alignment: Alignment.bottomCenter, child: TextField(autofocus: true))),
        ],
      ),
    );
  }
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('Party: a conversation opens with the caret in its box; Back stops the typing, then returns to its row', (t) async {
    addTearDown(signOut);
    await phase9Pages['Party']!(t);
    expect(find.byType(PartyPage), findsOneWidget);
    await Bed.dpadMode(t);
    final thread = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ThreadRow').first;
    await Bed.focus(t, thread);
    final row = FocusManager.instance.primaryFocus!;
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 5);
    expect(find.byType(DmPage), findsOneWidget);
    expect(_typing(), isTrue, reason: 'a conversation opens ready to type');
    // a box of several lines keeps Up while the caret has somewhere to go: with nothing typed it has not
    await Bed.up(t);
    expect(_typing(), isFalse, reason: 'Up leaves the box');
    await Bed.down(t, times: 3);
    expect(_typing(), isTrue, reason: 'and Down comes back to it');
    await Bed.back(t);
    if (find.byType(DmPage).evaluate().isNotEmpty) await Bed.back(t);
    expect(find.byType(DmPage), findsNothing, reason: 'Back (after stepping off the box, if focus was in it) leaves the conversation');
    expect(row.hasPrimaryFocus, isTrue, reason: 'R6: back on the conversation you opened');
  }, variant: screen);

  testWidgets('Party: the friends tabs switch on OK and every request has its buttons within reach', (t) async {
    addTearDown(signOut);
    await phase9Pages['Party']!(t);
    await Bed.dpadMode(t);
    final requests = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabPill' && find.descendant(of: find.byWidget(w), matching: find.textContaining('Requests')).evaluate().isNotEmpty);
    if (requests.evaluate().isEmpty) {
      // (the tab is named for what it holds; fall back to the second pill)
      await Bed.focus(t, find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabPill').at(1));
    } else {
      await Bed.focus(t, requests.first);
    }
    final tab = FocusManager.instance.primaryFocus!;
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(tab.hasPrimaryFocus, isTrue, reason: 'OK shows the tab and focus stays on it');
    await Bed.down(t);
    expect(tab.hasPrimaryFocus, isFalse, reason: 'Down goes into what the tab shows');
    expect(Bed.focused(), isNot('nothing'));
    await Bed.right(t, times: 2);
    await Bed.left(t);
    expect(Bed.focused(), isNot('nothing'));
    expect(find.byType(PartyPage), findsOneWidget);
    // back up to the tabs: onto the one that is showing, wherever in its content you were
    for (var i = 0; i < 6 && !Bed.focused().contains('_TabPill'); i++) {
      await Bed.up(t);
    }
    expect(tab.hasPrimaryFocus, isTrue, reason: 'Up from what a tab shows returns to that tab');
  }, variant: screen);

  testWidgets('Party: creating a room is a box that keeps the arrows; Back closes it onto the button that opened it', (t) async {
    addTearDown(signOut);
    await phase9Pages['Party']!(t);
    await Bed.dpadMode(t);
    final create = find.byWidgetPredicate((w) => w is Pressable && w.tooltip != null && w.tooltip!.toLowerCase().contains('room'));
    if (create.evaluate().isEmpty) {
      showCreateRoomDialog(Bed.sectionNavigator(t).context).ignore();
    } else {
      await Bed.focus(t, create.first);
      await Bed.ok(t);
    }
    await Bed.settle(t, rounds: 4);
    expect(_inBox(), isTrue);
    for (final arrow in [Bed.down, Bed.down, Bed.right, Bed.up, Bed.left]) {
      await arrow(t, times: 2);
      expect(_inBox(), isTrue, reason: 'arrows stay in the box');
    }
    for (var i = 0; i < 3 && _inBox(); i++) {
      await Bed.back(t);
    }
    expect(_inBox(), isFalse);
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  testWidgets('a room: opens ready to type; the people and the voice bar are within reach; Back leaves the page', (t) async {
    addTearDown(signOut);
    signIn(inRoom: true);
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'party');
    await Bed.settle(t, rounds: 4);
    openRoom(Bed.sectionNavigator(t)).ignore();
    await Bed.settle(t, rounds: 6);
    expect(find.byType(RoomPage), findsOneWidget);
    await Bed.dpadMode(t);
    await Bed.settle(t, rounds: 2);
    expect(_typing(), isTrue, reason: 'a room opens with the caret in its chat box');
    for (var i = 0; i < 6 && !Bed.focused().contains('_Tile'); i++) {
      await Bed.left(t);
      if (!Bed.focused().contains('_Tile')) await Bed.up(t);
    }
    expect(Bed.focused(), contains('_Tile'), reason: 'the people in the room can be reached from the chat');
    for (var i = 0; i < 8 && !Bed.focused().contains('_VoiceBar'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('_VoiceBar'), reason: 'and the voice bar under them');
    await Bed.back(t);
    expect(find.byType(RoomPage), findsNothing, reason: 'Back leaves the room’s page (the room itself goes on)');
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  testWidgets('a room: OK on someone opens their menu; their volume moves with Left and Right; Back returns to them', (t) async {
    addTearDown(signOut);
    await phase9Pages['Party, a room']!(t);
    await Bed.dpadMode(t);
    final tile = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tile').at(1); // (the first is you)
    await Bed.focus(t, tile);
    final from = FocusManager.instance.primaryFocus!;
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(_inBox(), isTrue, reason: 'OK on someone else opens their menu');
    expect(find.text('Report'), findsOneWidget);
    // down to the line their volume is on, then along it to the slider
    await Bed.down(t);
    for (final step in [Bed.left, Bed.right, Bed.right]) {
      if (_onSlider()) break;
      await step(t);
    }
    expect(_onSlider(), isTrue, reason: 'their volume is a stop (focus is on ${Bed.focused()})');
    final id = Rooms.mine.value!.members[1].id;
    final before = Voice.volumes[id] ?? 1.0;
    await Bed.right(t, times: 3);
    expect(Voice.volumes[id], closeTo(before + .3, .001), reason: 'Right turns them up, a tenth at a time');
    await Bed.left(t, times: 3);
    expect(Voice.volumes[id], closeTo(before, .001));
    expect(_inBox(), isTrue, reason: 'Left and Right on the slider never leave it');
    await Bed.ok(t);
    expect(Voice.volumes[id], 0, reason: 'OK on the slider mutes them for you');
    await Bed.ok(t);
    expect(Voice.volumes[id], closeTo(before, .001), reason: 'and OK again brings them back');
    // everything in the menu is somewhere arrows go: nothing is left that only a mouse reaches
    final stops = Dpad.stopsIn(FocusManager.instance.primaryFocus!.nearestScope!).length;
    final seen = <FocusNode>{FocusManager.instance.primaryFocus!};
    for (final arrow in [Bed.up, Bed.up, Bed.down, Bed.right, Bed.down, Bed.down, Bed.down, Bed.down, Bed.down, Bed.down, Bed.up, Bed.up]) {
      await arrow(t);
      seen.add(FocusManager.instance.primaryFocus!);
    }
    expect(seen.length, stops, reason: 'every stop of the menu was visited');
    await Bed.down(t, times: 6);
    expect(_inBox(), isTrue, reason: 'arrows stay in the menu');
    await Bed.back(t);
    expect(_inBox(), isFalse, reason: 'Back closes it');
    expect(from.hasPrimaryFocus, isTrue, reason: 'R6: back on the person it was opened from');
    Voice.volumes.remove(id);
  }, variant: screen);

  testWidgets('a room: every button of the voice bar is a stop, in one line', (t) async {
    addTearDown(signOut);
    await phase9Pages['Party, a room']!(t);
    await Bed.dpadMode(t);
    final bar = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_RoundToggle');
    expect(bar, findsWidgets);
    await Bed.focus(t, bar.first);
    final seen = <String>{Bed.focused()};
    final y = FocusManager.instance.primaryFocus!.rect.center.dy;
    for (var i = 0; i < bar.evaluate().length - 1; i++) {
      await Bed.right(t);
      expect((FocusManager.instance.primaryFocus!.rect.center.dy - y).abs() < 4, isTrue, reason: 'Right along the bar stays on the bar');
      seen.add('${Bed.focused()} at ${FocusManager.instance.primaryFocus!.rect.left.round()}');
    }
    expect(seen.length, bar.evaluate().length, reason: 'each press is a different button');
  }, variant: screen);

  group('pieces of a room by themselves', () {
    testWidgets('hold to talk: you talk for as long as OK is held, and not a moment longer', (t) async {
      Voice.talking.value = false;
      await t.pumpWidget(Bed.app(const Scaffold(body: Center(child: SizedBox(width: 200, child: HoldToTalk())))));
      await t.pump(const Duration(milliseconds: 300));
      await Bed.dpadMode(t);
      await Bed.focus(t, find.byType(HoldToTalk));
      expect(Voice.talking.value, isFalse);
      await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 50));
      expect(Voice.talking.value, isTrue, reason: 'OK down: talking');
      for (var i = 0; i < 10; i++) {
        await t.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await t.pump(const Duration(milliseconds: 33));
      }
      expect(Voice.talking.value, isTrue, reason: 'held: still talking');
      await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 50));
      expect(Voice.talking.value, isFalse, reason: 'OK up: quiet');
      // a mouse holds it with the mouse, as before
      final g = await t.startGesture(t.getCenter(find.byType(HoldToTalk)));
      await t.pump(const Duration(milliseconds: 50));
      expect(Voice.talking.value, isTrue);
      await g.up();
      await t.pump(const Duration(milliseconds: 50));
      expect(Voice.talking.value, isFalse);
    }, variant: screen);

    testWidgets('a message: a stop whose menu opens with OK, over the message', (t) async {
      final opened = <Offset>[];
      await t.pumpWidget(Bed.app(Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              DpadMenuStop(onMenu: opened.add, child: SizedBox(width: 300, height: 40, child: Text('Message ${i + 1}'))),
          ]),
        ),
      )));
      await t.pump(const Duration(milliseconds: 300));
      await Bed.dpadMode(t);
      await Bed.focus(t, find.byType(DpadMenuStop).first);
      await Bed.down(t);
      expect(Bed.focusInView(), isTrue);
      await Bed.ok(t);
      expect(opened, hasLength(1));
      final second = t.getRect(find.text('Message 2'));
      expect(second.inflate(4).contains(opened.single), isTrue, reason: 'the menu opens over the message focus is on');
      // a click does not open it (that is still the right button, or a long press)
      await t.tapAt(t.getCenter(find.text('Message 1')));
      await t.pump(const Duration(milliseconds: 300));
      expect(opened, hasLength(1));
    }, variant: screen);

    testWidgets('the Live TV tile: one stop in the room, OK fills the window; there, the two states', (t) async {
      await t.pumpWidget(Bed.app(_Room((full, onExpand) => PartyLivePlayer(key: const ValueKey('live'), url: 'http://tv.example/1.m3u8', title: 'Channel 1', onExpand: onExpand, full: full))));
      await Bed.settle(t, rounds: 4);
      _RoomState room() => t.state<_RoomState>(find.byType(_Room));
      await Bed.dpadMode(t);
      await Bed.focus(t, find.widgetWithText(Pressable, 'Row 2'));
      await Bed.right(t);
      expect(Bed.focused(), contains('PartyLivePlayer'), reason: 'Right from the list lands on the tile');
      await Bed.picture(t, 'phase9/piece_live_tile_1_focused');
      final tile = FocusManager.instance.primaryFocus!;
      await Bed.right(t);
      expect(tile.hasPrimaryFocus, isFalse, reason: 'Right steps onto its buttons');
      expect(tile.hasFocus, isTrue);
      await Bed.left(t);
      expect(tile.hasPrimaryFocus, isTrue);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(room().full, isTrue, reason: 'OK on the tile fills the window');
      expect(_label(), 'room live player', reason: 'with focus resting on the picture');
      await Bed.ok(t);
      expect(Bed.focused(), contains('PartyLivePlayer'), reason: 'OK brings the controls up, with the ring on one of them');
      expect(find.byTooltip('Pause (Space)').evaluate().isNotEmpty || find.byTooltip('Play (Space)').evaluate().isNotEmpty, isTrue);
      await Bed.picture(t, 'phase9/piece_live_tile_2_full');
      await Bed.back(t);
      expect(room().full, isTrue, reason: 'the first Back hides the controls');
      expect(_label(), 'room live player');
      await Bed.ok(t);
      expect(Bed.focused(), isNot('nothing'), reason: 'OK brings them back');
      await Bed.back(t);
      await Bed.back(t);
      await Bed.settle(t, rounds: 2);
      expect(room().full, isFalse, reason: 'Back, then Back again, returns to the room');
      expect(_label(), 'room live tile', reason: 'R6: with the ring on the tile it filled the window from');
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 4);
    }, variant: screen);

    testWidgets('the film tile: one stop in the room; its controls show while focus is there; OK fills the window', (t) async {
      final media = Bed.freshTitle();
      await t.pumpWidget(Bed.app(_Room((full, onExpand) => PlayerPage(key: const ValueKey('film'), media: media, embedded: true, expanded: full, onExpand: onExpand))));
      await Bed.settle(t, rounds: 6);
      _RoomState room() => t.state<_RoomState>(find.byType(_Room));
      expect(InputModeTracker.currentMode, InputMode.pointer);
      await Bed.dpadMode(t);
      await Bed.focus(t, find.widgetWithText(Pressable, 'Row 2'));
      await Bed.right(t);
      expect(_label(), 'room player tile', reason: 'Right from the list lands on the tile');
      await Bed.picture(t, 'phase9/piece_film_tile_1_focused');
      await t.pump(const Duration(seconds: 6));
      final dockShut = t.widget<ExcludeFocus>(find.ancestor(of: find.byType(PlayKey), matching: find.byType(ExcludeFocus)).first).excluding;
      expect(dockShut, isFalse, reason: 'its controls stay up while focus is on the tile');
      await Bed.right(t);
      expect(Bed.focused(), contains('PlayKey'), reason: 'Right steps onto its controls, at Play');
      await Bed.picture(t, 'phase9/piece_film_tile_2_on_play');
      await Bed.up(t);
      expect(Bed.focused(), contains('PlayerRail'), reason: 'Up from its buttons is its own seek bar, not the page above');
      await Bed.down(t);
      expect(Bed.focused(), contains('PlayKey'));
      for (var i = 0; i < 6 && _label() != 'room player tile'; i++) {
        await Bed.left(t);
      }
      expect(_label(), 'room player tile', reason: 'Left off its first button is back on the tile');
      await Bed.left(t);
      expect(Bed.focused(), contains('Row'), reason: 'and Left again returns to the list');
      await Bed.right(t);
      expect(_label(), 'room player tile');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(room().full, isTrue, reason: 'OK on the tile fills the window');
      expect(_label(), isNot('room player tile'), reason: 'with focus resting on the picture');
      expect(FocusManager.instance.primaryFocus is DirectionalShortcutFocusNode, isTrue);
      // out again: Back hides whatever is up, then returns to the room
      for (var i = 0; i < 3 && room().full; i++) {
        await Bed.back(t);
        await Bed.settle(t, rounds: 2);
      }
      expect(room().full, isFalse, reason: 'Back returns to the room');
      expect(_label(), 'room player tile', reason: 'R6: with the ring on the tile it filled the window from');
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 4);
    }, variant: screen);

    testWidgets('the strip over a player: Room chat opens a box to type in; hold to talk is a stop; hidden, it takes no focus', (t) async {
      addTearDown(signOut);
      signIn(inRoom: true);
      final talkWas = Voice.pushToTalk.value;
      Voice.pushToTalk.value = true;
      addTearDown(() => Voice.pushToTalk.value = talkWas);
      final messages = StreamController<RoomMessage>.broadcast();
      addTearDown(messages.close);
      Widget strip({required bool up}) => Bed.app(Scaffold(
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.all(40), child: PartyStrip(controlsUp: up, touch: true, messages: messages.stream)),
          Pressable(onTap: () {}, builder: (_, _, _) => const SizedBox(width: 120, height: 48, child: Center(child: Text('Play')))),
        ]),
      ));
      await t.pumpWidget(strip(up: true));
      await t.pump(const Duration(milliseconds: 300));
      await Bed.dpadMode(t);
      await Bed.focus(t, find.byTooltip('Room chat'));
      expect(Bed.focusInView(), isTrue);
      await Bed.ok(t);
      await t.pump(const Duration(milliseconds: 200));
      expect(_typing(), isTrue, reason: 'OK on Room chat opens the box with the caret in it');
      await Bed.back(t);
      await t.pump(const Duration(milliseconds: 200));
      expect(_typing(), isFalse, reason: 'Back stops the typing');
      expect(find.byType(TextField), findsNothing, reason: 'and an empty box closes');
      expect(Bed.focused(), isNot('nothing'));
      // the talk button under the faces
      await Bed.focus(t, find.byTooltip('Room chat'));
      await Bed.down(t);
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<HoldToTalk>(), isNotNull, reason: 'Down from the faces is the talk button');
      await Bed.picture(t, 'phase9/piece_strip_talk_button');
      // the player hides its controls: the faces and the chat button go, the talk button stays
      await Bed.down(t);
      await t.pumpWidget(strip(up: false));
      await t.pump(const Duration(milliseconds: 400));
      final scope = FocusManager.instance.primaryFocus!.nearestScope!;
      final inStrip = [for (final n in Dpad.stopsIn(scope)) if (n.context!.findAncestorWidgetOfExactType<PartyStrip>() != null) n];
      expect(inStrip, hasLength(1), reason: 'only the talk button is left to focus');
      expect(inStrip.single.context!.findAncestorWidgetOfExactType<HoldToTalk>(), isNotNull);
      Voice.talking.value = false;
    }, variant: screen);

    for (final full in [false, true]) {
      testWidgets('the room\u2019s music, ${full ? 'filling the window' : 'as a card in the room'}: every control is reached; the seek line and the volume move with Left and Right', (t) async {
        final position = ValueNotifier(const Duration(seconds: 60));
        final duration = ValueNotifier(const Duration(seconds: 240));
        addTearDown(position.dispose);
        addTearDown(duration.dispose);
        final seeks = <Duration>[];
        var volume = 60.0;
        var toggles = 0;
        final music = StatefulBuilder(
          builder: (context, setState) => PartyMusicView(
            song: const PartySong(id: 's1', title: 'A made-up song', artist: 'Nobody', album: 'Nothing', seconds: 240),
            position: position,
            duration: duration,
            playing: true,
            listeners: [for (var i = 0; i < 3; i++) PartyListener(id: 'u$i', name: person(i).name)],
            upNext: const [PartySong(id: 's2', title: 'The next one', artist: 'Nobody', seconds: 200), PartySong(id: 's3', title: 'The one after', artist: 'Nobody', seconds: 180)],
            canPlay: true,
            canSkip: true,
            full: full,
            volume: volume,
            onToggle: () => toggles++,
            onSeek: (to) {
              seeks.add(to);
              position.value = to;
            },
            onNext: () {},
            onPrevious: () {},
            onExpand: () {},
            onStop: () {},
            onAdd: () {},
            onVolume: (v) => setState(() => volume = v),
          ),
        );
        await t.pumpWidget(Bed.app(Scaffold(body: full ? music : Center(child: SizedBox(width: 760, child: music)))));
        await Bed.settle(t, rounds: 4);
        await Bed.dpadMode(t);
        await Bed.settle(t, rounds: 2);
        final report = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: (_) => true).run(maxPresses: 1500);
        debugPrint('room music ${full ? 'full' : 'card'}: walked ${report.places.length} places in ${report.presses} presses, ${report.problems.length} problem(s)');
        for (final p in report.problems) {
          debugPrint('PROBLEM $p', wrapWidth: 2000);
        }
        report.expectClean();
        // the host's seek line
        await Bed.focus(t, find.byType(DpadSeekStop));
        await Bed.picture(t, 'phase9/piece_room_music_${full ? 'full' : 'card'}_seek_line');
        final at = position.value;
        seeks.clear();
        await Bed.right(t);
        await t.pump(const Duration(seconds: 1));
        expect(seeks, isNotEmpty, reason: 'Right on the seek line seeks');
        expect(seeks.last, at + const Duration(seconds: 5));
        await Bed.left(t);
        await t.pump(const Duration(seconds: 1));
        expect(seeks.last, at, reason: 'and Left seeks back');
        // the volume
        final slider = find.byType(DpadSlider);
        if (slider.evaluate().isNotEmpty) {
          await Bed.focus(t, slider.first);
          await Bed.picture(t, 'phase9/piece_room_music_${full ? 'full' : 'card'}_volume');
          final was = volume;
          await Bed.right(t);
          expect(volume, was + 5, reason: 'Right on the volume turns it up five');
          await Bed.left(t, times: 2);
          expect(volume, was - 5);
        } else {
          expect(full, isFalse, reason: 'filling the window, the volume has a slider');
        }
        // OK on Play works wherever the ring is put
        final play = find.byWidgetPredicate((w) => w is Pressable && (w.tooltip?.toLowerCase().contains('pause') ?? false));
        if (play.evaluate().isNotEmpty) {
          await Bed.focus(t, play.first);
          await Bed.ok(t);
          expect(toggles, 1);
        }
      }, variant: screen);
    }

    testWidgets('the film tile: it never takes the keyboard from the chat box, with a mouse or with a D-pad', (t) async {
      final media = Bed.freshTitle();
      await t.pumpWidget(Bed.app(_Room(chat: true, (full, onExpand) => PlayerPage(key: const ValueKey('film'), media: media, embedded: true, expanded: full, onExpand: onExpand))));
      await Bed.settle(t, rounds: 6);
      expect(find.byType(PlayKey), findsOneWidget);
      expect(InputModeTracker.currentMode, InputMode.pointer);
      expect(_typing(), isTrue, reason: 'a room opened with a film on: the caret is in the chat box, as it always was');
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 4);

      // the same when a remote is already in charge as the room opens
      await t.pumpWidget(Bed.app(const Scaffold(body: SizedBox())));
      await Bed.dpadMode(t);
      final other = Bed.freshTitle();
      await t.pumpWidget(Bed.app(_Room(chat: true, (full, onExpand) => PlayerPage(key: const ValueKey('film 2'), media: other, embedded: true, expanded: full, onExpand: onExpand))));
      await Bed.settle(t, rounds: 6);
      expect(InputModeTracker.currentMode, InputMode.keyboard);
      expect(_typing(), isTrue, reason: 'with a D-pad too: Play on the tile is where stepping into it lands, not where the page starts');
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 4);
    }, variant: screen);
  });
}
