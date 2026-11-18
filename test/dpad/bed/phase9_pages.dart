// Party (phase 9), opened ready to be walked or photographed. Party needs an account and its
// server; the bed has neither, so what the server would have sent is put in by hand: who is
// signed in, their friends and requests, the rooms that are open, their conversations, and
// the room they are in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/account/account.dart';
import 'package:vyse_tv/data/party/dms.dart';
import 'package:vyse_tv/data/party/friends.dart';
import 'package:vyse_tv/data/party/party.dart';
import 'package:vyse_tv/data/party/rooms.dart';
import 'package:vyse_tv/screens/party/dm_page.dart';
import 'package:vyse_tv/screens/party/party_widgets.dart';
import 'package:vyse_tv/screens/party/room_page.dart';
import 'package:vyse_tv/screens/party/rooms_view.dart';

import '../harness.dart';

typedef Opener = Future<void> Function(WidgetTester t);

const me = AccountUser(id: 'me', email: 'me@vyse.example', username: 'ayla', name: 'Ayla Brandt', verified: true);

PartyProfile person(int n, {String presence = 'online', String relation = 'friend'}) => PartyProfile(
  id: 'u$n',
  username: const ['mara', 'tobias', 'ines', 'kofi', 'lena', 'omar', 'yuki', 'sam'][n % 8],
  name: const ['Mara Ellison', 'Tobias Reed', 'Ines Calder', 'Kofi Mensah', 'Lena Roth', 'Omar Haddad', 'Yuki Tanaka', 'Sam Okafor'][n % 8],
  bio: 'A made-up person.',
  presence: presence,
  relation: relation,
);

PartyRoom room(int n, {bool mine = false}) => PartyRoom(
  id: 'room$n',
  name: const ['Movie night', 'Anime club', 'Late shift', 'Sunday football'][n % 4],
  topic: 'A made-up room',
  owner: mine ? 'me' : 'u$n',
  limit: 6,
  members: [
    if (mine) const RoomMember(id: 'me', username: 'ayla', name: 'Ayla Brandt', presence: 'online', owner: true),
    for (var i = 0; i < 3; i++) RoomMember(id: 'u${n + i}', username: person(n + i).username, name: person(n + i).name, presence: 'online', owner: !mine && i == 0),
  ],
);

/// Signs the made-up user in and fills Party with made-up people, rooms and conversations.
/// Every test that calls this must end with [signOut].
void signIn({bool inRoom = false}) {
  Account.user.value = AccountUser(id: me.id, email: me.email, username: me.username, name: me.name, verified: true, termsAt: DateTime(2026, 1, 1), created: DateTime(2025, 6, 1));
  Friends.lists.value = FriendLists(
    friends: [for (var i = 0; i < 5; i++) person(i, presence: i < 3 ? 'online' : 'offline')],
    incoming: [person(5, relation: 'incoming'), person(6, relation: 'incoming')],
    outgoing: [person(7, relation: 'outgoing')],
  );
  Rooms.public.value = [for (var i = 0; i < 4; i++) room(i)];
  Rooms.mine.value = inRoom ? room(0, mine: true) : null;
  Dms.threads.value = [
    for (var i = 0; i < 3; i++)
      DmThread(
        partner: person(i),
        last: DmMessage(id: 'm$i', sender: 'u$i', receiver: 'me', body: 'A made-up message, number ${i + 1}.', created: DateTime(2026, 11, 15, 20, i)),
        unread: i == 0 ? 2 : 0,
        lastAt: DateTime(2026, 11, 15, 20, i),
      ),
  ];
}

void signOut() {
  Rooms.mine.value = null;
  Rooms.public.value = const [];
  Friends.lists.value = FriendLists.empty;
  Dms.threads.value = const [];
  Account.user.value = null;
}

Future<void> _party(WidgetTester t, {bool inRoom = false}) async {
  signIn(inRoom: inRoom);
  await Bed.pumpShell(t);
  await Bed.openSection(t, 'party');
  await Bed.settle(t, rounds: 5);
}

BuildContext _page(WidgetTester t) => Bed.sectionNavigator(t).context;

final Map<String, Opener> phase9Pages = {
  'Party': (t) => _party(t),
  'Party, a conversation': (t) async {
    await _party(t);
    openDm(Bed.sectionNavigator(t), person(0));
    await Bed.settle(t, rounds: 5);
    expect(find.byType(DmPage), findsOneWidget);
  },
  'Party, a profile': (t) async {
    await _party(t);
    showPartyProfile(_page(t), 'u1', initial: person(1)).ignore();
    await Bed.settle(t, rounds: 5);
  },
  'Party, creating a room': (t) async {
    await _party(t);
    showCreateRoomDialog(_page(t)).ignore();
    await Bed.settle(t, rounds: 5);
  },
  'Party, joining by code': (t) async {
    await _party(t);
    showJoinCodeDialog(_page(t)).ignore();
    await Bed.settle(t, rounds: 5);
  },
  'Party, a room': (t) async {
    await _party(t, inRoom: true);
    openRoom(Bed.sectionNavigator(t)).ignore();
    await Bed.settle(t, rounds: 6);
    expect(find.byType(RoomPage), findsOneWidget);
  },
};
