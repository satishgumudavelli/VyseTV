// T6: the guard. It reads the interface's source and fails when someone adds something a D-pad
// cannot deal with: a tap detector that is not a Pressable, a control told to be passed over,
// or an autofocus, without it being looked at and listed here with its reason.
//
// It holds the files of finished phases to the rules ([donePhase]); the others are counted in
// docs/dpad/inventory.md and wait their turn.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'bed/source_scan.dart';

/// The last phase of docs/dpad/PLAN.md that is finished.
const donePhase = 10;

/// One reviewed exception: every line in [file] whose text is [line] ([count] of them).
class Reviewed {
  const Reviewed(this.file, this.line, this.count, this.why);
  final String file;
  final String line;
  final int count;
  final String why;
}

/// Tap detectors that are not Pressable, and stay.
const rawTaps = [
  Reviewed('lib/widgets/common.dart', 'child: GestureDetector(', 3,
      'Pressable itself (the mechanism), and the two toasts: a toast comes and goes by itself and is never a focus stop (plan 3.5).'),
  Reviewed('lib/widgets/section_chrome.dart', 'child: GestureDetector(', 1,
      'The search box: a click anywhere in the box puts the caret in its text field. The text field is the focus stop.'),
  Reviewed('lib/screens/search/search_page.dart', 'child: GestureDetector(', 1,
      'Search\'s own box: the same. A click anywhere in it puts the caret in the text field, which is the focus stop.'),
  Reviewed('lib/screens/details/episode_explorer.dart', 'child: GestureDetector(', 1,
      'The episode timeline: a pointer taps or drags along it to pick an episode. A D-pad picks with Left and Right (the explorer\'s own keys) from the Play button above it.'),
  Reviewed('lib/screens/details/episode_explorer.dart', 'return GestureDetector(', 1,
      'The window on a long season\'s timeline, dragged by a pointer. It follows the picked episode, which a D-pad moves with Left and Right.'),
  Reviewed('lib/screens/details/person_page.dart', 'itemBuilder: (_, i) => GestureDetector(', 1,
      'The photo viewer: a click beside the photo closes it. With a D-pad, Back closes it and its close button is a focus stop.'),
  Reviewed('lib/screens/details/person_page.dart', 'child: GestureDetector(', 1,
      'The photo itself swallowing clicks so they do not close the viewer. Nothing to press.'),
  Reviewed('lib/screens/player/player_chrome.dart', 'child: GestureDetector(', 1,
      'The seek bar: a pointer clicks or drags along it. It is a focus stop of its own (Left and Right seek, further when held).'),
  Reviewed('lib/screens/player/player_episodes.dart', 'child: GestureDetector(', 1,
      'The episode list swallowing clicks on its background so they do not reach the picture behind. Nothing to press.'),
  Reviewed('lib/screens/player/player_menus.dart', 'child: GestureDetector(', 1,
      'The settings menu\'s card, swallowing clicks on its background so they do not close it. Nothing to press.'),
  Reviewed('lib/screens/player/tv_menus.dart', 'Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}, child: child)),', 1,
      'A TV\'s full-screen menus (the player\'s menus, Episodes, Subtitle sync), swallowing clicks on their background so they do not reach the picture behind. Nothing to press.'),
  Reviewed('lib/screens/player/subtitle_sync_panel.dart', 'child: GestureDetector(', 1,
      'The subtitle sync panel swallowing clicks on its background. Nothing to press.'),
  Reviewed('lib/screens/player/player_page.dart', 'child: GestureDetector(', 2,
      'The picture: a click shows or hides the controls, a double click is full screen, a swipe is volume or brightness; with keys that is OK, F and the volume keys. And the small window: a tap shows its buttons, which focus shows too.'),
  Reviewed('lib/screens/player/player_page.dart', 'child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: widget.onExpand, child: const SizedBox.expand()),', 1,
      'Picture-in-picture on a desktop: a double click on the small window brings the full one back. Its "Back to the full window" button is a focus stop, and Escape does the same.'),
  Reviewed('lib/screens/shell/intro_screen.dart', 'child: GestureDetector(', 1,
      'The intro: a tap anywhere skips it. So does OK, Space or Back.'),
  Reviewed('lib/screens/live_tv/live_tv_player_page.dart', 'child: GestureDetector(', 1,
      'The Live TV picture: a click shows or hides the controls and a double click is full screen; with keys that is OK and F.'),
  Reviewed('lib/screens/live_tv/portal_browser_player.dart', 'child: GestureDetector(', 1,
      'The portal browser picture: the same. To a D-pad the pane is one focus stop and OK on it is full screen.'),
  Reviewed('lib/screens/live_tv/portal_browser_page.dart', 'return GestureDetector(', 1,
      'The pane search box: a click anywhere in the box puts the caret in its text field, which is the focus stop.'),
  Reviewed('lib/screens/manga/manga_reader_page.dart', 'Widget _scrollView(List<String> pages, double top) => GestureDetector(', 1,
      'The reader in scroll mode: a tap on the page shows or hides its bar. With keys, holding OK (or Menu) brings the bar up and Back hides it.'),
  Reviewed('lib/screens/manga/manga_reader_page.dart', 'builder: (context, c) => GestureDetector(', 1,
      'The reader in page mode: a tap on the left or right third turns the page, in the middle shows or hides the bar. With keys, Left and Right turn pages and holding OK (or Menu) brings the bar up.'),
  Reviewed('lib/screens/party/party_live_player.dart', 'child: GestureDetector(', 1,
      'The picture of a room\'s Live TV: a click shows or hides its controls. To a D-pad the tile is one focus stop and OK fills the window; there OK brings the controls up and Back hides them.'),
  Reviewed('lib/screens/party/party_music_view.dart', 'child: GestureDetector(', 1,
      'The host\'s seek line of a room\'s music: a pointer clicks or drags along it. It is a focus stop of its own (Left and Right seek five seconds, further when held).'),
  Reviewed('lib/screens/party/party_strip.dart', 'builder: (context, on, _) => GestureDetector(', 1,
      'Hold to talk: it works for as long as it is held, so it is not a Pressable. It is a focus stop, and holding OK on it holds it.'),
  Reviewed('lib/screens/party/party_strip.dart', 'child: Listener(', 1,
      'The same button: the pointer going down and coming up. With a D-pad that is OK going down and coming up.'),
];

/// Pressables a D-pad passes over (`focusable: false`), each with what it uses instead.
const passedOver = [
  Reviewed('lib/widgets/media_rows.dart', 'focusable: false,', 1, 'A row\'s paging arrows. A D-pad pages a row by moving along it.'),
  Reviewed('lib/widgets/hero_carousel.dart', 'focusable: false,', 1, 'The hero\'s slide dots (4 px each). Slides are browsed in the spotlight: Up from the hero, then Left and Right.'),
  Reviewed('lib/screens/home/continue_watching.dart', 'focusable: false,', 1,
      'The ✓ and × on a Continue watching card, shown under the mouse. Holding OK on the card opens a menu with the same two (t2_controls_test).'),
  Reviewed('lib/screens/player/player_episodes.dart', 'focusable: false,', 1,
      'The tick at the end of an episode row (watched or not), for a pointer. Holding OK on the row marks it (t4_journeys_watched_test).'),
  Reviewed('lib/screens/manga/manga_widgets.dart', 'focusable: false,', 1, 'The × on a manga card. Holding OK on the card removes it.'),
  Reviewed('lib/widgets/audiobook_widgets.dart', 'focusable: false,', 1, 'The × on a Continue listening book. Holding OK on the card removes it.'),
];

/// `autofocus: true` in the files of finished phases.
const autofocus = <Reviewed>[
  Reviewed('lib/screens/details/details_page.dart', 'autofocus: true,', 1,
      'The page-wide key handler (Escape and Backspace leave the page) holding focus while a mouse is in charge. It is not a focus stop: in D-pad mode focus goes to Play.'),
  Reviewed('lib/screens/details/anime_details_page.dart', 'autofocus: true,', 1, 'The same handler on an anime\'s page.'),
  Reviewed('lib/screens/details/person_page.dart', 'autofocus: true,', 2,
      'The same handler on a person\'s page, and the photo viewer\'s (Left and Right turn photos, Escape closes).'),
  Reviewed('lib/screens/player/sources_page.dart', 'autofocus: true,', 1, 'The same handler on the sources page.'),
  Reviewed('lib/screens/profile/account_sheet.dart', 'autofocus: true,', 2,
      'The sign-in sheet opens with the caret in its first box (the code, or the new password), as a form should. Arrows leave the box.'),
  Reviewed('lib/widgets/dialogs/debrid_consent.dart', "TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),", 1,
      'The safe answer is the one Enter gives.'),
  Reviewed('lib/screens/player/player_chrome.dart', 'autofocus: true,', 1,
      'Play: where a D-pad lands when the controls of the player come up. The picture holds focus until then, so it takes nothing by itself.'),
  Reviewed('lib/screens/player/player_page.dart', 'autofocus: true, // with a D-pad, the controls start here when they come up', 1,
      'The same, for the Play button a narrow screen has in the middle of the picture.'),
  Reviewed('lib/screens/player/player_page.dart', 'autofocus: true,', 1,
      'Picture-in-picture on a desktop: the key handler of the small window (Escape, Space). Not a focus stop.'),
  Reviewed('lib/screens/player/subtitle_sync_panel.dart', 'autofocus: true, // with a D-pad the panel opens here', 1,
      'The Play button of the sync panel: where a D-pad lands when the panel opens. Inside a region it is only a mark.'),
  Reviewed('lib/screens/player/subtitle_sync_panel.dart', '? _findBox(autofocus: true)', 1,
      'On a short screen the "find a line" box replaces a row when its button is pressed: the caret goes into the box that was asked for.'),
  Reviewed('lib/screens/shell/intro_screen.dart', 'autofocus: true,', 1,
      'The intro listening for the keys that skip it. Not a focus stop: there is nothing on it to press.'),
  Reviewed('lib/screens/live_tv/live_tv_player_page.dart', 'autofocus: true,', 1,
      'The Live TV picture: focus rests on it while the controls are hidden (Up and Down change channel). Not a focus stop.'),
  Reviewed('lib/screens/servers/server_sign_in.dart', "_Field(controller: _user, label: 'Username', hint: 'Your name on the server', icon: Icons.person_outline_rounded, autofocus: true, onSubmit: _login),", 1,
      'The login step of the server sign-in opens with the caret in Username, as a form should. Arrows leave the box.'),
  Reviewed('lib/screens/servers/servers_page.dart', 'autofocus: true,', 1,
      'The PIN box of a Plex Home profile: the box is the one thing in its dialog.'),
  Reviewed('lib/screens/profile/profile_page.dart', 'autofocus: true,', 3,
      'Three boxes that are about one text field and open with the caret in it: the new display name, the font search, and the word that confirms deleting the account.'),
  Reviewed('lib/screens/audiobooks/audiobook_player_page.dart', 'autofocus: true,', 1,
      'The audiobook player itself: with a mouse in charge focus rests on the page (Left and Right skip 30 seconds). Not a focus stop: a D-pad is put straight on its controls.'),
  Reviewed('lib/screens/music/music_player_page.dart', 'autofocus: true,', 1,
      'The same for the music player (Left and Right seek five seconds).'),
  Reviewed('lib/screens/manga/manga_reader_page.dart', 'autofocus: true,', 1,
      'The reader: focus rests on the page while reading (the arrows turn pages). Not a focus stop.'),
  Reviewed('lib/screens/manga/manga_details_page.dart', 'autofocus: true,', 1,
      'The page-wide key handler of a manga series (Escape leaves), holding focus while a mouse is in charge. Not a focus stop.'),
  Reviewed('lib/screens/audiobooks/audiobooks_page.dart', 'autofocus: true,', 1,
      'Audiobooks opens with the caret in its search box, as Search does. Arrows leave the box.'),
  Reviewed('lib/screens/music/music_ui.dart', "TextField(controller: _name, autofocus: true, maxLength: 80, decoration: _field('Name'), onSubmitted: (_) => _save()),", 1,
      'The "new playlist" box opens with the caret in its name field, as a form should.'),
  Reviewed('lib/screens/party/party_music_room.dart', 'child: Focus(autofocus: true, child: view),', 1,
      'A room\'s music filling the window: the key handler (Back returns to the room, Space pauses) holding focus while a mouse is in charge. Not a focus stop: a D-pad is put on its buttons.'),
  Reviewed('lib/screens/party/party_music_room.dart', 'autofocus: true,', 1,
      'The "music for the room" picker opens with the caret in its search box, as Search does. Arrows leave the box.'),
  Reviewed('lib/screens/party/party_widgets.dart', 'autofocus: true,', 2,
      'Two boxes that are about one text field and open with the caret in it: the link of a picture, and a line of text to change (a name, a bio).'),
  Reviewed('lib/screens/party/room_page.dart', 'autofocus: true,', 2,
      'The "edit room" box opens with the caret in the room\'s name. And the "press a key" box of push to talk: the sentence in it is what waits for the key (a remote\'s Back cancels, as Escape does).'),
  Reviewed('lib/screens/party/rooms_view.dart', "PartyField(controller: _name, label: 'Name', hint: 'Movie night', maxLength: 40, autofocus: true, onSubmit: _create),", 1,
      'Creating a room opens with the caret in its name, as a form should. Arrows leave the box.'),
  Reviewed('lib/screens/party/rooms_view.dart', 'autofocus: true,', 1,
      'Joining by code opens with the caret in the code box: the box is the one thing to fill in.'),
];

void _check(String kind, List<Reviewed> reviewed, {required bool everyFile}) {
  final all = scanInterface();
  final problems = <String>[];
  for (final entry in all.entries) {
    final file = entry.key;
    final phase = phaseOf(file);
    if (!everyFile && phase > donePhase) continue;
    final hits = entry.value.where((h) => h.kind == kind).toList();
    final byLine = <String, List<Hit>>{};
    for (final h in hits) {
      (byLine[h.text] ??= []).add(h);
    }
    for (final group in byLine.entries) {
      final allowed = reviewed.where((r) => r.file == file && r.line == group.key).fold<int>(0, (n, r) => n + r.count);
      if (group.value.length > allowed) {
        problems.add('$file: ${group.value.length} x "${group.key}" (lines ${group.value.map((h) => h.line).join(', ')}), $allowed reviewed');
      }
    }
  }
  for (final r in reviewed) {
    final found = (all[r.file] ?? const <Hit>[]).where((h) => h.kind == kind && h.text == r.line).length;
    if (found < r.count) problems.add('${r.file}: the reviewed "${r.line}" is listed ${r.count} x but is there $found x (take it off the list)');
  }
  expect(problems, isEmpty, reason: 'Unreviewed "$kind" in the interface. Make it a Pressable (lib/widgets/common.dart), or list it in test/dpad/guard_test.dart with its reason:\n${problems.join('\n')}');
}

void main() {
  test('every interface file belongs to a phase of the plan', () {
    final lost = [for (final f in interfaceFiles()) if (phaseOf(f) == 0) f];
    expect(lost, isEmpty, reason: 'Say which phase handles these (test/dpad/bed/source_scan.dart)');
  });

  test('no tap detector but Pressable, in the files of finished phases', () => _check('raw tap', rawTaps, everyFile: false));

  test('every control a D-pad passes over is listed with what it uses instead', () => _check('passed over', passedOver, everyFile: true));

  test('no unreviewed autofocus, in the files of finished phases', () => _check('autofocus', autofocus, everyFile: false));

  test('the focus kit never fades or blurs (the video is a hole those would paint over)', () {
    final bad = <String>[];
    for (final f in Directory('lib/dpad').listSync().whereType<File>()) {
      final src = f.readAsStringSync();
      for (final w in const ['Opacity(', 'AnimatedOpacity(', 'FadeTransition(', 'BackdropFilter(', 'ShaderMask(', 'saveLayer(']) {
        if (src.contains(w)) bad.add('${f.path}: $w');
      }
    }
    expect(bad, isEmpty);
  });

  test('the tests and the kit keep out of lib/services and lib/models', () {
    // The one way in that is allowed: the bed names a few plain data types (a song, a manga and
    // its chapters, an audiobook and its chapters) so it can hand made-up ones to the pages that take one. Their shapes
    // came from the analyzer's own messages, not from reading the files. Nothing else in the
    // tests, the kit or the tool may import from either folder.
    const allowed = {
      "import 'package:vyse_tv/models/audiobook/audiobook_model.dart';",
      "import 'package:vyse_tv/models/manga/manga.dart';",
      "import 'package:vyse_tv/models/manga/manga_chapter.dart';",
      "import 'package:vyse_tv/models/music/music_track.dart';",
    };
    final bad = <String>[];
    for (final root in const ['test/dpad', 'lib/dpad', 'tool']) {
      for (final f in Directory(root).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final bed = f.path.replaceAll('\\', '/').endsWith('test/dpad/harness.dart');
        for (final line in f.readAsLinesSync()) {
          if (line.startsWith('import') && (line.contains('vyse_tv/services/') || line.contains('vyse_tv/models/') || line.contains("'../../services/") || line.contains("'../../models/"))) {
            if (bed && allowed.contains(line.trim())) continue;
            bad.add('${f.path}: $line');
          }
        }
      }
    }
    expect(bad, isEmpty);
  });
}
