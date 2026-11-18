// T4: the path to a title, key by key. Home to a title to an episode to the list of sources;
// searching; and every dialog on the way opened and closed with focus put back.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/torrent_file_ask.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/screens/profile/account_sheet.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/details/person_page.dart';
import 'package:vyse_tv/screens/search/search_page.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/dialogs/debrid_consent.dart';
import 'package:vyse_tv/screens/details/episode_explorer.dart';
import 'package:vyse_tv/widgets/dialogs/p2p_consent.dart';
import 'package:vyse_tv/widgets/dialogs/torrent_file_dialog.dart';

import 'harness.dart';

/// The Material control with focus, by its words ("Cancel"), or null.
String? _materialFocus() {
  final node = DpadRoot.debugRinged;
  if (node?.context == null) return null;
  String? text;
  void visit(Element e) {
    if (text != null) return;
    if (e.widget is Text) text = (e.widget as Text).data;
    e.visitChildren(visit);
  }

  (node!.context! as Element).visitChildren(visit);
  return text;
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('Home to a film: its page starts on Play; cast, a person, and all the way back', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t, times: 3);
    expect(Bed.focused(), contains('Hot right now'));
    final card = Bed.focused();
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    expect(Bed.focused(), contains("'Play'"), reason: 'a title\'s page starts on Play, not on Back');
    expect(Bed.focusInView(), isTrue);

    // along the buttons, then down to the tabs and the cast
    await Bed.right(t);
    expect(Bed.focused(), contains('_SaveButton'));
    await Bed.left(t);
    expect(Bed.focused(), contains("'Play'"));
    // up the page: the genre chips, then Back at the top
    await Bed.up(t);
    expect(Bed.focused(), contains('_GenreChip'));
    await Bed.up(t, times: 3);
    expect(Bed.focused(), contains("'Back'"), reason: 'Back is the top of the page');
    for (var i = 0; i < 6 && !Bed.focused().contains("'Cast'"); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains("'Cast'"), reason: 'the tabs are under the buttons');
    await Bed.down(t);
    expect(Bed.focused(), contains('Starring'));
    expect(Bed.focusInView(), isTrue);
    await Bed.right(t, times: 2);
    final actor = Bed.focused();
    await Bed.ok(t);
    expect(find.byType(PersonPage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));

    await Bed.back(t);
    expect(find.byType(PersonPage), findsNothing);
    expect(Bed.focused(), actor, reason: 'R6: back on the actor you opened');
    await Bed.back(t);
    expect(find.byType(DetailsPage), findsNothing);
    expect(Bed.focused(), card, reason: 'R6: back on the card you opened');
    expect(find.byType(HomePage), findsOneWidget);
  }, variant: screen);

  testWidgets('a film\'s tabs: OK switches, and what the tab shows is under it', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.catalogue[0]));
    await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    await Bed.down(t);
    await Bed.right(t, times: 2);
    expect(Bed.focused(), contains("'More like this'"));
    await Bed.ok(t);
    await Bed.down(t);
    expect(Bed.focused(), contains('PosterCard'), reason: 'the recommendations are reachable under their tab');
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    expect(find.byType(DetailsPage, skipOffstage: false), findsNWidgets(2), reason: 'a recommendation opens its own page over this one');
    expect(Bed.focused(), contains("'Play'"));
    await Bed.back(t);
    expect(Bed.focused(), contains('PosterCard'));
  }, variant: screen);

  testWidgets('a series: Left and Right pick the episode from its Play button; the seasons are to the left; OK leads to sources', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.catalogue[81]));
    await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    await Bed.down(t, times: 2);
    expect(find.byType(EpisodeExplorer), findsOneWidget);
    // into the explorer: down to the seasons, and Right from there to its own Play button for
    // the episode on show (a column's foot no longer leads diagonally into the episode)
    for (var i = 0; i < 6 && !Bed.focused().contains('_SeasonNumber'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('_SeasonNumber'));
    await Bed.right(t);
    expect(Bed.focused(), contains("'Play E1'"));
    expect(find.textContaining('Chapter 1:'), findsWidgets);
    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('Chapter 2:'), findsWidgets, reason: 'Right moves to the next episode');
    expect(Bed.focused(), contains("'Play E2'"), reason: 'focus stays on Play');
    await Bed.left(t);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains("'Play E1'"));
    await Bed.left(t);
    expect(Bed.focused(), isNot(contains('Play E')), reason: 'Left at the first episode leaves for the seasons');
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  testWidgets('the sources page opens with focus in it and Back leaves it', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.catalogue[0]));
    await Bed.down(t);
    final nav = Bed.sectionNavigator(t);
    nav.push(MaterialPageRoute<void>(builder: (_) => SourcesPage(media: Bed.catalogue[0])));
    await Bed.settle(t);
    expect(find.byType(SourcesPage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'), reason: 'R1 on the sources page');
    expect(Bed.focusInView(), isTrue);
    await Bed.down(t, times: 2);
    expect(Bed.focused(), isNot('nothing'));
    await Bed.back(t);
    expect(find.byType(SourcesPage), findsNothing);
    expect(Bed.focused(), contains("'Play'"));
  }, variant: screen);

  testWidgets('Search: type, Down to the results, open one; Back steps off the box before it leaves the page (R10)', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'search');
    await t.pump(const Duration(milliseconds: 500));
    final box = t.widget<EditableText>(find.byType(EditableText).first).focusNode;
    expect(box.hasPrimaryFocus, isTrue, reason: 'Search opens ready to type, as before');

    t.testTextInput.enterText('night');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await Bed.settle(t);
    expect(find.byType(SearchPage), findsOneWidget);
    await Bed.left(t);
    expect(box.hasPrimaryFocus, isTrue, reason: 'Left moves the caret while there is text to its left');
    await Bed.down(t);
    expect(box.hasPrimaryFocus, isFalse, reason: 'Down leaves the box');
    expect(Bed.focused(), isNot('nothing'));
    expect(Bed.focusInView(), isTrue);
    // back up into the box, then Back: first the text goes, then focus steps off, then the navbar
    await Bed.up(t, times: 6);
    expect(box.hasPrimaryFocus, isTrue, reason: 'Up from the results returns to the box');
    await Bed.back(t);
    // (the word itself is still on the page, as a recent search)
    expect(t.widget<EditableText>(find.byType(EditableText).first).controller.text, '', reason: 'Escape clears the box first, as it always did');
    expect(box.hasPrimaryFocus, isTrue);
    await Bed.back(t);
    expect(box.hasPrimaryFocus, isFalse, reason: 'Back stops the typing: focus steps off the box');
    expect(Bed.focused(), isNot('nothing'));
    expect(find.byType(SearchPage), findsOneWidget, reason: 'and the page is still there');
    await Bed.back(t);
    expect(Bed.focused(), contains("_RailItem in SideRail 'Search'"), reason: 'the next Back goes to the navbar');
  }, variant: screen);

  group('dialogs and sheets: focus goes in, stays in, Back closes, focus comes back', () {
    Future<void> opened(WidgetTester t, Future<Object?> Function(BuildContext context) open, {required String first, required Type dialog}) async {
      await Bed.pumpShell(t);
      await Bed.down(t, times: 2);
      final from = Bed.focused();
      expect(from, contains('Continue watching'));
      final context = FocusManager.instance.primaryFocus!.context!;
      Object? result = 'open';
      open(context).then((r) => result = r);
      await Bed.settle(t, rounds: 4);
      expect(find.byType(dialog), findsOneWidget);
      expect(_materialFocus() ?? Bed.focused(), contains(first), reason: 'focus goes to its first sensible control');
      // arrows cannot leave it
      await Bed.up(t, times: 4);
      await Bed.left(t, times: 6);
      await Bed.down(t, times: 8);
      await Bed.right(t, times: 6);
      expect(find.byType(dialog), findsOneWidget);
      expect(Bed.focused().contains('Continue watching') || Bed.focused().contains('SideRail'), isFalse, reason: 'focus got out of the dialog to ${Bed.focused()}');
      expect(_materialFocus() != null || Bed.focused() != 'nothing', isTrue, reason: 'R1 inside the dialog');
      await Bed.back(t);
      expect(find.byType(dialog), findsNothing, reason: 'Back closes it');
      expect(result, isNot('open'));
      expect(Bed.focused(), from, reason: 'focus is back on what was focused before it opened');
      expect(find.byType(HomePage), findsOneWidget, reason: 'and Back did nothing else');
    }

    testWidgets('the P2P question', (t) async {
      final was = AppSettings.p2pStreaming.value;
      AppSettings.p2pStreaming.value = false;
      addTearDown(() => AppSettings.p2pStreaming.value = was);
      await opened(t, (c) => allowP2p(c), first: 'Cancel', dialog: AlertDialog);
      expect(AppSettings.p2pStreaming.value, isFalse, reason: 'closing it is not allowing');
    }, variant: screen);

    testWidgets('the P2P question: Right to Allow, OK allows', (t) async {
      final was = AppSettings.p2pStreaming.value;
      AppSettings.p2pStreaming.value = false;
      addTearDown(() => AppSettings.p2pStreaming.value = was);
      await Bed.pumpShell(t);
      await Bed.down(t, times: 2);
      final from = Bed.focused();
      bool? answer;
      allowP2p(FocusManager.instance.primaryFocus!.context!).then((r) => answer = r);
      await Bed.settle(t, rounds: 4);
      expect(_materialFocus(), 'Cancel');
      await Bed.right(t);
      expect(_materialFocus(), 'Allow');
      await Bed.ok(t);
      expect(answer, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(Bed.focused(), from);
    }, variant: screen);

    testWidgets('the debrid question', (t) async {
      await opened(t, (c) => allowDebridInRoom(c), first: 'Cancel', dialog: AlertDialog);
    }, variant: screen);

    testWidgets('choosing a file in a torrent', (t) async {
      final List<TorrentFileChoice> files = [for (var i = 1; i <= 6; i++) (name: 'Episode $i.mkv', size: 700000000 + i)];
      await opened(t, (c) => askTorrentFile(c, files, torrent: 'A season pack'), first: 'Episode 1', dialog: Dialog);
    }, variant: screen);

    testWidgets('the sign-in sheet: opens in its first box, arrows reach its buttons, Back closes', (t) async {
      await Bed.pumpShell(t);
      await Bed.down(t, times: 2);
      final from = Bed.focused();
      showAccountSheet(FocusManager.instance.primaryFocus!.context!);
      await Bed.settle(t, rounds: 4);
      final box = FocusManager.instance.primaryFocus!;
      expect(box.context!.findAncestorStateOfType<EditableTextState>(), isNotNull, reason: 'the caret is in the first box');
      final seen = <String>{};
      for (var i = 0; i < 12; i++) {
        await Bed.down(t);
        seen.add(_materialFocus() ?? Bed.focused());
      }
      expect(seen.any((s) => s.contains('Continue watching') || s.contains('SideRail')), isFalse, reason: 'focus got out of the sheet');
      expect(seen.length, greaterThan(1), reason: 'Down leaves the box for what is under it');
      // Back: off the box first if it is in one, then the sheet closes
      await Bed.back(t);
      if (find.byType(Dialog).evaluate().isNotEmpty || find.byType(BottomSheet).evaluate().isNotEmpty) await Bed.back(t);
      expect(find.byType(Dialog), findsNothing);
      expect(Bed.focused(), from);
    }, variant: screen);
  });

  testWidgets('the photo viewer on a person\'s page: Left and Right turn photos, Back closes', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, const PersonPage(id: 500, name: 'Mara Ellison', profilePath: '/f500.jpg'));
    await Bed.down(t);
    for (var i = 0; i < 12 && !Bed.focused().contains('Photos'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('Photos'));
    final photo = Bed.focused();
    await Bed.ok(t);
    expect(find.byType(PageView), findsOneWidget, reason: 'OK on a photo opens the viewer');
    expect(Bed.focused(), isNot('nothing'), reason: 'R1 in the viewer');
    final pages = t.widget<PageView>(find.byType(PageView)).controller!;
    final opened = pages.page!;
    await Bed.right(t);
    await Bed.settle(t, rounds: 3);
    expect(pages.page, opened + 1, reason: 'Right turns to the next photo');
    await Bed.left(t);
    await Bed.settle(t, rounds: 3);
    expect(pages.page, opened);
    await Bed.back(t);
    expect(find.byType(PageView), findsNothing);
    expect(Bed.focused(), photo);
  }, variant: screen);

  testWidgets('a toast is never a focus stop', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t, times: 2);
    final from = Bed.focused();
    showToast(FocusManager.instance.primaryFocus!.context!, const Text('Saved'), onTap: () {});
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Saved'), findsOneWidget);
    expect(Bed.focused(), from);
    await Bed.up(t);
    await Bed.down(t);
    await Bed.left(t, times: 3);
    await Bed.right(t, times: 3);
    expect(Bed.focused(), isNot(contains('Saved')));
    await t.pump(const Duration(seconds: 6));
  }, variant: screen);
}
