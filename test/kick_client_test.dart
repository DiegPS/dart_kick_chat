import 'dart:async';
import 'dart:convert';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  test('subscribes once and suppresses duplicate messages', () async {
    final socket = FakeKickSocket();
    final client = await KickClient.connect(
      socketConnector: (_) => socket,
      channelResolver: _resolverFor(42),
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    final messages = <ChatMessage>[];
    client.messages.listen(messages.add);

    await client.joinBySlug('creator');
    await client.joinBySlug('creator');
    expect(socket.sent.where(_isSubscription), hasLength(3));

    socket.emit(_chatFrame(id: 'same', content: 'hello'));
    socket.emit(_chatFrame(id: 'same', content: 'hello'));
    await _flush();
    expect(messages, hasLength(1));
  });

  test('responds to ping and reports corrupt frames without leaking payloads',
      () async {
    final socket = FakeKickSocket();
    final logs = <String>[];
    final client = await KickClient.connect(
      socketConnector: (_) => socket,
      channelResolver: _resolverFor(1),
      logger: logs.add,
    );
    addTearDown(client.close);
    final errors = <Exception>[];
    client.errors.listen(errors.add);

    socket.emit('{"event":"pusher:ping"}');
    socket.emit('SECRET CHAT CONTENT');
    await _flush();

    expect(socket.sent.any((value) => value.contains('pusher:pong')), isTrue);
    expect(errors.single, isA<KickProtocolException>());
    expect(logs.join(' '), isNot(contains('SECRET CHAT CONTENT')));
  });

  test('exposes special events and subscribes to every public chat topic',
      () async {
    final socket = FakeKickSocket();
    final client = await KickClient.connect(
      socketConnector: (_) => socket,
      channelResolver: _resolverFor(42),
    );
    addTearDown(client.close);
    final event = client.events.first;

    await client.joinBySlug('creator');
    final channels = socket.sent
        .where(_isSubscription)
        .map((frame) =>
            (jsonDecode(frame)['data'] as Map<String, dynamic>)['channel'])
        .toSet();
    expect(channels, {
      'chatrooms.42.v2',
      'chatroom_42',
      'chatrooms.42',
    });

    socket.emit(jsonEncode({
      'event': 'GiftedSubscriptionsEvent',
      'data': jsonEncode({
        'gifter_username': 'gifter',
        'gifted_usernames': ['member'],
        'gifted_total': 1,
      }),
    }));
    expect(await event, isA<KickGiftedSubscriptionsEvent>());
  });

  test('reconnects and re-subscribes joined channels', () async {
    final first = FakeKickSocket();
    final second = FakeKickSocket();
    final sockets = [first, second];
    var connection = 0;
    final client = await KickClient.connect(
      socketConnector: (_) => sockets[connection++],
      channelResolver: _resolverFor(19),
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    await client.joinBySlug('creator');

    await first.end();
    await _until(() => second.sent.any(_isSubscription));

    expect(connection, 2);
    expect(second.sent.where(_isSubscription), hasLength(3));
  });

  test('emits reconnect errors and retries until a connection succeeds',
      () async {
    final first = FakeKickSocket();
    final recovered = FakeKickSocket();
    var connection = 0;
    final client = await KickClient.connect(
      socketConnector: (_) {
        connection++;
        if (connection == 1) return first;
        if (connection == 2) {
          return FakeKickSocket(readyError: Exception('offline'));
        }
        return recovered;
      },
      channelResolver: _resolverFor(9),
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    final errors = <Exception>[];
    client.errors.listen(errors.add);
    await client.joinBySlug('creator');

    await first.end();
    await _until(() => recovered.sent.any(_isSubscription));

    expect(errors, hasLength(1));
    expect(connection, 3);
  });

  test('bounds initial connection time and closes failed socket', () async {
    final socket = FakeKickSocket(ready: Completer<void>().future);

    await expectLater(
      KickClient.connect(
        socketConnector: (_) => socket,
        connectionTimeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(socket.isClosed, isTrue);
  });

  test('close is idempotent and prevents future joins', () async {
    final socket = FakeKickSocket();
    final client = await KickClient.connect(socketConnector: (_) => socket);

    await client.close();
    await client.close();

    expect(socket.closeCalls, 1);
    expect(() => client.joinChatroom(1), throwsStateError);
  });
}

KickChannelResolver _resolverFor(int id) => KickChannelResolver(
      http2Get: (_, __) async => KickHttpResponse(
        statusCode: 200,
        body: '{"chatroom_id":$id}',
      ),
      httpGet: (_, __) async =>
          const KickHttpResponse(statusCode: 500, body: ''),
    );

bool _isSubscription(String value) => value.contains('pusher:subscribe');

String _chatFrame({required String id, required String content}) => jsonEncode({
      'event': r'App\Events\ChatMessageEvent',
      'data': jsonEncode({
        'id': id,
        'chatroom_id': 42,
        'content': content,
        'type': 'message',
        'created_at': '2026-01-01T00:00:00.000Z',
        'sender': {
          'id': 1,
          'username': 'viewer',
          'slug': 'viewer',
          'identity': {'color': '#fff', 'badges': <Object>[]},
        },
      }),
    });

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

final class FakeKickSocket implements KickSocket {
  FakeKickSocket({Future<void>? ready, Exception? readyError})
      : ready = ready ??
            (readyError == null
                ? Future<void>.value()
                : Future<void>.error(readyError));

  final StreamController<Object?> _controller =
      StreamController<Object?>.broadcast();
  final List<String> sent = <String>[];
  @override
  final Future<void> ready;
  bool isClosed = false;
  int closeCalls = 0;

  @override
  Stream<Object?> get stream => _controller.stream;

  @override
  void add(String data) => sent.add(data);

  void emit(Object? value) => _controller.add(value);

  Future<void> end() => _controller.close();

  @override
  Future<void> close() async {
    closeCalls++;
    if (isClosed) return;
    isClosed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}
