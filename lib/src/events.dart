import 'dart:convert';

import 'types.dart';

/// A non-fatal malformed response or realtime frame from Kick.
final class KickProtocolException implements Exception {
  const KickProtocolException(this.message);
  final String message;

  @override
  String toString() => 'KickProtocolException: $message';
}

/// Base type for every public realtime event emitted by Kick.
sealed class KickEvent {
  const KickEvent(this.eventName, this.raw);
  final String eventName;
  final Map<String, dynamic> raw;
}

final class KickChatMessageEvent extends KickEvent {
  KickChatMessageEvent(super.name, super.raw)
      : message = ChatMessage.fromJson(raw);
  final ChatMessage message;
}

final class KickMessageDeletedEvent extends KickEvent {
  KickMessageDeletedEvent(super.name, super.raw)
      : messageId = _map(raw['message'])['id']?.toString() ?? '',
        aiModerated = raw['aiModerated'] as bool? ?? false,
        violatedRules = _strings(raw['violatedRules']);
  final String messageId;
  final bool aiModerated;
  final List<String> violatedRules;
}

final class KickSubscriptionEvent extends KickEvent {
  KickSubscriptionEvent(super.name, super.raw)
      : username = raw['username']?.toString() ?? '',
        months = (raw['months'] as num?)?.toInt() ?? 0,
        customMessage = raw['custom_message']?.toString() ?? '';
  final String username;
  final int months;
  final String customMessage;
}

final class KickGiftChunk {
  const KickGiftChunk({
    required this.correlationId,
    required this.index,
    required this.total,
  });
  factory KickGiftChunk.fromJson(Map<String, dynamic> json) => KickGiftChunk(
        correlationId: json['correlation_id']?.toString() ?? '',
        index: (json['chunk_index'] as num?)?.toInt() ?? 0,
        total: (json['total_chunks'] as num?)?.toInt() ?? 0,
      );
  final String correlationId;
  final int index;
  final int total;
}

final class KickGiftedSubscriptionsEvent extends KickEvent {
  KickGiftedSubscriptionsEvent(super.name, super.raw)
      : gifterUsername = raw['gifter_username']?.toString() ?? '',
        giftedUsernames = _strings(raw['gifted_usernames']),
        gifterTotal = (raw['gifter_total'] as num?)?.toInt() ?? 0,
        giftedTotal = (raw['gifted_total'] as num?)?.toInt() ?? 0,
        chunk = _map(raw['chunk_details']).isEmpty
            ? null
            : KickGiftChunk.fromJson(_map(raw['chunk_details']));
  final String gifterUsername;
  final List<String> giftedUsernames;
  final int gifterTotal;
  final int giftedTotal;
  final KickGiftChunk? chunk;
}

final class KickPinnedMessageCreatedEvent extends KickEvent {
  KickPinnedMessageCreatedEvent(super.name, super.raw)
      : message = ChatMessage.fromJson(_map(raw['message'])),
        pinnedBy = Sender.fromJson(
          _map(raw['pinnedBy']).isNotEmpty
              ? _map(raw['pinnedBy'])
              : _map(raw['pinned_by']),
        ),
        durationMinutes = (raw['duration'] as num?)?.toInt() ?? 0;
  final ChatMessage message;
  final Sender pinnedBy;
  final int durationMinutes;
}

final class KickPinnedMessageDeletedEvent extends KickEvent {
  const KickPinnedMessageDeletedEvent(super.name, super.raw);
}

final class KickChatroomClearedEvent extends KickEvent {
  const KickChatroomClearedEvent(super.name, super.raw);
}

final class KickUserBannedEvent extends KickEvent {
  KickUserBannedEvent(super.name, super.raw)
      : user = Sender.fromJson(_map(raw['user'])),
        bannedBy = Sender.fromJson(_map(raw['banned_by'])),
        permanent = raw['permanent'] as bool? ?? false,
        durationSeconds = (raw['duration'] as num?)?.toInt() ?? 0,
        expiresAt = DateTime.tryParse(raw['expires_at']?.toString() ?? '');
  final Sender user;
  final Sender bannedBy;
  final bool permanent;
  final int durationSeconds;
  final DateTime? expiresAt;
}

final class KickUserUnbannedEvent extends KickEvent {
  KickUserUnbannedEvent(super.name, super.raw)
      : user = Sender.fromJson(_map(raw['user']));
  final Sender user;
}

/// A recognized event whose evolving payload remains available through [raw].
final class KickKnownEvent extends KickEvent {
  const KickKnownEvent(super.name, super.raw);
}

/// A future event unknown to this library. No fields are discarded.
final class KickUnknownEvent extends KickEvent {
  const KickUnknownEvent(super.name, super.raw);
}

/// Parses the event name and JSON data used by Kick's Pusher transport.
KickEvent parseKickEvent(String eventName, Object? data) {
  final raw = _decodeMap(data);
  return switch (eventName) {
    r'App\Events\ChatMessageEvent' => KickChatMessageEvent(eventName, raw),
    r'App\Events\MessageDeletedEvent' =>
      KickMessageDeletedEvent(eventName, raw),
    r'App\Events\SubscriptionEvent' => KickSubscriptionEvent(eventName, raw),
    'GiftedSubscriptionsEvent' => KickGiftedSubscriptionsEvent(eventName, raw),
    r'App\Events\PinnedMessageCreatedEvent' =>
      KickPinnedMessageCreatedEvent(eventName, raw),
    r'App\Events\PinnedMessageDeletedEvent' =>
      KickPinnedMessageDeletedEvent(eventName, raw),
    r'App\Events\ChatroomClearEvent' =>
      KickChatroomClearedEvent(eventName, raw),
    r'App\Events\UserBannedEvent' => KickUserBannedEvent(eventName, raw),
    r'App\Events\UserUnbannedEvent' => KickUserUnbannedEvent(eventName, raw),
    'RewardRedeemedEvent' ||
    r'App\Events\StreamHostedEvent' ||
    'GoalCreatedEvent' ||
    'GoalUpdatedEvent' ||
    'GoalProgressUpdateEvent' ||
    'GoalAchievedEvent' ||
    'GoalCanceledEvent' ||
    'KicksGifted' ||
    r'App\Events\PollUpdateEvent' ||
    r'App\Events\PollDeleteEvent' ||
    r'App\Events\LivestreamUpdated' ||
    r'App\Events\StreamerIsLive' ||
    r'App\Events\StopStreamBroadcast' ||
    r'App\Events\ChatMoveToSupportedChannelEvent' =>
      KickKnownEvent(eventName, raw),
    _ => KickUnknownEvent(eventName, raw),
  };
}

Map<String, dynamic> _decodeMap(Object? data) {
  Object? decoded = data;
  if (data is String) {
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      throw const KickProtocolException('invalid event JSON');
    }
  }
  if (decoded is! Map) {
    throw const KickProtocolException('event data is not an object');
  }
  return Map<String, dynamic>.unmodifiable(decoded);
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<String> _strings(Object? value) =>
    value is List ? value.map((item) => item.toString()).toList() : const [];
