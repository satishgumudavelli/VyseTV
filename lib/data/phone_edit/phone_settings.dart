import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import '../../core/nav_sections.dart';
import '../../mpv/mpv.dart' show Upscaler;
import '../app_settings.dart';
import '../../core/lean.dart';
import '../playback/intro_db.dart' show SegmentKind;
import '../playback/player_engine.dart';
import '../sources/addons.dart';
import '../sources/debrid/debrid.dart';
import '../sources/film_sources/film_sources.dart' show FilmSource;
import '../sources/film_sources/source_settings.dart';
import '../subtitles/subtitle_style.dart';

/// Everything Edit on your phone can change, in the order and words of Settings. The phone page
/// draws whatever this describes (it knows controls, not settings), so a setting added here shows
/// up there with no change to the page. Every change that comes back is checked against what is
/// described here before anything is set: a change the TV doesn't offer is dropped.

/// A line the phone shows under something after the TV acted on it.
class PhoneNote {
  const PhoneNote(this.text, {this.bad = false});
  final String text;
  final bool bad;
  Map<String, Object?> toJson() => {'text': text, if (bad) 'bad': true};
}

/// What a change from the phone did: [what] for the TV's own screen ("Text size: 32"), [note]
/// for the phone, next to what changed.
class PhoneTook {
  const PhoneTook(this.what, [this.note]);
  final String? what;
  final PhoneNote? note;
}

abstract class PhoneItem {
  PhoneItem(this.id, this.title, [this.sub]);
  final String id;
  final String title;
  final String? sub;
  String get kind;
  Map<String, Object?> get fields => const {};

  /// What changes what this shows, so the TV sends its settings again.
  List<Listenable> get watched => const [];

  Map<String, Object?> toJson() => {'id': id, 'kind': kind, 'title': title, 'sub': ?sub, ...fields};

  /// Takes a change from the phone. Null: it made no sense here, and nothing changed.
  Future<PhoneTook?> take(Map<String, Object?> change);
}

class PhoneSection {
  const PhoneSection(this.id, this.title, this.blurb, this.items);
  final String id;
  final String title;
  final String blurb;
  final List<PhoneItem> items;
  Map<String, Object?> toJson() => {'id': id, 'title': title, 'blurb': blurb, 'items': [for (final i in items) i.toJson()]};
}

/// A heading inside a section.
class _Group extends PhoneItem {
  _Group(String title) : super('group.$title', title);
  @override
  String get kind => 'group';
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async => null;
}

class _Toggle extends PhoneItem {
  _Toggle(this.setting, String title, [String? sub]) : super(setting.key, title, sub);
  final Setting<bool> setting;
  @override
  String get kind => 'toggle';
  @override
  Map<String, Object?> get fields => {'value': setting.value};
  @override
  List<Listenable> get watched => [setting];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    if (v is! bool) return null;
    setting.set(v);
    return PhoneTook('$title: ${v ? 'on' : 'off'}');
  }
}

/// One of a few values: pills, colour dots, or a list for long ones ([kind] `select`).
class _Choice<T> extends PhoneItem {
  _Choice(this.setting, String title, this.options, {String? sub, this.kind = 'choice', this.colors = const {}, this.shown}) : super(setting.key, title, sub);
  final Setting<T> setting;
  final List<(T, String)> options;
  final Map<T, int> colors;

  /// The option to show as picked for a saved value, when that value is not one of [options].
  final T Function(T)? shown;
  @override
  final String kind;
  @override
  Map<String, Object?> get fields => {
    'value': shown?.call(setting.value) ?? setting.value,
    'options': [
      for (final (v, l) in options) {'v': v, 'l': l, if (colors[v] case final c?) 'c': cssColor(c)},
    ],
  };
  @override
  List<Listenable> get watched => [setting];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    for (final (o, l) in options) {
      if (o == v || (o is int && v is num && v == o)) {
        setting.set(o);
        return PhoneTook(l.isEmpty ? title : '$title: $l');
      }
    }
    return null;
  }
}

/// A number stepped through with − and +. [fmt] says how the phone writes it: `tenths` (25 is
/// 2.5), `percent`, `delay` (milliseconds as ±s), or `plain`; [zero] is what 0 is called.
class _Stepper extends PhoneItem {
  _Stepper(this.setting, String title, {required this.min, required this.max, required this.step, this.fmt = 'plain', this.zero, String? sub})
    : super(setting.key, title, sub);
  final Setting<int> setting;
  final int min, max, step;
  final String fmt;
  final String? zero;
  @override
  String get kind => 'stepper';
  @override
  Map<String, Object?> get fields => {'value': setting.value, 'min': min, 'max': max, 'step': step, 'fmt': fmt, 'zero': ?zero};
  @override
  List<Listenable> get watched => [setting];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    if (v is! num || v != v.roundToDouble()) return null;
    final n = v.toInt();
    if (n < min || n > max || (n - min) % step != 0) return null;
    setting.set(n);
    return PhoneTook('$title: ${_label(n)}');
  }

  String _label(int n) {
    if (n == 0 && zero != null) return zero!;
    return switch (fmt) {
      'tenths' => (n / 10).toStringAsFixed(n % 10 == 0 ? 0 : 1),
      'percent' => '$n%',
      'delay' => '${n > 0 ? '+' : '−'}${(n.abs() / 1000).toStringAsFixed(2)} s',
      _ => '$n',
    };
  }
}

class _Text extends PhoneItem {
  _Text(this.setting, String title, {required this.max, this.placeholder, String? sub}) : super(setting.key, title, sub);
  final Setting<String> setting;
  final int max;
  final String? placeholder;
  @override
  String get kind => 'text';
  @override
  Map<String, Object?> get fields => {'value': setting.value, 'max': max, 'placeholder': ?placeholder};
  @override
  List<Listenable> get watched => [setting];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    if (v is! String) return null;
    final t = v.trim();
    if (t.isEmpty || t.length > max) return null;
    setting.set(t);
    return PhoneTook('$title: $t');
  }
}

/// One of the player's skip buttons, on or off (AppSettings.skipButtonsOff lists the ones off).
class _SkipButton extends PhoneItem {
  _SkipButton(this.segment, String title) : super('play.skip.${segment.name}', title);
  final SegmentKind segment;
  static Set<String> get _off => AppSettings.skipButtonsOff.value.split(',').where((s) => s.isNotEmpty).toSet();
  @override
  String get kind => 'toggle';
  @override
  Map<String, Object?> get fields => {'value': !_off.contains(segment.name)};
  @override
  List<Listenable> get watched => [AppSettings.skipButtonsOff];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    if (v is! bool) return null;
    final off = _off;
    v ? off.remove(segment.name) : off.add(segment.name);
    AppSettings.skipButtonsOff.set([for (final k in SegmentKind.values) if (off.contains(k.name)) k.name].join(','));
    return PhoneTook('${segment.action}: ${v ? 'on' : 'off'}');
  }
}

/// A list in an order of your own, each one on or off: the navbar, the film sources.
class _Order<T> extends PhoneItem {
  _Order(
    String id,
    String title, {
    String? sub,
    required this.list,
    required this.idOf,
    required this.labelOf,
    required this.isOn,
    required this.setOrder,
    required this.setOn,
    required this.reset,
    required this.watched,
    this.minOn = 1,
  }) : super(id, title, sub);
  final List<T> Function() list;
  final String Function(T) idOf;
  final String Function(T) labelOf;
  final bool Function(T) isOn;
  final void Function(List<T>) setOrder;
  final void Function(T, bool) setOn;
  final void Function() reset;
  final int minOn;
  @override
  final List<Listenable> watched;
  @override
  String get kind => 'order';
  @override
  Map<String, Object?> get fields => {
    'items': [for (final x in list()) {'id': idOf(x), 'l': labelOf(x), 'on': isOn(x)}],
    'minOn': minOn,
    'reset': 'Default order',
  };
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    if (change['reset'] == true) {
      reset();
      return PhoneTook('$title: default order');
    }
    final order = change['order'];
    final off = change['off'];
    if (order is! List || off is! List) return null;
    final now = list();
    final byId = {for (final x in now) idOf(x): x};
    final ids = order.whereType<String>().toList();
    // the same ones, each once: nothing added, nothing lost
    if (ids.length != now.length || ids.toSet().length != ids.length || !ids.every(byId.containsKey)) return null;
    final offIds = off.whereType<String>().toSet();
    if (now.length - offIds.where(byId.containsKey).length < minOn) return null;
    setOrder([for (final id in ids) byId[id] as T]);
    // switched on before any goes off, so the last one showing is never the one asked to go
    for (final x in now) {
      if (!offIds.contains(idOf(x))) setOn(x, true);
    }
    for (final x in now) {
      if (offIds.contains(idOf(x))) setOn(x, false);
    }
    return PhoneTook('$title: changed');
  }
}

/// Stremio addons: the list, Remove, and Install from a link pasted on the phone. Their links
/// can hold keys, so only names go to the phone; an addon is known there by a hash of its link.
class _Addons extends PhoneItem {
  _Addons() : super('addons', 'Your addons', 'Paste a Stremio addon link to install it on the TV.');
  @override
  String get kind => 'addons';
  static String _idOf(Addon a) => sha256.convert(utf8.encode(a.manifestUrl)).toString().substring(0, 16);
  @override
  Map<String, Object?> get fields => {
    'placeholder': 'https://…/manifest.json  or  stremio://…',
    'items': [
      for (final a in Addons.list.value)
        {
          'id': _idOf(a),
          'l': a.name,
          'sub': [a.streams && a.subtitles ? 'Sources and subtitles' : (a.streams ? 'Sources' : 'Subtitles'), if (a.builtIn) 'built in', if (!a.enabled) 'off'].join(' · '),
          'removable': !a.builtIn,
        },
    ],
  };
  @override
  List<Listenable> get watched => [Addons.list];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final add = change['add'];
    if (add is String && add.trim().isNotEmpty && add.length <= 2000) {
      try {
        final a = await Addons.install(add.trim());
        final what = a.streams && a.subtitles ? ' (sources and subtitles)' : a.streams ? ' (sources)' : ' (subtitles)';
        return PhoneTook('Installed ${a.name}', PhoneNote('${a.name} is installed$what.'));
      } catch (e) {
        return PhoneTook(null, PhoneNote('$e', bad: true));
      }
    }
    final remove = change['remove'];
    if (remove is String) {
      final a = Addons.list.value.where((x) => _idOf(x) == remove && !x.builtIn).firstOrNull;
      if (a == null) return null;
      Addons.remove(a);
      return PhoneTook('Removed ${a.name}', PhoneNote('${a.name} is removed.'));
    }
    return null;
  }
}

/// The debrid key, typed (or pasted) on the phone: checked with the service, then kept in the
/// TV's keychain like one typed on the TV. It never comes back to the phone.
class _DebridKey extends PhoneItem {
  _DebridKey() : super('debrid.key', Debrid.provider == null ? 'Key' : '${Debrid.provider!.label} key', "Kept in this TV's keychain. It never goes to your VyseTV account.");
  @override
  String get kind => 'secret';
  @override
  Map<String, Object?> get fields {
    final p = Debrid.provider;
    if (p == null) return {'value': '', 'placeholder': 'Pick a service first'};
    return {
      'value': Debrid.keyed.value.contains(p) ? 'saved' : '',
      'placeholder': 'Paste your ${p.label} API key',
      'href': p.keyPage,
      'hrefLabel': 'Where to find your ${p.label} key',
      'button': 'Save',
    };
  }

  @override
  List<Listenable> get watched => [AppSettings.debridProvider, Debrid.keyed];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final key = change['v'];
    final p = Debrid.provider;
    if (key is! String || key.trim().isEmpty || key.length > 500) return null;
    if (p == null) return const PhoneTook(null, PhoneNote('Pick a service first.', bad: true));
    final user = await Debrid.verify(p, key.trim());
    if (user == null) return PhoneTook(null, PhoneNote("${p.label} didn't accept that key. Check you copied all of it.", bad: true));
    await Debrid.saveKey(p, key.trim());
    return PhoneTook('Connected to ${p.label}', PhoneNote('Connected to ${p.label}. ${Debrid.describe(user)}'.trim()));
  }
}

/// The lean way of drawing (core/lean.dart), on or off: on unless the TV's owner says otherwise.
class _Lean extends PhoneItem {
  _Lean()
    : super(
        'device.lean',
        'Lighter interface',
        'Fewer animations and effects, so VyseTV stays quick on this TV. Switch it off for the full look if your TV keeps up',
      );
  @override
  String get kind => 'toggle';
  @override
  Map<String, Object?> get fields => {'value': Lean.on};
  @override
  List<Listenable> get watched => [Lean.changes];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    if (v is! bool) return null;
    Lean.choose(v);
    return PhoneTook('$title: ${v ? 'on' : 'off'}');
  }
}

/// Android TV: the video engine. Changing it changes what else is on the page: what only mpv
/// can do is left out while Media3 is the engine.
class _Engine extends PhoneItem {
  _Engine()
    : super(
        'device.engine',
        'Player engine',
        "Media3 is Android's own player; a video it can't play switches to mpv by itself. "
            'Upscaling, ambient lighting, the 5.1 limit and some subtitle styling need mpv. Applies from the next video',
      );
  @override
  String get kind => 'choice';
  @override
  Map<String, Object?> get fields => {
    'value': PlayerEngine.current,
    'options': const [
      {'v': PlayerEngine.media3, 'l': 'Media3'},
      {'v': PlayerEngine.mpv, 'l': 'mpv'},
    ],
  };
  @override
  List<Listenable> get watched => [PlayerEngine.changes];
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    final v = change['v'];
    if (v != PlayerEngine.media3 && v != PlayerEngine.mpv) return null;
    PlayerEngine.choose(v as String);
    return PhoneTook('Player engine: ${v == PlayerEngine.media3 ? 'Media3' : 'mpv'}');
  }
}

class _Action extends PhoneItem {
  _Action(String id, String title, {String? sub, required this.button, required this.confirm, required this.run}) : super(id, title, sub);
  final String button;
  final String confirm;
  final void Function() run;
  @override
  String get kind => 'action';
  @override
  Map<String, Object?> get fields => {'button': button, 'confirm': confirm};
  @override
  Future<PhoneTook?> take(Map<String, Object?> change) async {
    run();
    return PhoneTook('$title: reset');
  }
}

String cssColor(int argb) {
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  final a = (argb >> 24) & 0xFF;
  final rgb = '#${hex((argb >> 16) & 0xFF)}${hex((argb >> 8) & 0xFF)}${hex(argb & 0xFF)}';
  return a == 0xFF ? rgb : '$rgb${hex(a)}';
}

/// The sections, as Settings has them. [fonts]: the subtitle fonts this device has
/// (SubtitleStyle.available()).
List<PhoneSection> phoneSections({required List<SubtitleFontChoice> fonts}) {
  // Media3 is the engine: what only mpv can do is left out (it is back with mpv)
  final m3 = PlayerEngine.isMedia3;
  return [
    PhoneSection('playback', 'Playback', 'How videos play by default.', [
      _Toggle(AppSettings.streamingMode, 'Streaming mode', "On: videos play right away from VyseTV's servers. Off: pick a source from your addons first"),
      _Toggle(
        AppSettings.autoplayBest,
        'Autoplay the best source',
        'With streaming mode off: the Next episode button plays the best match from your addons. Nothing starts by itself',
      ),
      _Toggle(AppSettings.p2pStreaming, 'P2P streaming', 'Play torrent sources. You connect directly to other people, who can see your IP address'),
      _Toggle(AppSettings.autoNext, 'Auto next episode', 'Play the next episode when one ends'),
      _Toggle(AppSettings.autoSubtitles, 'Auto-enable subtitles', 'Turn on captions in your language when a video starts'),
      _Choice<int>(AppSettings.seekSeconds, 'Seek amount', [for (final s in const [5, 10, 15, 30]) (s, '${s}s')], sub: 'Per skip, with left and right in the player'),
      _Group('Skip buttons the player offers'),
      for (final (k, name) in const [(SegmentKind.intro, 'Intro'), (SegmentKind.recap, 'Recap'), (SegmentKind.preview, 'Preview'), (SegmentKind.credits, 'Credits')])
        _SkipButton(k, name),
    ]),
    PhoneSection('player', 'Sound and picture', 'Set for this TV only.', [
      if (PlayerEngine.offered) _Engine(),
      _Stepper(AppSettings.audioDelayMs, 'Audio sync', min: -5000, max: 5000, step: 50, fmt: 'delay', zero: 'In sync', sub: 'Fixes lip-sync. + plays the sound later'),
      _Choice<String>(AppSettings.audioChannels, 'Channels', [const ('original', 'Original'), if (!m3) const ('surround51', '5.1'), const ('stereo', 'Stereo')], sub: 'Stereo folds surround down for headphones and TV speakers',
          // (Media3 has no 5.1 limit: it plays that choice as Original)
          shown: m3 ? (v) => v == 'surround51' ? 'original' : v : null),
      _Toggle(AppSettings.volumeLevelling, 'Volume levelling', 'Evens out quiet talk and loud action'),
      if (!Platform.isIOS) _Toggle(AppSettings.audioPassthrough, 'Passthrough', 'Sends Dolby and DTS untouched to a receiver. Not with levelling, stereo or other speeds'),
      if (!m3) _Choice<String>(AppSettings.upscaler, 'Upscaling', [for (final u in Upscaler.offered) (u.id, u.label)]),
      if (!m3) _Toggle(AppSettings.ambientLight, 'Ambient lighting', 'Fills the black bars with a soft glow of the picture'),
      if (Platform.isWindows) _Toggle(AppSettings.hdrOutput, 'HDR', 'Real HDR on an HDR screen. Off maps it to SDR'),
      if (Platform.isWindows || Platform.isAndroid) _Toggle(AppSettings.matchRefreshRate, 'Match refresh rate', "Switches the screen to the video's frame rate"),
    ]),
    PhoneSection('subtitles', 'Subtitles', 'Default captions for the player.', [
      _Choice<String>(AppSettings.subtitleLanguage, 'Default language', [for (final l in subtitleLanguages) (l, l)], kind: 'select', sub: "If a video doesn't have it, no subtitles are loaded."),
      _Group('Caption style'),
      if (!m3)
        _Choice<String>(AppSettings.subtitleFont, 'Font', [
          for (final f in fonts) (f.family == SubtitleStyle.defaultFamily ? '' : f.family, f.name),
        ], kind: 'select', sub: 'Go Noto covers every language. Other fonts fall back to it for letters they lack.'),
      _Toggle(AppSettings.subtitleBold, 'Bold'),
      _Toggle(AppSettings.subtitleItalic, 'Italic'),
      _Stepper(AppSettings.subtitleSize, 'Text size', min: captionSizeMin, max: captionSizeMax, step: captionSizeStep),
      _Choice<int>(AppSettings.subtitleColor, 'Text colour', [for (final c in captionColors) (c, '')], kind: 'colors', colors: {for (final c in captionColors) c: c}),
      if (!m3) _Stepper(AppSettings.subtitleSpacing, 'Letter spacing', min: -20, max: 50, step: 5, fmt: 'tenths', zero: 'Normal'),
      _Group('Background box'),
      _Choice<int>(AppSettings.subtitleBackground, 'Box', [for (final v in captionBoxLevels) (v, v == 0 ? 'None' : '$v%')], sub: m3 ? 'A box behind the text. With no box, the outline below is used.' : 'A box behind the text. With no box, the outline and shadow below are used.'),
      _Choice<int>(AppSettings.subtitleBackColor, 'Box colour', [for (final c in captionBoxColors) (c, '')], kind: 'colors', colors: {for (final c in captionBoxColors) c: c}),
      _Group(m3 ? 'Outline' : 'Outline and shadow'),
      _Stepper(AppSettings.subtitleOutline, 'Outline', min: 0, max: 80, step: 5, fmt: 'tenths', zero: 'None', sub: m3 ? 'On or off: Media3 draws it at one thickness' : null),
      _Choice<int>(AppSettings.subtitleOutlineColor, 'Outline colour', [for (final c in captionOutlineColors) (c, '')], kind: 'colors', colors: {for (final c in captionOutlineColors) c: c}),
      if (!m3) ...[
        _Stepper(AppSettings.subtitleShadow, 'Shadow', min: 0, max: 60, step: 5, fmt: 'tenths', zero: 'None'),
        _Choice<int>(AppSettings.subtitleShadowColor, 'Shadow strength', const [(0x60000000, 'Soft'), (0xA0000000, 'Medium'), (0xFF000000, 'Strong')]),
        _Stepper(AppSettings.subtitleBlur, 'Soft edges', min: 0, max: 30, step: 5, fmt: 'tenths', zero: 'Off', sub: 'Blurs the outline a little'),
      ],
      _Group('Position'),
      _Choice<bool>(AppSettings.subtitleTop, 'Place at', const [(false, 'Bottom'), (true, 'Top')]),
      _Stepper(AppSettings.subtitleLift, 'Distance from the edge', min: 0, max: 45, step: 1, fmt: 'percent', zero: 'Edge', sub: "Of the screen's height. Bottom subtitles still move up while the controls show."),
      _Toggle(AppSettings.subtitleOnPicture, 'Keep on the picture', "Never put subtitles in a film's black bars"),
      if (!m3) ...[
        _Group('Styled subtitles'),
        _Choice<String>(AppSettings.subtitleAss, 'Show them', const [('scale', 'Keep as made'), ('force', 'Use my style'), ('strip', 'Plain')], sub: 'Anime fansubs (ASS/SSA) often bring their own fonts, colours, signs and karaoke.'),
      ],
      _Action('subs.reset', 'Caption style', sub: 'Back to how VyseTV draws subtitles out of the box', button: 'Reset', confirm: 'Reset the caption style on the TV?', run: SubtitleStyle.resetCaption),
    ]),
    PhoneSection('appearance', 'Appearance', 'The light behind every page, and what the navbar shows.', [
      _Choice<String>(AppSettings.themeId, 'Look', [for (final t in appThemes) (t.id, t.name)], colors: {for (final t in appThemes) t.id: t.color.toARGB32()}),
      _Lean(),
      _Order<NavItem>(
        'nav',
        'Navigation',
        sub: 'The sections in the navbar, in order. Switch one off to hide it. VyseTV opens on the first one showing.',
        list: () => NavLayout.all,
        idOf: (s) => s.id,
        labelOf: (s) => s.label,
        isOn: (s) => NavLayout.visible.contains(s),
        setOrder: NavLayout.setOrder,
        setOn: NavLayout.setOn,
        reset: NavLayout.reset,
        watched: [NavLayout.changes],
      ),
    ]),
    PhoneSection('sources', 'Sources', 'Where films and shows play from, and in what order.', [
      _Order<FilmSource>(
        'sources',
        'Film and TV sources',
        sub: 'Asked from the top down, and the first to answer plays. Switch one off to skip it.',
        list: orderedFilmSources,
        idOf: (s) => s.id,
        labelOf: (s) => s.name,
        isOn: filmSourceOn,
        setOrder: setFilmSourceOrder,
        setOn: setFilmSourceOn,
        reset: () {
          AppSettings.sourceOrder.set('');
          AppSettings.sourcesOff.set('');
        },
        watched: [AppSettings.sourceOrder, AppSettings.sourcesOff],
      ),
    ]),
    PhoneSection('addons', 'Addons', 'Stremio addons for sources and subtitles.', [_Addons()]),
    PhoneSection('debrid', 'Debrid', 'Stream torrents from a debrid service instead of peer to peer.', [
      _Choice<String>(
        AppSettings.debridProvider,
        'Service',
        [('', 'None'), for (final p in DebridProvider.values) (p.id, p.label)],
        sub: 'A debrid service downloads the torrent on its own servers and streams it to you over HTTPS.',
      ),
      _DebridKey(),
      _Toggle(AppSettings.debridOn, 'Play torrents through debrid', 'With a service and its key: torrents play from it instead of peer to peer'),
    ]),
    PhoneSection('lists', 'Lists and tracking', 'What you watch here keeps your lists there up to date, once connected on the TV.', [
      _Toggle(AppSettings.trackAniList, 'Update AniList progress', 'Anime episodes you finish here count there'),
      _Toggle(AppSettings.trackRewatches, 'Count rewatches', 'Finishing episode 1 of something you completed starts a rewatch there'),
      _Group('Simkl'),
      _Toggle(AppSettings.simklScrobble, 'Scrobble what I watch', 'Films, shows and anime, as you play them'),
      _Toggle(AppSettings.simklList, 'Sync My List', 'Adding here puts it on your Simkl plan to watch'),
      _Toggle(AppSettings.simklHistory, 'History removals reach Simkl', 'Removing a title from History here also clears its watch history on Simkl'),
      _Group('Trakt'),
      _Toggle(AppSettings.traktScrobble, 'Scrobble what I watch', 'Films, shows and anime, as you play them'),
      _Toggle(AppSettings.traktList, 'Sync My List', 'Adding here puts it on your Trakt watchlist'),
      _Toggle(AppSettings.traktHistory, 'History removals reach Trakt', 'Removing a title from History here also removes the plays VyseTV sent to Trakt'),
    ]),
    PhoneSection('profile', 'Profile and more', 'Your name here, Party and music, and updates.', [
      _Text(AppSettings.displayName, 'Display name', max: 24, placeholder: 'Your name'),
      _Toggle(AppSettings.partyLibrary, 'Show my library', 'Your Party profile shows your My List, liked songs, public playlists and the artists you follow'),
      _Toggle(AppSettings.musicAutoplay, 'Music autoplay', 'When your queue runs out, keep playing songs like the last one.'),
      _Toggle(AppSettings.partySounds, 'Party sounds', 'For people coming and going, and for messages'),
      _Toggle(AppSettings.updateAuto, 'Check for updates automatically', 'Looks for a new version when VyseTV starts, and tells you'),
    ]),
  ];
}
