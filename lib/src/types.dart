import 'dart:convert';

import 'package:dart_kick_chat/src/emotes.dart';

/// A legacy badge attached to a Kick chat identity.
class Badge {
  const Badge({required this.type, required this.text, required this.count});

  factory Badge.fromJson(Map<String, dynamic> json) => Badge(
        type: json['type'] as String? ?? '',
        text: json['text'] as String? ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );

  final String type;
  final String text;
  final int count;
}

/// A current-generation Kick badge, including its image and metadata.
class BadgeV2 {
  const BadgeV2({
    required this.name,
    required this.badgeType,
    required this.imageUrl,
    required this.selected,
    required this.sortOrder,
    required this.metadata,
  });

  factory BadgeV2.fromJson(Map<String, dynamic> json) => BadgeV2(
        name: json['name'] as String? ?? '',
        badgeType: json['badge_type'] as String? ?? '',
        imageUrl: json['image_url'] as String? ?? '',
        selected: json['selected'] as bool? ?? false,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        metadata: _map(json['metadata']),
      );

  final String name;
  final String badgeType;
  final String imageUrl;
  final bool selected;
  final int sortOrder;
  final Map<String, dynamic> metadata;
}

/// Badge and color information supplied with a chat sender.
class Identity {
  const Identity({
    required this.color,
    required this.badges,
    this.badgesV2 = const [],
  });

  factory Identity.fromJson(Map<String, dynamic> json) => Identity(
        color: json['color'] as String? ?? '',
        badges: _maps(json['badges']).map(Badge.fromJson).toList(),
        badgesV2: _maps(json['badges_v2']).map(BadgeV2.fromJson).toList(),
      );

  final String color;
  final List<Badge> badges;
  final List<BadgeV2> badgesV2;

  bool get isBroadcaster => _hasRole({'broadcaster', 'channel_owner', 'owner'});
  bool get isModerator => _hasRole({'moderator', 'mod'});
  bool get isSubscriber => _hasRole({'subscriber', 'sub', 'founder'});
  bool get isVip => _hasRole({'vip'});
  bool get isVerified => _hasRole({'verified'});

  bool _hasRole(Set<String> roles) {
    final values = <String>{
      for (final badge in badges) ...[badge.type, badge.text],
      for (final badge in badgesV2) ...[badge.name, badge.badgeType],
    }.map((value) => value.toLowerCase().replaceAll('-', '_'));
    return values.any((value) => roles.any(value.contains));
  }
}

/// A public Kick user included in chat and moderation payloads.
class Sender {
  const Sender({
    required this.id,
    required this.username,
    required this.slug,
    required this.identity,
    this.profilePictureUrl = '',
  });

  factory Sender.fromJson(Map<String, dynamic> json) => Sender(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        profilePictureUrl: json['profile_pic'] as String? ??
            json['profilepic'] as String? ??
            '',
        identity: Identity.fromJson(_map(json['identity'])),
      );

  final int id;
  final String username;
  final String slug;
  final Identity identity;
  final String profilePictureUrl;
}

class MessageReferenceSender {
  const MessageReferenceSender({required this.id, required this.username});
  factory MessageReferenceSender.fromJson(Map<String, dynamic> json) =>
      MessageReferenceSender(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
      );
  final int id;
  final String username;
}

class MessageReference {
  const MessageReference({required this.id, required this.content});
  factory MessageReference.fromJson(Map<String, dynamic> json) =>
      MessageReference(
        id: json['id'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
  final String id;
  final String content;
}

/// A subscription or reward celebration embedded in chat metadata.
class ChatCelebration {
  const ChatCelebration({
    required this.type,
    required this.totalMonths,
    required this.raw,
  });
  factory ChatCelebration.fromJson(Map<String, dynamic> json) =>
      ChatCelebration(
        type: json['type'] as String? ?? '',
        totalMonths: (json['total_months'] as num?)?.toInt() ?? 0,
        raw: Map.unmodifiable(json),
      );
  final String type;
  final int totalMonths;
  final Map<String, dynamic> raw;
}

/// Structured metadata attached to a live or historical chat message.
class ChatMessageMetadata {
  const ChatMessageMetadata({
    required this.messageReference,
    required this.originalSender,
    required this.originalMessage,
    required this.raw,
    this.celebration,
  });

  factory ChatMessageMetadata.fromJson(Object? value) {
    final raw = _metadataMap(value);
    final sender = _map(raw['original_sender']);
    final message = _map(raw['original_message']);
    return ChatMessageMetadata(
      messageReference: raw['message_ref']?.toString() ?? '',
      originalSender:
          sender.isEmpty ? null : MessageReferenceSender.fromJson(sender),
      originalMessage:
          message.isEmpty ? null : MessageReference.fromJson(message),
      celebration: _map(raw['celebration']).isEmpty
          ? null
          : ChatCelebration.fromJson(_map(raw['celebration'])),
      raw: raw,
    );
  }

  final String messageReference;
  final MessageReferenceSender? originalSender;
  final MessageReference? originalMessage;
  final Map<String, dynamic> raw;
  final ChatCelebration? celebration;
}

class ParsedEmote {
  const ParsedEmote({required this.id, required this.name, required this.url});
  final String id;
  final String name;
  final String url;
}

class MessagePart {
  const MessagePart.text(this.text) : emote = null;
  const MessagePart.emote(ParsedEmote this.emote) : text = '';
  final String text;
  final ParsedEmote? emote;
  bool get isEmote => emote != null;
}

/// A single chat message received from Kick or its history endpoint.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatroomId,
    required this.content,
    required this.type,
    required this.createdAt,
    required this.sender,
    required this.emotes,
    required this.parts,
    this.metadata = const ChatMessageMetadata(
      messageReference: '',
      originalSender: null,
      originalMessage: null,
      raw: {},
      celebration: null,
    ),
    this.threadParentId,
    this.raw = const {},
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final content = json['content'] as String? ?? '';
    return ChatMessage(
      id: json['id'] as String? ?? '',
      chatroomId: (json['chatroom_id'] as num?)?.toInt() ??
          (json['chat_id'] as num?)?.toInt() ??
          0,
      content: content,
      type: json['type'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sender: Sender.fromJson(_map(json['sender'])),
      emotes: parseEmotes(content),
      parts: parseMessage(content),
      metadata: ChatMessageMetadata.fromJson(json['metadata']),
      threadParentId: json['thread_parent_id'] as String?,
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  final String id;
  final int chatroomId;
  final String content;
  final String type;
  final DateTime createdAt;
  final Sender sender;
  final List<ParsedEmote> emotes;
  final List<MessagePart> parts;
  final ChatMessageMetadata metadata;
  final String? threadParentId;
  final Map<String, dynamic> raw;
}

Map<String, dynamic> _metadataMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String && value.isNotEmpty && value != 'null') {
    try {
      return _map(jsonDecode(value));
    } catch (_) {
      // Unknown formats remain available in ChatMessage.raw.
    }
  }
  return const {};
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

Iterable<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from)
    : const <Map<String, dynamic>>[];
