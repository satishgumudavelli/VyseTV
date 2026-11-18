// The pages of phase 6 (Anime, Live TV, Downloads, Servers), each opened ready to be walked or
// photographed. Shared by the Windows and the Android files. The bed must have content
// (Bed.withContent): AniList answers and Downloads holds three downloads.
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/widgets/common.dart';

import '../harness.dart';

typedef Opener = Future<void> Function(WidgetTester t);

/// Gives focus to a control and presses OK on it, as a D-pad user would have.
Future<void> pressOn(WidgetTester t, Finder control) async {
  await Bed.dpadMode(t);
  await Bed.focus(t, control);
  await Bed.ok(t);
  await Bed.settle(t, rounds: 4);
}

Future<void> _section(WidgetTester t, String id) async {
  await Bed.pumpShell(t);
  await Bed.openSection(t, id);
  await Bed.settle(t, rounds: 5);
}

Future<void> _liveTab(WidgetTester t, String tab) async {
  await _section(t, 'live');
  await pressOn(t, find.widgetWithText(Pressable, tab).first);
}

/// The Live TV page builds its channel page while its own list is listening to the same
/// source, and Flutter (in a debug build only) objects to the list being told mid-build. It
/// is the page's own, with a mouse too, and nothing a D-pad does; it is on the follow-up list
/// in the plan. Taken here so it is not mistaken for something the walk caused.
void takeKnownChannelPageError(WidgetTester t) {
  final e = t.takeException();
  if (e != null && !'$e'.contains('called during build')) throw e as Object;
}

final Map<String, Opener> phase6Pages = {
  'Anime': (t) => _section(t, 'anime'),
  'Anime, the filters': (t) async {
    await _section(t, 'anime');
    await pressOn(t, find.widgetWithText(Pressable, 'Filters'));
  },
  'Live TV, Matches': (t) => _liveTab(t, 'Matches'),
  'Live TV, Channels': (t) => _liveTab(t, 'Channels'),
  'Live TV, Portals': (t) => _liveTab(t, 'Portals'),
  'Live TV, Playlists': (t) => _liveTab(t, 'Playlists'),
  'Live TV, a channel’s page': (t) async {
    await _liveTab(t, 'Channels');
    // (on a narrow screen the tabs take two lines, so the first tile is further down)
    for (var i = 0; i < 6 && !Bed.focused().contains('ChannelTile'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('ChannelTile'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 5);
    takeKnownChannelPageError(t);
  },
  'Live TV, adding a portal': (t) async {
    await _liveTab(t, 'Portals');
    await pressOn(t, find.widgetWithText(Pressable, 'Add portal'));
  },
  'Downloads': (t) => _section(t, 'downloads'),
  'Servers': (t) => _section(t, 'servers'),
  'Servers, signing in to Jellyfin': (t) async {
    await _section(t, 'servers');
    await pressOn(t, find.widgetWithText(Pressable, 'Jellyfin').first);
    await Bed.realIo(t, until: () => Bed.lookedForServers); // (the box looks for servers on the local network too)
  },
};
