import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/account/account.dart';
import '../../data/party/chat_quote.dart';
import '../../dpad/dpad_extras.dart';
import '../../dpad/dpad_root.dart' show DpadReturnObserver;
import '../../widgets/common.dart';
import 'party_widgets.dart';

// The chat both lounges and room chat use: messages grouped by who wrote them, replies with what
// they answer above them, replies to you highlighted, and the box to write in with what you're
// replying to above it. A message is a D-pad stop; OK on it opens its menu (Reply first), as a
// right click or a long press does.

String chatClock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Puts the caret in [box] once the menu that was just chosen from has gone (the D-pad kit
/// otherwise returns focus to the message that opened it).
void focusAfterMenu(FocusNode box) => DpadReturnObserver.focusOnceClosed(box);

/// The highlight of a reply to you.
const replyGlow = Color(0x1AFFA53A);
const _red = Color(0xFFFF8A8C);

/// One line of a chat: a message, or a note ("Mara joined").
class ChatLine {
  const ChatLine.message({
    required String this.id,
    required this.user,
    required this.name,
    required this.body,
    required this.created,
    this.avatarUrl = '',
    this.quote,
    this.hidden = false,
  }) : note = null;

  ChatLine.note(String this.note) : id = null, user = '', name = '', body = '', avatarUrl = '', quote = null, hidden = false, created = DateTime.now();

  final String? id;
  final String user;
  final String name;
  final String avatarUrl;
  final String body;
  final ChatQuote? quote; // what this message answers
  final bool hidden; // hidden by reports (moderators only see these)
  final DateTime created;
  final String? note;

  bool get mine => user.isNotEmpty && user == Account.user.value?.id;

  /// Someone else answering you: highlighted.
  bool get toMe => !mine && (quote?.toMe ?? false);

  /// [quote] as a message of this chat, for the box's "Replying to".
  ChatQuote get asQuote => ChatQuote(id: id ?? '', user: user, name: name, body: body.length > 140 ? body.substring(0, 140) : body);
}

/// A menu at [at] (where a right click was, or the middle of a message for OK). [items] are
/// (value, label, danger). A choice that moves focus on (Reply) says so with [focusAfterMenu].
Future<String?> showChatMenu(BuildContext context, Offset at, List<(String, String, bool)> items) => showMenu<String>(
  context: context,
  color: VyseColors.surfaceHi,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
  items: [
    for (final (value, label, danger) in items)
      PopupMenuItem(
        value: value,
        child: Text(label, style: danger ? const TextStyle(color: _red) : null),
      ),
  ],
);

/// What a reply answers, shown above it: a thin elbow, who, and the start of what they said.
class ChatQuoteView extends StatelessWidget {
  const ChatQuoteView({super.key, required this.quote, this.name, this.dark = false});
  final ChatQuote quote;

  /// Who wrote it, when the quote has no name of its own (DMs).
  final String? name;

  /// On an orange bubble (your own DM).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final who = quote.toMe ? 'you' : (quote.name.isNotEmpty ? quote.name : (name ?? ''));
    final faint = dark ? Colors.black.withValues(alpha: .6) : VyseColors.textFaint;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: faint),
          const SizedBox(width: 4),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  if (who.isNotEmpty)
                    TextSpan(
                      text: '$who  ',
                      style: TextStyle(fontWeight: FontWeight.w800, color: quote.toMe && !dark ? VyseColors.accent : (dark ? Colors.black : VyseColors.textDim)),
                    ),
                  TextSpan(text: quote.body.replaceAll('\n', ' ')),
                ],
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: faint),
            ),
          ),
        ],
      ),
    );
  }
}

/// The messages, newest at the bottom. [onMenu] opens a message's menu.
class PartyChatList extends StatelessWidget {
  const PartyChatList({super.key, required this.lines, required this.scroll, required this.intro, required this.onMenu, this.loadingOlder = false});
  final List<ChatLine> lines; // oldest first
  final ScrollController scroll;

  /// The faint line above the first message ("Room chat. It disappears when the room closes.").
  final String intro;
  final void Function(BuildContext context, ChatLine line, Offset at) onMenu;

  /// Older messages are on their way (a spinner at the top).
  final bool loadingOlder;

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: scroll,
    reverse: true,
    // dragging the messages puts the keyboard away, as chats do
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
    itemCount: lines.length + 1,
    itemBuilder: (context, i) {
      if (i == lines.length) {
        if (loadingOlder) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(intro, style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
        );
      }
      final idx = lines.length - 1 - i;
      final line = lines[idx];
      if (line.note != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.arrow_right_alt_rounded, size: 16, color: VyseColors.textFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  line.note!,
                  style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      }
      final prev = idx > 0 && lines[idx - 1].note == null ? lines[idx - 1] : null;
      // a reply always shows who wrote it, under what it answers
      final first = line.quote != null || prev == null || prev.user != line.user || line.created.difference(prev.created) > const Duration(minutes: 5);
      Widget row = Padding(
        padding: EdgeInsets.only(top: first ? 12 : 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 38,
              child: first ? Padding(padding: EdgeInsets.only(top: line.quote != null ? 18 : 0), child: PartyAvatar(url: line.avatarUrl, name: line.name, size: 34)) : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (line.quote != null) ChatQuoteView(quote: line.quote!),
                  if (first)
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            line.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: line.mine ? VyseColors.accent : VyseColors.text),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(chatClock(line.created), style: const TextStyle(fontSize: 11, color: VyseColors.textFaint)),
                      ],
                    ),
                  if (line.hidden)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 2),
                      child: Text('Hidden after reports. Only moderators see it.', style: TextStyle(fontSize: 11.5, color: _red, fontWeight: FontWeight.w700)),
                    ),
                  Text(
                    line.body,
                    style: TextStyle(fontSize: 14, height: 1.4, color: line.hidden ? VyseColors.textDim : null),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      if (line.toMe) {
        // a reply to you: lit up, with a bar down its side
        row = Container(
          margin: EdgeInsets.only(top: first ? 6 : 0),
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
          decoration: const BoxDecoration(
            color: replyGlow,
            border: Border(left: BorderSide(color: VyseColors.accent, width: 3)),
          ),
          child: row,
        );
      }
      // right-click or long-press: the message's menu. With a D-pad a message is a stop and OK
      // opens the same menu.
      return DpadMenuStop(
        onMenu: (at) => onMenu(context, line, at),
        child: GestureDetector(
          onSecondaryTapDown: (d) => onMenu(context, line, d.globalPosition),
          onLongPressStart: (d) => onMenu(context, line, d.globalPosition),
          child: row,
        ),
      );
    },
  );
}

/// "Replying to Mara", with × to stop replying.
class ReplyBar extends StatelessWidget {
  const ReplyBar({super.key, required this.quote, required this.onCancel, this.name});
  final ChatQuote quote;
  final VoidCallback onCancel;
  final String? name; // who wrote it, when the quote has no name (DMs)

  @override
  Widget build(BuildContext context) {
    final who = quote.toMe ? 'yourself' : (quote.name.isNotEmpty ? quote.name : (name ?? ''));
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 0, 4),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, size: 16, color: VyseColors.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Replying to '),
                  TextSpan(
                    text: who,
                    style: const TextStyle(fontWeight: FontWeight.w800, color: VyseColors.text),
                  ),
                  TextSpan(text: '  ${quote.body.replaceAll('\n', ' ')}'),
                ],
              ),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim),
            ),
          ),
          // part of the text box as far as taps go: the keyboard stays up
          TextFieldTapRegion(
            child: Pressable(
              onTap: onCancel,
              tooltip: 'Stop replying',
              builder: (context, hovered, _) => Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded, size: 16, color: hovered ? VyseColors.text : VyseColors.textDim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The box to write in: Enter sends (a phone's own Send key on a phone), what you're replying to
/// above it. [notice] in place of the box when you can't post, with [action] beside it.
class PartyChatInput extends StatelessWidget {
  const PartyChatInput({
    super.key,
    required this.input,
    required this.focus,
    required this.sending,
    required this.onSend,
    required this.hint,
    this.autofocus = false,
    this.maxLength = 1000,
    this.replying,
    this.onCancelReply,
    this.notice,
    this.action,
  });
  final TextEditingController input;
  final FocusNode focus;
  final bool sending;
  final VoidCallback onSend;
  final String hint;
  final bool autofocus;
  final int maxLength;
  final ChatQuote? replying;
  final VoidCallback? onCancelReply;
  final String? notice;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final bottom = 12 + MediaQuery.paddingOf(context).bottom;
    if (notice != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 6, 12, bottom),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(
            color: partyCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: VyseColors.stroke),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  notice!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                ),
              ),
              ?action,
            ],
          ),
        ),
      );
    }
    final box = Container(
      padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
      decoration: BoxDecoration(
        color: partyCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: replying != null ? VyseColors.accent.withValues(alpha: .5) : VyseColors.stroke),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): onSend,
                if (replying != null && onCancelReply != null) const SingleActivator(LogicalKeyboardKey.escape): onCancelReply!,
              },
              child: TextField(
                controller: input,
                focusNode: focus,
                autofocus: autofocus,
                minLines: 1,
                maxLines: 4,
                maxLength: maxLength,
                // a phone's keyboard has its own Send key; sending keeps it up for the next message
                textInputAction: hasSoftKeyboard ? TextInputAction.send : TextInputAction.newline,
                onEditingComplete: hasSoftKeyboard ? () {} : null,
                onSubmitted: hasSoftKeyboard ? (_) => onSend() : null,
                onTapOutside: dismissKeyboard,
                style: const TextStyle(fontSize: 14, height: 1.35),
                cursorColor: VyseColors.accent,
                decoration: InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                  hintText: hint,
                  hintMaxLines: 1,
                  hintStyle: const TextStyle(color: VyseColors.textFaint),
                ),
              ),
            ),
          ),
          // part of the text box as far as taps go: pressing Send leaves the keyboard up
          TextFieldTapRegion(
            child: IconButton(
              tooltip: 'Send',
              onPressed: sending ? null : onSend,
              icon: sending
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))
                  : const Icon(Icons.send_rounded, color: VyseColors.accent, size: 20),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6, 12, bottom),
      child: replying == null
          ? box
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ReplyBar(quote: replying!, onCancel: onCancelReply ?? () {}),
                box,
              ],
            ),
    );
  }
}
