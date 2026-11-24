import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/platform/platform_detector.dart' show PlatformDetector;

/// One look for the app: the accent shown on the Appearance cards and the ambient glow the shell
/// lays over every page. [glow] null keeps each page's own haze untouched.
class AppTheme {
  const AppTheme(this.id, this.name, this.blurb, this.color, {this.glow = true});
  final String id;
  final String name;
  final String blurb;
  final Color color;
  final bool glow;
}

const appThemes = [
  AppTheme('vyse', 'Vyse', 'Amber light, violet haze', Color(0xFFFFA53A), glow: false),
  AppTheme('crimson', 'Crimson', 'Low red glow, like a cinema', Color(0xFFE5383B)),
  AppTheme('abyss', 'Abyss', 'Deep navy, blue haze', Color(0xFF3B82F6)),
  AppTheme('amber', 'Amber', 'Warm gold undertones', Color(0xFFF59E0B)),
  AppTheme('bloom', 'Bloom', 'Dark rose, soft pink light', Color(0xFFEC4899)),
  AppTheme('canopy', 'Canopy', 'Emerald mist', Color(0xFF10B981)),
  AppTheme('glacier', 'Glacier', 'Steel blue, cyan frost', Color(0xFF06B6D4)),
  AppTheme('violet', 'Violet', 'Purple dusk', Color(0xFF8B5CF6)),
];

/// A saved preference you can listen to.
class Setting<T> extends ValueNotifier<T> {
  Setting(this.key, this.fallback) : super(fallback);
  final String key;
  final T fallback;

  void set(T v) {
    value = v;
    AppSettings._save(key, v);
  }
}

/// Everything on the Profile page, kept on this device until accounts land.
class AppSettings {
  static SharedPreferences? _prefs;

  // Profile
  static final displayName = Setting<String>('profile.name', 'Guest');
  static final avatarUrl = Setting<String?>('profile.avatar', null);
  static final avatarLabel = Setting<String?>('profile.avatarLabel', null);

  // Appearance
  static final themeId = Setting<String>('look.theme', 'vyse');
  static AppTheme get theme => appThemes.firstWhere((t) => t.id == themeId.value, orElse: () => appThemes.first);

  /// The navbar: section ids in your order ('' = the default order) and the ones you hid, both
  /// comma-separated. Read and written through NavLayout (core/nav_sections.dart).
  static final navOrder = Setting<String>('look.navOrder', '');
  static final navOff = Setting<String>('look.navOff', '');

  // My List page
  static final myListGrid = Setting<bool>('list.grid', true);
  static final myListSort = Setting<int>('list.sort', 0);

  // Party: the member list beside the page (wide screens)
  static final partyMembers = Setting<bool>('party.members', true);

  // Party: sounds for people coming and going and for messages
  static final partySounds = Setting<bool>('party.sounds', true);

  // Party: people whose messages make no sound or notification (user ids, comma-separated)
  static final partyMuted = Setting<String>('party.muted', '');

  // Anime: adult titles may show (turned on in the filters, after saying you're 18 or older)
  static final animeAdult = Setting<bool>('anime.adult', false);

  // Anime: the audio language to start on ('' = the original; 'English', 'Hindi': that dub,
  // when there is one), as last picked by hand
  static final animeAudio = Setting<String>('anime.audio', '');

  // Stremio addons you installed (JSON list; their links can hold your debrid keys, so they
  // travel only to your own account)
  static final addons = Setting<String>('addons.list', '[]');

  // Playback
  static final streamingMode = Setting<bool>('play.streaming', true);
  static final autoNext = Setting<bool>('play.autoNext', true);
  static final autoplayBest = Setting<bool>('play.autoplayBest', false);
  // Your own order for it (AutoplayOrder): its steps as JSON, '' for the built-in order; and
  // whether something outside your steps may play when none of them has a source
  static final autoplayOrder = Setting<String>('play.autoplayOrder', '');
  static final autoplayRest = Setting<bool>('play.autoplayRest', true);
  static final autoSubtitles = Setting<bool>('play.autoSubs', true);
  static final seekSeconds = Setting<int>('play.seek', 10);
  // Skip buttons the player doesn't offer (SegmentKind names, comma-separated: intro, recap,
  // preview, credits); that part then just plays
  static final skipButtonsOff = Setting<String>('play.skipOff', '');
  // P2P (torrent) sources: off until you allow them, since peers can see your IP address
  static final p2pStreaming = Setting<bool>('play.p2p', false);

  // Film and TV sources (Settings > Sources): the order they're asked in (source ids,
  // comma-separated; '' = the default, Movy first) and the ones turned off
  static final sourceOrder = Setting<String>('sources.order', '');
  static final sourcesOff = Setting<String>('sources.off', '');

  // Anime lists: episodes you finish here update AniList (once connected)
  static final trackAniList = Setting<bool>('trackers.anilist', true);
  // finishing episode 1 of something already Completed starts a rewatch there
  static final trackRewatches = Setting<bool>('trackers.rewatches', false);
  // Simkl: what you watch (start / pause / stop), My List as "plan to watch", and, only if
  // turned on, History removals (which clear that title's watch history on Simkl)
  static final simklScrobble = Setting<bool>('trackers.simkl', true);
  static final simklList = Setting<bool>('trackers.simkl.list', true);
  static final simklHistory = Setting<bool>('trackers.simkl.history', false);
  // Trakt: the same three (History removals only take off plays VyseTV itself sent)
  static final traktScrobble = Setting<bool>('trackers.trakt', true);
  static final traktList = Setting<bool>('trackers.trakt.list', true);
  static final traktHistory = Setting<bool>('trackers.trakt.history', false);

  // Subtitles
  static final subtitleLanguage = Setting<String>('subs.lang', 'English');
  // A downloaded subtitle lined up with the video's own subtitles, when it has some
  static final autoSyncSubtitles = Setting<bool>('subs.autoSync', true);
  // (on a TV, read from across the room, they start larger; a size the user chose is kept)
  static final subtitleSize = Setting<int>('subs.size', PlatformDetector.isTV() ? 44 : 28);
  static final subtitleColor = Setting<int>('subs.color', 0xFFFFFFFF);
  static final subtitleBackground = Setting<int>('subs.bg', 75);
  // How mpv/libass draws them (Settings > Subtitles). Tenths are stored as ints (25 = 2.5).
  static final subtitleFont = Setting<String>('subs.font', ''); // '' = Go Noto, bundled
  static final subtitleBold = Setting<bool>('subs.bold', true);
  static final subtitleItalic = Setting<bool>('subs.italic', false);
  static final subtitleBackColor = Setting<int>('subs.bgColor', 0xFF000000); // the box, its opacity is subs.bg
  static final subtitleOutline = Setting<int>('subs.outline', 25);
  static final subtitleOutlineColor = Setting<int>('subs.outlineColor', 0xFF000000);
  static final subtitleShadow = Setting<int>('subs.shadow', 10);
  static final subtitleShadowColor = Setting<int>('subs.shadowColor', 0xA0000000);
  static final subtitleBlur = Setting<int>('subs.blur', 0);
  static final subtitleSpacing = Setting<int>('subs.spacing', 0);
  static final subtitleTop = Setting<bool>('subs.top', false);
  static final subtitleLift = Setting<int>('subs.lift', 0); // % of the height from its edge
  static final subtitleOnPicture = Setting<bool>('subs.onPicture', false); // never in the black bars
  static final subtitleAss = Setting<String>('subs.ass', 'scale'); // styled subs: scale, force, strip

  // Player (mpv). `device.` keys describe this device's screen and speakers, so they stay
  // here and never sync to the account (see [synced]).
  static final audioDelayMs = Setting<int>('device.audioDelay', 0); // lip-sync, + = audio later
  static final audioPassthrough = Setting<bool>('device.passthrough', false); // bitstream to a receiver
  static final audioChannels = Setting<String>('device.channels', 'original'); // original, surround51, stereo
  static final hdrOutput = Setting<bool>('device.hdr', true);
  static final matchRefreshRate = Setting<bool>('device.matchRefresh', false);
  // The video engine on an Android TV: '' (not chosen: Media3), 'media3' or 'mpv'. Read through
  // PlayerEngine (data/playback/player_engine.dart).
  static final playerEngine = Setting<String>('device.engine', '');
  // Media3 hands a video it can't play to mpv, which carries on from the same spot (on unless
  // turned off). Read through PlayerEngine.handOver.
  static final mpvHandOver = Setting<bool>('device.handOver', true);
  // Network modes (data/network/network_modes.dart): this device only, so a TV's choice never reaches a phone through account sync.
  /// Route the app's traffic through Cloudflare WARP.
  static final netWarp = Setting<bool>('device.net.warp', false);
  /// With WARP on: only VyseTV's own server (account, sync, API) goes through it; sources and video stay direct.
  static final netWarpServerOnly = Setting<bool>('device.net.warpServerOnly', false);
  /// Secure DNS provider: 'off', 'cloudflare', 'google', 'adguard' or 'custom'; the custom resolver's address is [netDohUrl].
  static final netDoh = Setting<String>('device.net.doh', 'off');
  static final netDohUrl = Setting<String>('device.net.dohUrl', '');
  /// Anti-DPI mode on or off, its preset id (data/network/anti_dpi_presets.dart) and, when edited by hand, its parameters ('' = the preset's).
  static final netAntiDpi = Setting<bool>('device.net.antidpi', false);
  static final netAntiDpiPreset = Setting<String>('device.net.antidpiPreset', 'split_disorder');
  static final netAntiDpiArgs = Setting<String>('device.net.antidpiArgs', '');
  // Fewer animations and less paint, for a TV's chip: '' (not chosen: on for an Android TV),
  // 'on' or 'off'. Read through Lean (core/lean.dart).
  static final leanMotion = Setting<String>('device.lean', '');
  // The picture's shape on this screen: 'fit', 'fill' or 'stretch' (screens/player/picture_shape.dart).
  static final pictureShape = Setting<String>('device.shape', 'fit');
  static final volumeLevelling = Setting<bool>('play.levelling', false);
  static final upscaler = Setting<String>('play.upscaler', 'none');
  static final ambientLight = Setting<bool>('play.ambient', false);

  /// Your Party profile shows your library (My List, liked songs, public playlists, artists).
  static final partyLibrary = Setting<bool>('party.library', true);

  /// When the queue runs out, keep going with songs like the last one.
  static final musicAutoplay = Setting<bool>('music.autoplay', true);

  /// Debrid (Settings → Debrid): which service, and whether torrents go through it. On this
  /// device only, like the key itself (in the keychain).
  static final debridProvider = Setting<String>('device.debrid.provider', '');
  static final debridOn = Setting<bool>('device.debrid.on', true);

  // Updates: whether VyseTV looks for a newer version by itself, and a version you said no to.
  static final updateAuto = Setting<bool>('device.update.auto', true);
  static final updateSkipped = Setting<String>('device.update.skipped', '');

  // Addons: when their manifests were last read again (ms since 1970), to keep them current.
  static final addonsRefreshed = Setting<int>('device.addons.refreshed', 0);

  // Torrents (Settings > Playback > Torrents). Memory (MB), what loads before playing (MB) and
  // connections describe this device, 0 being its default (Torrents has them); your trackers,
  // one per line, travel with your account.
  static final torrentMemory = Setting<int>('device.torrent.memory', 0);
  static final torrentPreload = Setting<int>('device.torrent.preload', 0);
  static final torrentConnections = Setting<int>('device.torrent.connections', 0);
  static final torrentUpload = Setting<bool>('device.torrent.upload', true);
  static final torrentTrackers = Setting<String>('play.trackers', '');
  static final publicTrackers = Setting<bool>('play.publicTrackers', true);

  static List<Setting<Object?>> get _all => [
        displayName, avatarUrl, avatarLabel, themeId, navOrder, navOff,
        addons, streamingMode, autoNext, autoplayBest, autoplayOrder, autoplayRest, autoSubtitles, seekSeconds, skipButtonsOff, p2pStreaming, sourceOrder, sourcesOff, trackAniList, trackRewatches, simklScrobble, simklList, simklHistory,
        traktScrobble, traktList, traktHistory,
        subtitleLanguage, autoSyncSubtitles, subtitleSize, subtitleColor,
        subtitleBackground, subtitleFont, subtitleBold, subtitleItalic, subtitleBackColor, subtitleOutline, subtitleOutlineColor,
        subtitleShadow, subtitleShadowColor, subtitleBlur, subtitleSpacing, subtitleTop, subtitleLift, subtitleOnPicture, subtitleAss,
        audioDelayMs, audioPassthrough, audioChannels, hdrOutput, matchRefreshRate, playerEngine, mpvHandOver, leanMotion, pictureShape, volumeLevelling,
        upscaler, ambientLight, partyLibrary, musicAutoplay, debridProvider, debridOn, updateAuto, updateSkipped, addonsRefreshed,
        torrentMemory, torrentPreload, torrentConnections, torrentUpload, torrentTrackers, publicTrackers, myListGrid, myListSort, partyMembers, partySounds, partyMuted, animeAdult, animeAudio,
              netWarp, netWarpServerOnly, netDoh, netDohUrl, netAntiDpi, netAntiDpiPreset, netAntiDpiArgs,
      ];

  static Future<void> initialize() async {
    final p = _prefs = await SharedPreferences.getInstance();
    for (final s in _all) {
      final v = p.get(s.key);
      if (v != null && (s.fallback == null || v.runtimeType == s.fallback.runtimeType)) s.value = v;
    }
  }

  static void _save(String key, Object? v) {
    final p = _prefs;
    if (p == null) return;
    switch (v) {
      case null:
        p.remove(key);
      case bool b:
        p.setBool(key, b);
      case int i:
        p.setInt(key, i);
      case String s:
        p.setString(key, s);
    }
  }

  // ── account sync (name and avatar travel on the account itself) ──

  static List<Setting<Object?>> get synced =>
      _all.where((s) => !s.key.startsWith('profile.') && !s.key.startsWith('device.')).toList();
  static final Listenable anySynced = Listenable.merge(synced);

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async => {for (final s in synced) s.key: {'v': s.value}};

  static Future<void> syncApply(String key, Map<String, dynamic>? data) async {
    if (data == null) return;
    final s = synced.where((x) => x.key == key).firstOrNull;
    if (s == null) return;
    var v = data['v'];
    if (v is double && s.fallback is int) v = v.toInt();
    try {
      s.set(v);
    } catch (_) {
      // wrong type from an older build: keep ours
    }
  }

  /// Back to defaults. Kept: the profile (name and avatar), installed addons (they can hold debrid
  /// keys) and the people you muted, which are yours rather than preferences.
  static void resetPreferences() {
    for (final s in _all) {
      if (s == displayName || s == avatarUrl || s == avatarLabel || s == addons || s == partyMuted) continue;
      s.set(s.fallback);
    }
  }
}
