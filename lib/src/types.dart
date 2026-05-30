import 'package:dart_kick_chat/src/emotes.dart';

class Badge {
  final String type;
  final String text;
  final int count;

  const Badge({
    required this.type,
    required this.text,
    required this.count,
  });

  factory Badge.fromJson(Map<String, dynamic> json) => Badge(
        type: json['type'] as String? ?? '',
        text: json['text'] as String? ?? '',
        count: json['count'] as int? ?? 0,
      );
}

class Identity {
  final String color;
  final List<Badge> badges;

  const Identity({required this.color, required this.badges});

  factory Identity.fromJson(Map<String, dynamic> json) => Identity(
        color: json['color'] as String? ?? '',
        badges: (json['badges'] as List<dynamic>? ?? [])
            .map((b) => Badge.fromJson(b as Map<String, dynamic>))
            .toList(),
      );
}

class Sender {
  final int id;
  final String username;
  final String slug;
  final Identity identity;

  const Sender({
    required this.id,
    required this.username,
    required this.slug,
    required this.identity,
  });

  factory Sender.fromJson(Map<String, dynamic> json) => Sender(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        identity: Identity.fromJson(
          json['identity'] as Map<String, dynamic>? ?? {},
        ),
      );
}

/// A single Kick emote extracted from message content.
class ParsedEmote {
  final String id;
  final String name;

  /// CDN URL: https://files.kick.com/emotes/{id}/fullsize
  final String url;

  const ParsedEmote({
    required this.id,
    required this.name,
    required this.url,
  });
}

/// One segment of a parsed chat message.
/// Exactly one of [text] (non-empty) or [emote] (non-null) is set.
class MessagePart {
  final String text;
  final ParsedEmote? emote;

  const MessagePart.text(this.text) : emote = null;
  const MessagePart.emote(ParsedEmote this.emote) : text = '';

  bool get isEmote => emote != null;
}

/// A single chat message received from Kick.
class ChatMessage {
  final String id;
  final int chatroomId;

  /// Raw content — may contain [emote:id:name] tokens.
  final String content;

  final String type;
  final DateTime createdAt;
  final Sender sender;

  /// Unique emotes present in [content] (deduplicated).
  final List<ParsedEmote> emotes;

  /// [content] split into ordered text+emote segments — use this for rendering.
  final List<MessagePart> parts;

  const ChatMessage({
    required this.id,
    required this.chatroomId,
    required this.content,
    required this.type,
    required this.createdAt,
    required this.sender,
    required this.emotes,
    required this.parts,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final content = json['content'] as String? ?? '';
    return ChatMessage(
      id: json['id'] as String? ?? '',
      chatroomId: (json['chatroom_id'] as num?)?.toInt() ?? 0,
      content: content,
      type: json['type'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      sender: Sender.fromJson(
        json['sender'] as Map<String, dynamic>? ?? {},
      ),
      emotes: parseEmotes(content),
      parts: parseMessage(content),
    );
  }
}
