import 'dart:convert';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  test('parses chat messages while preserving reply metadata', () {
    final event = parseKickEvent(
      r'App\Events\ChatMessageEvent',
      jsonEncode({
        'id': 'message-1',
        'chatroom_id': 9,
        'content': 'reply',
        'type': 'reply',
        'created_at': '2026-09-06T12:00:00Z',
        'thread_parent_id': 'parent-1',
        'metadata': {
          'message_ref': 'ref-1',
          'original_sender': {'id': 4, 'username': 'original'},
          'original_message': {'id': 'parent-1', 'content': 'hello'},
        },
        'sender': {
          'id': 7,
          'username': 'viewer',
          'slug': 'viewer',
          'identity': {'color': '#fff', 'badges': [], 'badges_v2': []},
        },
      }),
    );

    expect(event, isA<KickChatMessageEvent>());
    final message = (event as KickChatMessageEvent).message;
    expect(message.threadParentId, 'parent-1');
    expect(message.metadata.messageReference, 'ref-1');
    expect(message.metadata.originalMessage?.content, 'hello');
    expect(message.metadata.originalSender?.username, 'original');
  });

  test('models moderation, subscriptions, gifts and pins', () {
    expect(
      parseKickEvent(
        r'App\Events\MessageDeletedEvent',
        jsonEncode({
          'message': {'id': 'deleted'},
          'aiModerated': true,
          'violatedRules': ['spam'],
        }),
      ),
      isA<KickMessageDeletedEvent>()
          .having((event) => event.messageId, 'message id', 'deleted')
          .having((event) => event.aiModerated, 'AI moderated', isTrue),
    );
    expect(
      parseKickEvent(
        r'App\Events\SubscriptionEvent',
        jsonEncode({'username': 'member', 'months': 1, 'custom_message': 'hi'}),
      ),
      isA<KickSubscriptionEvent>().having((event) => event.months, 'months', 1),
    );
    expect(
      parseKickEvent(
        'GiftedSubscriptionsEvent',
        jsonEncode({
          'gifter_username': 'gifter',
          'gifted_usernames': ['one', 'two'],
          'gifter_total': 8,
          'gifted_total': 2,
          'chunk_details': {
            'correlation_id': 'batch',
            'chunk_index': 0,
            'total_chunks': 1,
          },
        }),
      ),
      isA<KickGiftedSubscriptionsEvent>()
          .having((event) => event.giftedTotal, 'gifted total', 2)
          .having((event) => event.chunk?.correlationId, 'batch', 'batch'),
    );
    expect(
      parseKickEvent(
        r'App\Events\PinnedMessageCreatedEvent',
        jsonEncode({
          'duration': 5,
          'message': _messageJson('pinned'),
          'pinnedBy': {'id': 2, 'username': 'mod', 'slug': 'mod'},
        }),
      ),
      isA<KickPinnedMessageCreatedEvent>()
          .having((event) => event.durationMinutes, 'duration', 5)
          .having((event) => event.message.id, 'message', 'pinned'),
    );
  });

  test('models lifecycle and retains unknown renderers losslessly', () {
    expect(
      parseKickEvent(r'App\Events\ChatroomClearEvent', '{}'),
      isA<KickChatroomClearedEvent>(),
    );
    expect(
      parseKickEvent(r'App\Events\PinnedMessageDeletedEvent', '{}'),
      isA<KickPinnedMessageDeletedEvent>(),
    );
    expect(
      parseKickEvent('FutureEvent', '{"new_field":{"value":3}}'),
      isA<KickUnknownEvent>().having(
        (event) => event.raw['new_field'],
        'raw payload',
        {'value': 3},
      ),
    );
  });

  test('models renewal celebrations embedded in chat messages', () {
    final json = _messageJson('renewal')
      ..['type'] = 'celebration'
      ..['metadata'] = {
        'celebration': {
          'type': 'subscription_renewed',
          'total_months': 12,
          'future': true,
        },
      };
    final event = parseKickEvent(
      r'App\Events\ChatMessageEvent',
      json,
    ) as KickChatMessageEvent;

    expect(event.message.metadata.celebration?.type, 'subscription_renewed');
    expect(event.message.metadata.celebration?.totalMonths, 12);
    expect(event.message.metadata.celebration?.raw['future'], isTrue);
  });

  group('models public evolving events', () {
    test('models the captured KICK gift payload and derives its image', () {
      final event = parseKickEvent('KicksGifted', {
        'message': '',
        'sender': {
          'id': 27183991,
          'username': 'RubyRiotYT',
          'username_color': '#FF9D00',
        },
        'gift': {
          'gift_id': 'hell_yeah',
          'name': 'Hell Yeah',
          'amount': 1,
          'type': 'kicks',
          'tier': 'tier_1',
          'pinned_time': 0,
        },
        'created_at': '2026-07-14T22:00:00Z',
      });

      expect(
        event,
        isA<KickKicksGiftedEvent>()
            .having((value) => value.sender.username, 'sender', 'RubyRiotYT')
            .having((value) => value.gift.amount, 'amount', 1)
            .having((value) => value.gift.name, 'name', 'Hell Yeah')
            .having(
              (value) => value.gift.imageUrl,
              'derived image',
              'https://files.kick.com/kicks/gifts/hell-yeah.webp',
            )
            .having(
              (value) => value.createdAt,
              'created at',
              DateTime.utc(2026, 7, 14, 22),
            ),
      );
    });

    test('prefers explicit KICK gift images and rejects unsafe derived IDs',
        () {
      final explicit = parseKickEvent('KicksGifted', {
        'gift': {
          'gift_id': 'gift',
          'image_url': 'https://cdn.example/gift.webp',
        },
      }) as KickKicksGiftedEvent;
      final unsafe = parseKickEvent('KicksGifted', {
        'gift': {'gift_id': '../gift'},
      }) as KickKicksGiftedEvent;

      expect(explicit.gift.imageUrl, 'https://cdn.example/gift.webp');
      expect(unsafe.gift.imageUrl, isEmpty);
    });

    test('models rewards without discarding future fields', () {
      final event = parseKickEvent('RewardRedeemedEvent', {
        'redemption_id': 'redemption-1',
        'reward': {
          'id': 'reward-1',
          'title': 'Hydrate',
          'description': 'Drink water',
          'cost': 750,
          'future_reward_field': true,
        },
        'redeemer': {
          'user_id': 7,
          'username': 'viewer',
          'channel_slug': 'viewer-channel',
        },
        'user_input': 'cold water',
        'status': 'fulfilled',
        'redeemed_at': '2026-09-06T12:00:00Z',
        'future_event_field': 4,
      });

      expect(
        event,
        isA<KickRewardRedeemedEvent>()
            .having((value) => value.redemptionId, 'redemption', 'redemption-1')
            .having((value) => value.reward.title, 'title', 'Hydrate')
            .having((value) => value.reward.cost, 'cost', 750)
            .having((value) => value.redeemer.id, 'redeemer id', 7)
            .having((value) => value.userInput, 'input', 'cold water')
            .having((value) => value.raw['future_event_field'], 'raw', 4),
      );
      expect(
        (event as KickRewardRedeemedEvent).reward.raw['future_reward_field'],
        isTrue,
      );
    });

    test('models polls with options, tallies and lifecycle', () {
      final updated = parseKickEvent(r'App\Events\PollUpdateEvent', {
        'poll': {
          'id': 'poll-1',
          'question': 'Choose one',
          'options': [
            {'id': 'a', 'text': 'A', 'vote_count': 3},
            {'id': 'b', 'text': 'B', 'vote_count': 5},
          ],
        },
        'status': 'active',
        'duration_seconds': 60,
      });
      final deleted = parseKickEvent(
        r'App\Events\PollDeleteEvent',
        {'poll_id': 'poll-1'},
      );

      expect(
        updated,
        isA<KickPollUpdatedEvent>()
            .having((value) => value.pollId, 'id', 'poll-1')
            .having((value) => value.title, 'title', 'Choose one')
            .having((value) => value.options.length, 'options', 2)
            .having((value) => value.options.last.votes, 'votes', 5),
      );
      expect(
        deleted,
        isA<KickPollDeletedEvent>()
            .having((value) => value.pollId, 'id', 'poll-1'),
      );
    });

    test('models every goal transition with progress', () {
      const cases = {
        'GoalCreatedEvent': KickGoalAction.created,
        'GoalUpdatedEvent': KickGoalAction.updated,
        'GoalProgressUpdateEvent': KickGoalAction.progress,
        'GoalAchievedEvent': KickGoalAction.achieved,
        'GoalCanceledEvent': KickGoalAction.canceled,
      };

      for (final entry in cases.entries) {
        final event = parseKickEvent(entry.key, {
          'id': 'goal-1',
          'title': 'Subscriptions',
          'current': 12,
          'target': 20,
        });
        expect(
          event,
          isA<KickGoalEvent>()
              .having((value) => value.action, 'action', entry.value)
              .having((value) => value.current, 'current', 12)
              .having((value) => value.target, 'target', 20),
        );
      }
    });

    test('models hosts, livestream lifecycle and chat moves', () {
      final host = parseKickEvent(r'App\Events\StreamHostedEvent', {
        'host': {'id': 9, 'username': 'hoster'},
        'hosted_channel': {'slug': 'destination'},
        'viewer_count': 44,
      });
      final live = parseKickEvent(r'App\Events\StreamerIsLive', {
        'livestream_id': 123,
        'session_title': 'Now live',
        'viewer_count': 9,
      });
      final moved = parseKickEvent(
        r'App\Events\ChatMoveToSupportedChannelEvent',
        {'supported_channel_id': 55, 'channel_slug': 'new-place'},
      );

      expect(
        host,
        isA<KickStreamHostedEvent>()
            .having((value) => value.host.username, 'host', 'hoster')
            .having(
              (value) => value.hostedChannel,
              'destination',
              'destination',
            )
            .having((value) => value.viewerCount, 'viewers', 44),
      );
      expect(
        live,
        isA<KickLivestreamEvent>()
            .having(
              (value) => value.action,
              'action',
              KickLivestreamAction.started,
            )
            .having((value) => value.title, 'title', 'Now live'),
      );
      expect(
        moved,
        isA<KickChatMovedEvent>()
            .having((value) => value.channelId, 'channel id', 55)
            .having((value) => value.channelSlug, 'slug', 'new-place'),
      );
    });

    test('keeps partial and malformed optional values safe', () {
      final poll = parseKickEvent(
        r'App\Events\PollUpdateEvent',
        {'options': 'not-a-list', 'duration': 'invalid', 'future': true},
      ) as KickPollUpdatedEvent;
      final goal = parseKickEvent(
        'GoalUpdatedEvent',
        {'current': '12', 'target': 'invalid'},
      ) as KickGoalEvent;

      expect(poll.options, isEmpty);
      expect(poll.durationSeconds, isNull);
      expect(poll.raw['future'], isTrue);
      expect(goal.current, 12);
      expect(goal.target, isNull);
    });
  });
}

Map<String, dynamic> _messageJson(String id) => {
      'id': id,
      'chatroom_id': 9,
      'content': 'hello',
      'type': 'message',
      'created_at': '2026-09-06T12:00:00Z',
      'sender': {
        'id': 1,
        'username': 'viewer',
        'slug': 'viewer',
        'identity': {'color': '#fff', 'badges': [], 'badges_v2': []},
      },
    };
