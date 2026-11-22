// A watch party guest finds the host's subtitle in its own list (lib/data/subtitles/subtitle_match.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/subtitles/subtitle_match.dart';
import 'package:vyse_tv/data/subtitles/subtitles.dart';

SubtitleTrack t(String id, String provider, String lang, String url, {String release = '', bool translated = false}) => SubtitleTrack(
      id: id,
      provider: provider,
      lang: lang,
      language: lang == 'en' ? 'English' : (lang == 'es' ? 'Spanish' : lang),
      release: release,
      url: url,
      translated: translated,
    );

Map<String, dynamic> json(SubtitleTrack s) => {
      'id': s.id,
      'provider': s.provider,
      'lang': s.lang,
      'language': s.language,
      'release': s.release,
      'url': s.url,
      'format': s.format,
      'translated': s.translated,
    };

void main() {
  // the host's Cinejoy file: its link only works for the host
  final host = t('cinejoy-2', 'Cinejoy', 'en', 'https://subs.example/host-token/2.srt', release: 'English SDH');

  test('the room state round-trips into a track', () {
    final back = hostSubtitle(json(host));
    expect(back.url, host.url);
    expect(back.provider, 'Cinejoy');
    expect(back.release, 'English SDH');
  });

  test("the guest's own link to the same file is used, not the host's", () {
    final mine = [
      t('cinejoy-1', 'Cinejoy', 'en', 'https://subs.example/guest-token/1.srt', release: 'English'),
      t('cinejoy-2', 'Cinejoy', 'en', 'https://subs.example/guest-token/2.srt', release: 'English SDH'),
      t('os-9', 'OpenSubtitles', 'en', 'https://os.example/9.srt', release: 'English SDH'),
    ];
    expect(subtitleCopy(host, mine)?.url, 'https://subs.example/guest-token/2.srt');
  });

  test('the same name wins over the same place in the list', () {
    final mine = [
      t('cinejoy-1', 'Cinejoy', 'en', 'https://subs.example/g/1.srt', release: 'English SDH'),
      t('cinejoy-2', 'Cinejoy', 'en', 'https://subs.example/g/2.srt', release: 'English'),
    ];
    expect(subtitleCopy(host, mine)?.url, 'https://subs.example/g/1.srt');
  });

  test('a link that works anywhere is found by the link itself', () {
    final os = t('os-9', 'OpenSubtitles', 'en', 'https://os.example/9.srt', release: 'Show.S01E01.WEB');
    final mine = [t('os-9b', 'OpenSubtitles', 'en', 'https://os.example/9.srt', release: 'Show S01E01')];
    expect(subtitleCopy(os, mine), mine.single);
  });

  test('nothing from another provider, language, or translation counts as the same file', () {
    final mine = [
      t('cinejoy-2', 'Cinejoy', 'es', 'https://subs.example/g/2.srt', release: 'English SDH'),
      t('cinejoy-2', 'SubtitleCat', 'en', 'https://cat.example/2.srt', release: 'English SDH'),
      t('cinejoy-2', 'Cinejoy', 'en', 'https://subs.example/g/2.srt#tl=en', release: 'English SDH', translated: true),
    ];
    expect(subtitleCopy(host, mine), isNull);
  });

  test('a file with no name is matched by its place only when the host\'s has no name either', () {
    final bare = t('cinejoy-3', 'Cinejoy', 'en', 'https://subs.example/h/3.srt');
    final mine = [t('cinejoy-3', 'Cinejoy', 'en', 'https://subs.example/g/3.srt')];
    expect(subtitleCopy(bare, mine), mine.single);
    expect(subtitleCopy(host, [t('cinejoy-2', 'Cinejoy', 'en', 'https://subs.example/g/2.srt', release: 'Other')]), isNull);
  });

  test("a link that already failed here isn't offered again", () {
    final mine = [t('cinejoy-2', 'Cinejoy', 'en', 'https://subs.example/g/2.srt', release: 'English SDH')];
    expect(subtitleCopy(host, mine, failed: {'https://subs.example/g/2.srt'}), isNull);
  });

  test("when the host's file isn't here: another in its language, inside the video first", () {
    final mine = [
      t('x', 'SubtitleCat', 'en', 'https://cat.example/en.srt#tl=en', translated: true),
      t('y', 'OpenSubtitles', 'en', 'https://os.example/en.srt'),
      t('z', 'Cinejoy', 'en', 'https://subs.example/g/9.srt', release: 'English'),
      t('b', 'Built in', 'en', 'mpv-sid:2', release: 'Forced'),
      t('c', 'Built in', 'en', 'mpv-sid:3', release: 'English'),
      t('s', 'Cinejoy', 'es', 'https://subs.example/g/es.srt'),
    ];
    expect(subtitleNear(host, mine)?.url, 'mpv-sid:3');
    expect(subtitleNear(host, mine.where((x) => x.provider != 'Built in'))?.url, 'https://subs.example/g/9.srt', reason: 'the same provider next');
    expect(subtitleNear(host, mine.where((x) => x.provider != 'Built in' && x.provider != 'Cinejoy'))?.url, 'https://os.example/en.srt',
        reason: 'then any real file before a translation');
    expect(subtitleNear(host, [mine.first])?.translated, isTrue, reason: 'a translation is better than none');
    expect(subtitleNear(host, [mine.last]), isNull, reason: 'never another language');
  });
}
