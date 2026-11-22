// The account sync's live side (lib/data/account/account_sync.dart): what it does with the
// account's news of a change while this device is still changing the same thing.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/account/account_sync.dart';

void main() {
  late ValueNotifier<int> value;
  late List<(int, int, Completer<void>)> sent; // what went out: the value, its time, its answer

  setUp(() {
    value = ValueNotifier<int>(12);
    sent = [];
    AccountSync.debugSources([
      SyncSource(
        kind: 'test_settings',
        snapshot: () async => {
          'lift': {'v': value.value},
        },
        apply: (key, data) async => value.value = (data!['v'] as num).toInt(),
        changes: value,
      ),
    ]);
    AccountSync.debugSignIn('someone', send: (kind, key, body) {
      final answer = Completer<void>();
      sent.add((((body['data'] as Map)['v'] as num).toInt(), body['updated_ms'] as int, answer));
      return answer.future;
    });
  });
  tearDown(() => AccountSync.debugSignIn(null));

  Future<void> wait([int ms = 400]) => Future<void>.delayed(Duration(milliseconds: ms));

  // A tester stepped a number up to 14% and watched it drop to 13% by itself. Each step is sent
  // to the account, and the account tells every device about it, this one included. That news
  // of 13 can arrive before the answer to the request that sent it, and by then the number
  // here was 14.
  test("the account's news of this device's own change is never put back over a newer one", () async {
    value.value = 13;
    await wait();
    expect(sent.map((s) => s.$1), [13], reason: '13 is on its way, and its answer is slow');

    value.value = 14;
    AccountSync.debugRemote('test_settings', 'lift', {'v': 13}, sent[0].$2);
    await wait(0);
    expect(value.value, 14, reason: 'the news of 13 is this device hearing itself');

    sent[0].$3.complete();
    await wait();
    expect(sent.map((s) => s.$1), [13, 14], reason: '14 goes out once 13 has been answered: one at a time');
    AccountSync.debugRemote('test_settings', 'lift', {'v': 13}, sent[0].$2);
    AccountSync.debugRemote('test_settings', 'lift', {'v': 14}, sent[1].$2);
    await wait(0);
    expect(value.value, 14);
    sent[1].$3.complete();
  });

  test("another device's later change still arrives", () async {
    value.value = 13;
    await wait();
    sent[0].$3.complete();
    await wait(0);
    AccountSync.debugRemote('test_settings', 'lift', {'v': 30}, sent[0].$2 + 5000);
    await wait(0);
    expect(value.value, 30);
    await wait();
    expect(sent.map((s) => s.$1), [13], reason: 'and is not sent straight back');
  });

  test('a change that could not be sent goes out again with the next one', () async {
    value.value = 13;
    await wait();
    sent[0].$3.completeError(StateError('no network'));
    await wait(0);
    value.value = 14;
    await wait();
    expect(sent.map((s) => s.$1), [13, 14]);
    sent[1].$3.complete();
    // and had 13 been taken for sent, its news would have been ignored for good: it is not
    value.value = 15;
    await wait();
    expect(sent.map((s) => s.$1), [13, 14, 15]);
    sent[2].$3.complete();
  });

  // Watch progress combines (each episode's watched mark from whichever device made it last):
  // a copy from the account that is older than this device's may still hold a mark this device
  // lacks. It used to be ignored, and the mark was lost on both.
  group('a kind that combines', () {
    Map<String, dynamic> both(Map<String, dynamic> a, Map<String, dynamic> b) => {
      'eps': ({...(a['eps'] as List), ...(b['eps'] as List)}.toList()..sort()),
      't': [a['t'] as int, b['t'] as int].reduce((x, y) => x > y ? x : y),
    };
    late ValueNotifier<Map<String, dynamic>> show;
    late List<Map<String, dynamic>> pushed;

    setUp(() {
      show = ValueNotifier<Map<String, dynamic>>({'eps': [1], 't': 10});
      pushed = [];
      AccountSync.debugSources([
        SyncSource(
          kind: 'test_progress',
          snapshot: () async => {'show': show.value},
          apply: (key, data) async => show.value = both(show.value, data!),
          changes: show,
          timeOf: (d) => (d['t'] as num?)?.toInt(),
          merge: both,
        ),
      ]);
      AccountSync.debugSignIn('someone', send: (kind, key, body) async {
        if (kind == 'test_progress') pushed.add(Map<String, dynamic>.from(body['data'] as Map));
      });
    });

    test('an older copy from the account is combined, and the result goes up', () async {
      show.value = {'eps': [1], 't': 10};
      await wait();
      expect(pushed, hasLength(1));
      AccountSync.debugRemote('test_progress', 'show', {'eps': [2], 't': 5}, 5);
      await wait();
      expect(show.value, {'eps': [1, 2], 't': 10}, reason: 'its episode 2 is kept here');
      expect(pushed.last, {'eps': [1, 2], 't': 10}, reason: 'and the account gets both');
      final n = pushed.length;
      AccountSync.debugRemote('test_progress', 'show', {'eps': [1, 2], 't': 10}, 10);
      await wait();
      expect(pushed, hasLength(n), reason: 'its own news coming back sends nothing more');
    });
  });
}
