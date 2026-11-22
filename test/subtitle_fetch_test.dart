// Where a Cinejoy relay link's file really is (lib/data/subtitles/subtitles.dart, cinejoyOrigin).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/subtitles/subtitles.dart';

String relay(String origin) => 'https://subs.wing.st/sub/${base64Url.encode(utf8.encode(origin)).replaceAll('=', '')}';

void main() {
  test('a name with "+" in it is asked for with the "+" escaped (the relay sends it bare: a 404)', () {
    // a real One Piece file: its host has it under this name, "+" and all
    const origin = 'https://mbpimages.chuaxin.com/movie_box/tv/srt/3/9/39/0/One+Piece+-+01+720p+WEB-DL+x264+2CH+%5BPahe.in%5D-1763464518.srt';
    expect(cinejoyOrigin(relay(origin)),
        'https://mbpimages.chuaxin.com/movie_box/tv/srt/3/9/39/0/One%2BPiece%2B-%2B01%2B720p%2BWEB-DL%2Bx264%2B2CH%2B%5BPahe.in%5D-1763464518.srt');
  });

  test('spaces and brackets are escaped; plain names stay as they are', () {
    expect(cinejoyOrigin(relay('https://mbpimages.chuaxin.com/movie_box/movie/srt/4/1/4061/306790/Fight Club 1999 BRrip 720p x264 [Herakler].srt')),
        'https://mbpimages.chuaxin.com/movie_box/movie/srt/4/1/4061/306790/Fight%20Club%201999%20BRrip%20720p%20x264%20%5BHerakler%5D.srt');
    const plain = 'https://mbpimages.chuaxin.com/movie_box/tv/srt/9/9/9/188208/game.of.thrones.s01e01.bdrip.xvid-reward-1711497757.srt';
    expect(cinejoyOrigin(relay(plain)), plain);
  });

  test('a query on the file is kept', () {
    expect(cinejoyOrigin(relay('https://subs5.strem.io/en/download/file/1955?a=b')), 'https://subs5.strem.io/en/download/file/1955?a=b');
  });

  test("other links, and relay links that don't hold one, give nothing", () {
    expect(cinejoyOrigin('https://subs.example/file.srt'), isNull);
    expect(cinejoyOrigin('https://subs.wing.st/sub/@@@'), isNull);
    expect(cinejoyOrigin(relay('ftp://example.com/a.srt')), isNull);
  });
}
