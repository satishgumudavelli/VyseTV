// Reads the interface's source (lib/screens, lib/widgets, and the shell's own files in lib/core)
// and lists everything a D-pad has to be able to deal with: what takes a tap, what opens over
// the page, what takes text, what only reacts to a mouse, what is dragged. The inventory
// (tool/dpad_inventory.dart) and the guard test (guard_test.dart) both read it from here.
//
// It never looks inside lib/services or lib/models.
import 'dart:io';

class Hit {
  const Hit(this.kind, this.file, this.line, this.text);
  final String kind;
  final String file;
  final int line;

  /// The source line, trimmed.
  final String text;

  String get at => '$file:$line';
}

/// Where the interface lives.
const interfaceRoots = ['lib/screens', 'lib/widgets'];

/// Which phase of docs/dpad/PLAN.md handles a file. The first match wins.
const _phases = <(String, int)>[
  ('lib/widgets/common.dart', 2),
  ('lib/widgets/section_chrome.dart', 2),
  ('lib/widgets/media_rows.dart', 2),
  ('lib/screens/home/continue_watching.dart', 2),
  ('lib/screens/home/up_next.dart', 2), // (no controls: what Continue watching's Up next cards show)
  ('lib/widgets/hero_carousel.dart', 2),
  ('lib/widgets/music_widgets.dart', 2),
  ('lib/screens/live_tv/live_tv_widgets.dart', 2),
  ('lib/widgets/audiobook_widgets.dart', 2),
  ('lib/screens/manga/manga_widgets.dart', 2),
  ('lib/screens/live_tv/match_widgets.dart', 2),
  ('lib/widgets/page_scrollbar.dart', 2),
  ('lib/widgets/service_logos.dart', 2),
  ('lib/widgets/voice_search.dart', 2),
  ('lib/widgets/watched_marks.dart', 4),
  ('lib/screens/shell/shell.dart', 3),
  ('lib/screens/shell/floating.dart', 3),
  ('lib/screens/home/home_page.dart', 3),
  ('lib/screens/home/addon_home.dart', 3),
  ('lib/screens/discover/discover_page.dart', 3),
  ('lib/screens/library/my_list_page.dart', 3),
  ('lib/screens/library/history_page.dart', 3),
  ('lib/screens/details/details_page.dart', 4),
  ('lib/screens/details/anime_details_page.dart', 4),
  ('lib/screens/details/person_page.dart', 4),
  ('lib/screens/details/episode_explorer.dart', 4),
  ('lib/screens/player/sources_page.dart', 4),
  ('lib/screens/search/search_page.dart', 4),
  ('lib/screens/live_tv/matches_view.dart', 4),
  ('lib/screens/search/open_link.dart', 4),
  ('lib/widgets/dialogs/p2p_consent.dart', 4),
  ('lib/widgets/dialogs/debrid_consent.dart', 4),
  ('lib/widgets/dialogs/torrent_file_dialog.dart', 4),
  ('lib/widgets/dialogs/update_dialog.dart', 4),
  ('lib/screens/profile/account_sheet.dart', 4),
  ('lib/screens/player/', 5),
  ('lib/screens/player/subtitle_sync_panel.dart', 5),
  ('lib/screens/anime/anime_page.dart', 6),
  ('lib/screens/live_tv/', 6),
  ('lib/screens/downloads/downloads_page.dart', 6),
  ('lib/screens/servers/', 6),
  ('lib/screens/shell/intro_screen.dart', 6),
  ('lib/screens/music/', 7),
  ('lib/screens/manga/', 7),
  ('lib/screens/audiobooks/', 7),
  ('lib/screens/profile/profile_page.dart', 8),
  ('lib/screens/profile/avatar_picker.dart', 8),
  ('lib/screens/profile/phone_edit_dialog.dart', 8),
  ('lib/widgets/trackers/', 8),
  ('lib/screens/party/', 9),
];


/// The phase that deals with [file]; 0 when the plan does not name it.
int phaseOf(String file) => _phases.where((p) => file.startsWith(p.$1)).firstOrNull?.$2 ?? 0;

/// A constructor call and, when [withAny] is given, the named arguments one of which must be
/// passed for the call to count (a GestureDetector that only drags is not a tap target).
class _Call {
  const _Call(this.kind, this.name, [this.withAny = const []]);
  final String kind;
  final String name;
  final List<String> withAny;
}

const _taps = ['onTap', 'onTapUp', 'onTapDown', 'onDoubleTap'];

final _calls = [
  const _Call('pressable', 'Pressable'),
  const _Call('raw tap', 'GestureDetector', _taps),
  const _Call('raw tap', 'InkWell', _taps),
  const _Call('raw tap', 'InkResponse', _taps),
  const _Call('raw tap', 'Listener', ['onPointerUp']),
  const _Call('long press', 'GestureDetector', ['onLongPress', 'onLongPressStart', 'onSecondaryTap', 'onSecondaryTapUp', 'onSecondaryTapDown']),
  const _Call('drag', 'GestureDetector', ['onPanUpdate', 'onPanStart', 'onHorizontalDragUpdate', 'onHorizontalDragStart', 'onVerticalDragUpdate', 'onVerticalDragStart', 'onScaleUpdate']),
  const _Call('drag', 'Slider'),
  const _Call('drag', 'ReorderableListView'),
  const _Call('drag', 'ReorderableListView.builder'),
  const _Call('drag', 'ReorderableDragStartListener'),
  const _Call('drag', 'Dismissible'),
  const _Call('drag', 'Draggable'),
  const _Call('hover', 'MouseRegion', ['onEnter', 'onExit', 'onHover']),
  const _Call('text box', 'TextField'),
  const _Call('text box', 'TextFormField'),
  const _Call('text box', 'EditableText'),
  const _Call('text box', 'VyseSearchField'),
  const _Call('overlay', 'showDialog'),
  const _Call('overlay', 'showGeneralDialog'),
  const _Call('overlay', 'showModalBottomSheet'),
  const _Call('overlay', 'showBottomSheet'),
  const _Call('overlay', 'showMenu'),
  const _Call('overlay', 'MenuAnchor'),
  const _Call('overlay', 'PopupMenuButton'),
  const _Call('overlay', 'OverlayEntry'),
  const _Call('overlay', 'OverlayPortal'),
  for (final b in const ['TextButton', 'TextButton.icon', 'IconButton', 'IconButton.filled', 'ElevatedButton', 'ElevatedButton.icon', 'FilledButton', 'FilledButton.icon', 'FilledButton.tonal', 'OutlinedButton', 'OutlinedButton.icon', 'MenuItemButton', 'PopupMenuItem', 'Switch', 'Switch.adaptive', 'Checkbox', 'Radio', 'ListTile', 'SwitchListTile', 'CheckboxListTile', 'DropdownButton', 'SegmentedButton', 'FloatingActionButton', 'ActionChip', 'ChoiceChip', 'FilterChip'])
    _Call('material', b),
];

/// Plain text patterns, counted wherever they stand.
final _patterns = <String, RegExp>{
  'onTap' : RegExp(r'\bonTap:'),
  'hover': RegExp(r'\bonHover:'),
  'long press': RegExp(r'\bonLongPress:'),
  'arrow keys': RegExp(r'LogicalKeyboardKey\.arrow(Up|Down|Left|Right)'),
  'key handler': RegExp(r'\b(onKeyEvent|onKey):|\bKeyboardListener\(|\bCallbackShortcuts\(|\bShortcuts\(|HardwareKeyboard\.instance\.addHandler'),
  'autofocus': RegExp(r'\bautofocus:\s*true'),
  'passed over': RegExp(r'\bfocusable:\s*false'),
  'focus node': RegExp(r'\bFocusNode\('),
};

/// Every Dart file under [roots], sorted, with forward slashes.
List<String> interfaceFiles([List<String> roots = interfaceRoots]) {
  final out = <String>[];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (path.endsWith('.dart')) out.add(path);
    }
  }
  return out..sort();
}

/// The source with comments and string contents blanked (same length, same line breaks), so a
/// word inside a comment or a message is never taken for code.
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final two = i + 1 < src.length ? src.substring(i, i + 2) : '';
    if (two == '//') {
      while (i < src.length && src[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (two == '/*') {
      while (i < src.length && !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        out.write(src[i] == '\n' ? '\n' : ' ');
        i++;
      }
      out.write('  ');
      i += 2;
    } else if (c == "'" || c == '"') {
      final triple = i + 2 < src.length && src[i + 1] == c && src[i + 2] == c;
      final end = triple ? c * 3 : c;
      out.write(end);
      i += end.length;
      while (i < src.length && !src.startsWith(end, i)) {
        if (src[i] == r'\' && i + 1 < src.length) {
          out.write('  ');
          i += 2;
          continue;
        }
        out.write(src[i] == '\n' ? '\n' : ' ');
        i++;
      }
      out.write(end);
      i += end.length;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The names of the arguments passed directly to the call whose "(" is at [open] (not those of
/// calls nested inside it), and where the call ends.
(Set<String>, int) _namedArgs(String code, int open) {
  final names = <String>{};
  var depth = 0;
  var i = open;
  final name = RegExp(r'[A-Za-z_]\w*');
  for (; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) break;
    } else if (depth == 1 && c == ':') {
      // the word just before this colon
      var j = i - 1;
      while (j > open && code[j] == ' ') {
        j--;
      }
      var k = j;
      while (k > open && RegExp(r'\w').hasMatch(code[k])) {
        k--;
      }
      final word = code.substring(k + 1, j + 1);
      if (name.hasMatch(word)) names.add(word);
    }
  }
  return (names, i);
}

List<Hit> scanFile(String path) {
  final src = File(path).readAsStringSync();
  final code = _codeOnly(src);
  final lines = src.split('\n');
  int lineOf(int offset) => '\n'.allMatches(code.substring(0, offset)).length + 1;
  final hits = <Hit>[];

  for (final call in _calls) {
    final re = RegExp('(?<![\\w.])${RegExp.escape(call.name)}(?:<[^>()]*>)?\\(');
    for (final m in re.allMatches(code)) {
      // a declaration (`const Pressable({…})`, `class Slider(`) is not a use
      final before = code.substring(m.start > 30 ? m.start - 30 : 0, m.start);
      if (RegExp(r'(class|const|factory|extends|implements)\s+$').hasMatch(before) && code.startsWith('{', m.end)) continue;
      if (call.withAny.isNotEmpty) {
        final (names, _) = _namedArgs(code, m.end - 1);
        if (!call.withAny.any(names.contains)) continue;
      }
      final line = lineOf(m.start);
      hits.add(Hit(call.kind, path, line, lines[line - 1].trim()));
    }
  }
  final codeLines = code.split('\n');
  for (var n = 0; n < codeLines.length; n++) {
    for (final p in _patterns.entries) {
      for (final _ in p.value.allMatches(codeLines[n])) {
        hits.add(Hit(p.key, path, n + 1, lines[n].trim()));
      }
    }
  }
  return hits..sort((a, b) => a.line.compareTo(b.line));
}

/// Everything in the interface, file by file.
Map<String, List<Hit>> scanInterface([List<String> roots = interfaceRoots]) => {for (final f in interfaceFiles(roots)) f: scanFile(f)};
