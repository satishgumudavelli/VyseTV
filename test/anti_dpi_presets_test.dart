import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/network/anti_dpi_presets.dart';

void main() {
  test('four presets, the recommended one first and the default', () {
    expect(antiDpiPresets.map((p) => p.id), ['split_disorder', 'disorder', 'split', 'fake_oob']);
    expect(antiDpiPresets.first.args, defaultAntiDpiArgs);
    expect(defaultAntiDpiArgs, '--split 1 --disorder 1 --auto=torst');
    expect(antiDpiPresetById('zzz').id, 'split_disorder');
    expect(antiDpiPresets.every((p) => p.description.isNotEmpty && p.name.isNotEmpty), isTrue);
  });

  test('which parameters run: the hand-edited ones, else the preset', () {
    expect(antiDpiArgsFor('split', ''), '--split 1');
    expect(antiDpiArgsFor('split', '  '), '--split 1');
    expect(antiDpiArgsFor('custom', ' --split 2 '), '--split 2');
    expect(antiDpiArgsFor('nope', ''), defaultAntiDpiArgs);
  });

  test('parameters: nothing that sets the address or port; printable; at most 512', () {
    expect(validateAntiDpiArgs(''), isNull);
    expect(validateAntiDpiArgs('--split 1 --disorder 1 --auto=torst'), isNull);
    expect(validateAntiDpiArgs('-s 1 -q 1 -Y'), isNull);
    for (final bad in [
      '-p 1',
      '--port 80',
      '--port=80',
      '-i 0.0.0.0',
      '--ip 1.2.3.4',
      '--ip=1.2.3.4',
      '-I 1.2.3.4',
      '--conn-ip 1.2.3.4',
      '--split 1 -p80',
      '-i0.0.0.0',
    ]) {
      expect(validateAntiDpiArgs(bad), isNotNull, reason: bad);
    }
    expect(validateAntiDpiArgs('--split 1\u0007'), isNotNull);
    expect(validateAntiDpiArgs('--split é'), isNotNull);
    expect(validateAntiDpiArgs('a' * 513), isNotNull);
    expect(validateAntiDpiArgs('a' * 512), isNull);
  });
}
