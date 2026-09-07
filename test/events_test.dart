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
