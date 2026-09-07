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
  KickChatMessageEvent(
    super.name,
    super.raw, {
    Map<String, ParsedEmote> externalEmotes = const {},
  }) : message = ChatMessage.fromJson(raw, externalEmotes: externalEmotes);
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

/// A channel-points reward redeemed through Kick's public realtime transport.
final class KickRewardRedeemedEvent extends KickEvent {
  KickRewardRedeemedEvent(super.name, super.raw)
      : redemptionId = _string(raw, const ['redemption_id', 'id']),
        reward = KickReward.fromJson(
          _firstMap(raw, const ['reward', 'channel_reward']),
        ),
        redeemer = Sender.fromJson(
          _firstMap(raw, const ['redeemer', 'user', 'sender']),
        ),
        userInput = _string(raw, const ['user_input', 'message', 'input']),
        status = _string(raw, const ['status']),
        redeemedAt = _date(raw, const ['redeemed_at', 'created_at']);

  final String redemptionId;
  final KickReward reward;
  final Sender redeemer;
  final String userInput;
  final String status;
  final DateTime? redeemedAt;
}

/// Public details describing a redeemed Kick channel-points reward.
final class KickReward {
  const KickReward({
    required this.id,
    required this.title,
    required this.description,
    required this.cost,
    required this.raw,
  });

  factory KickReward.fromJson(Map<String, dynamic> json) => KickReward(
        id: _string(json, const ['id', 'reward_id']),
        title: _string(json, const ['title', 'name']),
        description: _string(json, const ['description']),
        cost: _integer(json, const ['cost', 'price', 'points']),
        raw: Map.unmodifiable(json),
      );

  final String id;
  final String title;
  final String description;
  final int? cost;
  final Map<String, dynamic> raw;
}

/// A monetary KICK gift visible on Kick's public channel topic.
final class KickKicksGiftedEvent extends KickEvent {
  KickKicksGiftedEvent(super.name, super.raw)
      : transactionId = _string(
          raw,
          const ['gift_transaction_id', 'transaction_id', 'id'],
        ),
        sender = Sender.fromJson(
          _firstMap(raw, const ['sender', 'supporter', 'gifter', 'user']),
        ),
        gift = KickGift.fromJson(
          _firstMap(raw, const ['gift', 'kicks', 'kicks_gift']),
        ),
        message = _string(raw, const ['message', 'comment', 'note']),
        createdAt = _date(raw, const ['created_at']);

  final String transactionId;
  final Sender sender;
  final KickGift gift;
  final String message;
  final DateTime? createdAt;
}

/// Public product details included with a KICK gift.
final class KickGift {
  const KickGift({
    required this.id,
    required this.name,
    required this.amount,
    required this.type,
    required this.tier,
    required this.pinnedTimeSeconds,
    required this.imageUrl,
    required this.message,
    required this.raw,
  });

  factory KickGift.fromJson(Map<String, dynamic> json) {
    final id = _string(json, const ['gift_id', 'id']);
    final explicitImage = _string(
      json,
      const ['image_url', 'imageUrl', 'thumbnail_url', 'thumbnailUrl'],
    );
    final normalizedId = id.replaceAll('_', '-');
    return KickGift(
      id: id,
      name: _string(json, const ['name', 'title']),
      amount: _integer(json, const ['amount', 'value']),
      type: _string(json, const ['type']),
      tier: _string(json, const ['tier']),
      pinnedTimeSeconds: _integer(
        json,
        const ['pinned_time_seconds', 'pinned_time'],
      ),
      imageUrl: explicitImage.isNotEmpty ||
              normalizedId.isEmpty ||
              !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(normalizedId)
          ? explicitImage
          : 'https://files.kick.com/kicks/gifts/$normalizedId.webp',
      message: _string(json, const ['message']),
      raw: Map.unmodifiable(json),
    );
  }

  final String id;
  final String name;
  final int? amount;
  final String type;
  final String tier;
  final int? pinnedTimeSeconds;
  final String imageUrl;
  final String message;
  final Map<String, dynamic> raw;
}

/// A selectable answer and its current public tally in a Kick poll.
final class KickPollOption {
  const KickPollOption({
    required this.id,
    required this.label,
    required this.votes,
    required this.raw,
  });

  factory KickPollOption.fromJson(Map<String, dynamic> json) => KickPollOption(
        id: _string(json, const ['id', 'option_id']),
        label: _string(json, const ['label', 'title', 'text']),
        votes: _integer(json, const ['votes', 'vote_count', 'count']),
        raw: Map.unmodifiable(json),
      );

  final String id;
  final String label;
  final int? votes;
  final Map<String, dynamic> raw;
}

/// The current public state of a Kick poll.
final class KickPollUpdatedEvent extends KickEvent {
  KickPollUpdatedEvent(super.name, super.raw)
      : pollId = _string(
          _firstMap(raw, const ['poll']).isEmpty
              ? raw
              : _firstMap(raw, const ['poll']),
          const ['id', 'poll_id'],
        ),
        title = _string(
          _firstMap(raw, const ['poll']).isEmpty
              ? raw
              : _firstMap(raw, const ['poll']),
          const ['title', 'question'],
        ),
        status = _string(raw, const ['status']),
        durationSeconds = _integer(raw, const ['duration', 'duration_seconds']),
        endsAt = _date(raw, const ['ends_at', 'expires_at']),
        options = _maps(
          _firstMap(raw, const ['poll']).isEmpty
              ? raw['options']
              : _firstMap(raw, const ['poll'])['options'],
        ).map(KickPollOption.fromJson).toList(growable: false);

  final String pollId;
  final String title;
  final String status;
  final int? durationSeconds;
  final DateTime? endsAt;
  final List<KickPollOption> options;
}

/// Identifies a poll removed from the public chat.
final class KickPollDeletedEvent extends KickEvent {
  KickPollDeletedEvent(super.name, super.raw)
      : pollId = _string(raw, const ['id', 'poll_id']);
  final String pollId;
}

enum KickGoalAction { created, updated, progress, achieved, canceled }

/// The current state of a public Kick creator goal.
final class KickGoalEvent extends KickEvent {
  KickGoalEvent(super.name, super.raw, this.action)
      : goalId = _string(raw, const ['id', 'goal_id']),
        title = _string(raw, const ['title', 'name', 'description']),
        current = _integer(raw, const ['current', 'progress', 'current_value']),
        target = _integer(raw, const ['target', 'goal', 'target_value']),
        status = _string(raw, const ['status']),
        endsAt = _date(raw, const ['ends_at', 'expires_at']);

  final KickGoalAction action;
  final String goalId;
  final String title;
  final int? current;
  final int? target;
  final String status;
  final DateTime? endsAt;
}

/// A public Kick host event received from a channel topic.
final class KickStreamHostedEvent extends KickEvent {
  KickStreamHostedEvent(super.name, super.raw)
      : host = Sender.fromJson(
          _firstMap(raw, const ['host', 'hoster', 'sender', 'user']),
        ),
        hostedChannel = _string(
          _firstMap(raw, const ['channel', 'hosted_channel']),
          const ['slug', 'username', 'name'],
        ),
        viewerCount = _integer(
          raw,
          const ['viewer_count', 'viewers', 'number_viewers'],
        );

  final Sender host;
  final String hostedChannel;
  final int? viewerCount;
}

enum KickLivestreamAction { updated, started, stopped }

/// A public realtime update to a Kick livestream.
final class KickLivestreamEvent extends KickEvent {
  KickLivestreamEvent(super.name, super.raw, this.action)
      : livestreamId = _string(raw, const ['id', 'livestream_id']),
        title = _string(raw, const ['session_title', 'title']),
        viewerCount = _integer(raw, const ['viewer_count', 'viewers']),
        createdAt = _date(raw, const ['created_at', 'start_time']);

  final KickLivestreamAction action;
  final String livestreamId;
  final String title;
  final int? viewerCount;
  final DateTime? createdAt;
}

/// A public notice that chat moved to another supported Kick channel.
final class KickChatMovedEvent extends KickEvent {
  KickChatMovedEvent(super.name, super.raw)
      : channelId = _integer(raw, const ['channel_id', 'supported_channel_id']),
        channelSlug = _string(raw, const ['slug', 'channel_slug']);

  final int? channelId;
  final String channelSlug;
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
KickEvent parseKickEvent(
  String eventName,
  Object? data, {
  Map<String, ParsedEmote> externalEmotes = const {},
}) {
  final raw = _decodeMap(data);
  return switch (eventName) {
    r'App\Events\ChatMessageEvent' => KickChatMessageEvent(
        eventName,
        raw,
        externalEmotes: externalEmotes,
      ),
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
    'RewardRedeemedEvent' => KickRewardRedeemedEvent(eventName, raw),
    'KicksGifted' => KickKicksGiftedEvent(eventName, raw),
    r'App\Events\PollUpdateEvent' => KickPollUpdatedEvent(eventName, raw),
    r'App\Events\PollDeleteEvent' => KickPollDeletedEvent(eventName, raw),
    'GoalCreatedEvent' => KickGoalEvent(eventName, raw, KickGoalAction.created),
    'GoalUpdatedEvent' => KickGoalEvent(eventName, raw, KickGoalAction.updated),
    'GoalProgressUpdateEvent' =>
      KickGoalEvent(eventName, raw, KickGoalAction.progress),
    'GoalAchievedEvent' =>
      KickGoalEvent(eventName, raw, KickGoalAction.achieved),
    'GoalCanceledEvent' =>
      KickGoalEvent(eventName, raw, KickGoalAction.canceled),
    r'App\Events\StreamHostedEvent' => KickStreamHostedEvent(eventName, raw),
    r'App\Events\LivestreamUpdated' =>
      KickLivestreamEvent(eventName, raw, KickLivestreamAction.updated),
    r'App\Events\StreamerIsLive' =>
      KickLivestreamEvent(eventName, raw, KickLivestreamAction.started),
    r'App\Events\StopStreamBroadcast' =>
      KickLivestreamEvent(eventName, raw, KickLivestreamAction.stopped),
    r'App\Events\ChatMoveToSupportedChannelEvent' =>
      KickChatMovedEvent(eventName, raw),
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

Iterable<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from)
    : const <Map<String, dynamic>>[];

Map<String, dynamic> _firstMap(
  Map<String, dynamic> source,
  List<String> keys,
) {
  for (final key in keys) {
    final value = _map(source[key]);
    if (value.isNotEmpty) return value;
  }
  return const {};
}

String _string(Map<String, dynamic> source, List<String> keys) {
  for (final key in keys) {
    final value = source[key];
    if (value != null && value.toString().trim().isNotEmpty) {
      return value.toString();
    }
  }
  return '';
}

int? _integer(Map<String, dynamic> source, List<String> keys) {
  for (final key in keys) {
    final value = source[key];
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return null;
}

DateTime? _date(Map<String, dynamic> source, List<String> keys) {
  final value = _string(source, keys);
  return value.isEmpty ? null : DateTime.tryParse(value);
}
