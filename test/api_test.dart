import 'dart:async';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  test('fetches complete channel metadata through an injectable transport',
      () async {
    late Uri requested;
    final api = KickApiClient(httpGet: (uri, _) async {
      requested = uri;
      return const KickHttpResponse(statusCode: 200, body: _channelJson);
    });

    final channel = await api.fetchChannel('@Creator');

    expect(requested.path, '/api/v2/channels/creator');
    expect(channel.id, 10);
    expect(channel.chatroom.id, 20);
    expect(channel.livestream?.viewerCount, 321);
    expect(channel.livestream?.category?.name, 'Games');
    expect(channel.user.profilePictureUrl, 'https://cdn/avatar.webp');
    expect(channel.raw['future_field'], 'preserved');
  });

  test('fetches initial history, metadata, modern badges and pinned message',
      () async {
    final api = KickApiClient(httpGet: (uri, _) async {
      expect(uri.host, 'web.kick.com');
      expect(uri.path, '/api/v1/chat/10/history');
      return const KickHttpResponse(statusCode: 200, body: _historyJson);
    });

    final history = await api.fetchChatHistory(10);

    expect(history.messages, hasLength(1));
    expect(history.messages.single.chatroomId, 10);
    expect(history.messages.single.sender.identity.badgesV2.single.imageUrl,
        'https://cdn/level.png');
    expect(history.messages.single.sender.identity.isModerator, isTrue);
    expect(history.pinnedMessage?.message.id, 'pinned');
    expect(history.cursor, 'next');
  });

  test('reports HTTP, malformed payload and timeout failures', () async {
    final rejected = KickApiClient(
      httpGet: (_, __) async => const KickHttpResponse(
        statusCode: 503,
        body: 'unavailable',
      ),
    );
    await expectLater(
      rejected.fetchChannel('creator'),
      throwsA(isA<KickApiException>()),
    );

    final malformed = KickApiClient(
      httpGet: (_, __) async =>
          const KickHttpResponse(statusCode: 200, body: '[]'),
    );
    await expectLater(
      malformed.fetchChannel('creator'),
      throwsA(isA<KickProtocolException>()),
    );

    final timeout = KickApiClient(
      requestTimeout: const Duration(milliseconds: 5),
      httpGet: (_, __) => Completer<KickHttpResponse>().future,
    );
    await expectLater(
        timeout.fetchChannel('creator'), throwsA(isA<TimeoutException>()));
  });

  test('falls back from the HTTP/2 transport without duplicating injection',
      () async {
    var fallbackCalls = 0;
    final api = KickApiClient(
      http2Get: (_, __) async =>
          const KickHttpResponse(statusCode: 403, body: ''),
      httpGet: (_, __) async {
        fallbackCalls++;
        return const KickHttpResponse(statusCode: 200, body: _channelJson);
      },
    );

    expect((await api.fetchChannel('creator')).id, 10);
    expect(fallbackCalls, 1);
  });
}

const _channelJson = '''
{
  "id": 10,
  "user_id": 11,
  "slug": "creator",
  "followers_count": "42",
  "verified": true,
  "future_field": "preserved",
  "user": {"id": 11, "username": "Creator", "profile_pic": "https://cdn/avatar.webp"},
  "chatroom": {"id": 20, "channel_id": 10, "chat_mode": "public", "slow_mode": false},
  "livestream": {
    "id": 30,
    "session_title": "Live",
    "is_live": true,
    "viewer_count": 321,
    "start_time": "2026-09-06 12:00:00",
    "language": "English",
    "is_mature": false,
    "thumbnail": {"url": "https://cdn/thumb.jpg"},
    "categories": [{"id": 4, "name": "Games", "slug": "games"}]
  }
}
''';

const _historyJson = '''
{
  "data": {
    "messages": [{
      "id": "one", "chat_id": 10, "content": "hello", "type": "message",
      "metadata": "{\\"message_ref\\":\\"ref\\"}",
      "created_at": "2026-09-06T12:00:00Z",
      "sender": {"id": 1, "username": "mod", "slug": "mod", "identity": {
        "color": "#fff",
        "badges": [{"type": "moderator", "text": "Moderator"}],
        "badges_v2": [{"name": "level", "badge_type": "global", "image_url": "https://cdn/level.png", "selected": false, "metadata": {"level": 8}, "sort_order": 1}]
      }}
    }],
    "cursor": "next",
    "pinned_message": {"message": {
      "id": "pinned", "chat_id": 10, "content": "notice", "type": "message",
      "metadata": "null", "created_at": "2026-09-06T12:00:00Z",
      "sender": {"id": 2, "username": "owner", "slug": "owner"}
    }, "pinned_by": {"id": 2, "username": "owner", "slug": "owner"}}
  }
}
''';
