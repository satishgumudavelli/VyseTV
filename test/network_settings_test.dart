import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';

void main() {
  test('the network choices exist with their defaults', () {
    expect(AppSettings.netWarp.key, 'device.net.warp');
    expect(AppSettings.netWarp.fallback, false);
    expect(AppSettings.netDoh.fallback, 'off');
    expect(AppSettings.netDohUrl.fallback, '');
    expect(AppSettings.netAntiDpi.fallback, false);
    expect(AppSettings.netAntiDpiPreset.fallback, 'split_disorder');
    expect(AppSettings.netAntiDpiArgs.fallback, '');
  });

  test('they stay on this device: account sync never carries them (a phone must not switch a TV\'s WARP on)', () {
    final synced = AppSettings.synced.map((s) => s.key).toSet();
    for (final s in [
      AppSettings.netWarp,
      AppSettings.netDoh,
      AppSettings.netDohUrl,
      AppSettings.netAntiDpi,
      AppSettings.netAntiDpiPreset,
      AppSettings.netAntiDpiArgs,
    ]) {
      expect(synced, isNot(contains(s.key)), reason: s.key);
    }
  });

  test('Reset puts them back to the defaults', () {
    AppSettings.netWarp.value = true;
    AppSettings.netDoh.value = 'google';
    AppSettings.netAntiDpiArgs.value = '--split 2';
    AppSettings.resetPreferences();
    expect(AppSettings.netWarp.value, false);
    expect(AppSettings.netDoh.value, 'off');
    expect(AppSettings.netAntiDpiArgs.value, '');
  });
}
