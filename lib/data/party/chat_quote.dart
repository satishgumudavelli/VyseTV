import '../account/account.dart';

/// What a reply shows of the message it answers: in lounges, room chat and DMs. The server copies
/// it when the reply is sent, so the quote stays even once the message it came from is gone.
class ChatQuote {
  const ChatQuote({required this.id, required this.user, this.name = '', required this.body});
  final String id; // the message replied to
  final String user; // who wrote it
  final String name; // their name then ('' in DMs: there are only two of you)
  final String body; // its first 140 characters

  /// A reply to something you wrote: it's highlighted for you, Discord-style.
  bool get toMe => user.isNotEmpty && user == Account.user.value?.id;

  static ChatQuote? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final id = j['id'] as String? ?? '';
    if (id.isEmpty) return null;
    return ChatQuote(id: id, user: j['user'] as String? ?? '', name: j['name'] as String? ?? '', body: j['body'] as String? ?? '');
  }
}
