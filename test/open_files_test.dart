import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/open_files.dart';

int _softLimit() {
  final line = File('/proc/self/limits').readAsLinesSync().firstWhere((l) => l.startsWith('Max open files'));
  final v = line.split(RegExp(r'\s{2,}'))[1].trim();
  return v == 'unlimited' ? 1 << 30 : int.parse(v);
}

void main() {
  test('the open-file limit is raised to what the system allows, up to 65 536', () {
    final hard =
        int.tryParse(File('/proc/self/limits').readAsLinesSync().firstWhere((l) => l.startsWith('Max open files')).split(RegExp(r'\s{2,}'))[2].trim()) ??
        1 << 30;
    final now = raiseOpenFileLimit();
    expect(now, greaterThanOrEqualTo(hard < 65536 ? hard : 65536));
    expect(_softLimit(), now);
    expect(raiseOpenFileLimit(), now); // again: nothing changes
  }, skip: Platform.isLinux ? false : 'Linux only');

  test(
    'a thousand sockets can be open at once afterwards',
    () async {
      raiseOpenFileLimit();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((s) => s.listen((_) {}));
      final open = <Socket>[];
      for (var i = 0; i < 1300; i++) {
        open.add(await Socket.connect(InternetAddress.loopbackIPv4, server.port));
      }
      expect(open.length, 1300); // (at the default limit of 1024 this fails with "Too many open files")
      for (final s in open) {
        s.destroy();
      }
    },
    skip: Platform.isLinux ? false : 'Linux only',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
