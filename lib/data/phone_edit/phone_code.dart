import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:pointycastle/export.dart';

/// The code a TV shows for Edit on your phone: 16 letters and numbers (80 bits), in its QR code
/// and under it. The TV and the phone page work out the same two things from it: the session's
/// id, which the account server knows the session by, and an AES-256-GCM key, which never leaves
/// the two of them. Everything that passes through the server is sealed with that key, so the
/// server can read neither the TV's settings nor the phone's changes.
///
/// The phone page (`pb_public/phone/index.html` on the account server) does the same with
/// WebCrypto: id = SHA-256 of `vysetv-phone/1/id/<code>`; key = HKDF-SHA256 of the code, salt
/// `vysetv-phone/1`, info `aes-gcm key`; a box is base64url(iv) + "." + base64url(ciphertext and
/// tag), with `<id>/<kind>` as the additional data so a box can't be passed off as another kind.
class PhoneCode {
  PhoneCode._(this.code, this.id, this._key);

  /// Crockford's base 32: no I, L, O or U, so a typed code can't be misread.
  static const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const _prefix = 'vysetv-phone/1';

  final String code;
  final String id;
  final Uint8List _key;

  factory PhoneCode.random([Random? random]) {
    final r = random ?? Random.secure();
    return PhoneCode.of(String.fromCharCodes([for (var i = 0; i < 16; i++) alphabet.codeUnitAt(r.nextInt(alphabet.length))]));
  }

  /// [code] as typed or scanned: case, spaces and dashes don't matter, and O, I and L are read
  /// as 0, 1 and 1. Null when it isn't a code.
  static PhoneCode? parse(String text) {
    final s = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '').replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
    if (s.length != 16 || s.split('').any((c) => !alphabet.contains(c))) return null;
    return PhoneCode.of(s);
  }

  factory PhoneCode.of(String code) {
    final id = sha256.convert(utf8.encode('$_prefix/id/$code')).toString();
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(Uint8List.fromList(utf8.encode(code)), 32, Uint8List.fromList(utf8.encode(_prefix)), Uint8List.fromList(utf8.encode('aes-gcm key'))));
    final key = Uint8List(32);
    hkdf.deriveKey(null, 0, key, 0);
    return PhoneCode._(code, id, key);
  }

  /// The code in four groups, the way the TV shows it: `7KQ2-M4XD-…`.
  String get grouped => [for (var i = 0; i < 16; i += 4) code.substring(i, i + 4)].join('-');

  /// [value] as JSON, sealed for the other side. [kind] is `state` (TV to phone) or `change`.
  String seal(String kind, Object? value, [Random? random]) {
    final r = random ?? Random.secure();
    final iv = Uint8List.fromList([for (var i = 0; i < 12; i++) r.nextInt(256)]);
    final out = _gcm(true, iv, kind).process(Uint8List.fromList(utf8.encode(jsonEncode(value))));
    return '${_b64(iv)}.${_b64(out)}';
  }

  /// What a box from the other side holds. Throws when it wasn't sealed with this code's key, or
  /// was sealed as another kind.
  Object? open(String kind, String box) {
    final parts = box.split('.');
    if (parts.length != 2) throw const FormatException('Not a sealed box');
    final plain = _gcm(false, _unb64(parts[0]), kind).process(_unb64(parts[1]));
    return jsonDecode(utf8.decode(plain));
  }

  GCMBlockCipher _gcm(bool seal, Uint8List iv, String kind) =>
      GCMBlockCipher(AESEngine())..init(seal, AEADParameters(KeyParameter(_key), 128, iv, Uint8List.fromList(utf8.encode('$id/$kind'))));

  static String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
  static Uint8List _unb64(String s) => base64Url.decode(base64Url.normalize(s));
}
