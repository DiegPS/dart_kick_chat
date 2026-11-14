import 'dart:async';
import 'dart:convert';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  test('asks the realtime API where to connect and sends the guest token',
      () async {
    final socket = FakeKickSocket();
    final api = FakeRealtime();
    Uri? dialed;
    final client = await KickClient.connect(
      socketConnector: (uri) {
        dialed = uri;
        return socket;
      },
      realtimeApi: api.client,
    );
    addTearDown(client.close);

    expect(dialed.toString(), FakeRealtime.socketUrl);
    final connect = socket.commands.single;
    expect((connect['connect'] as Map)['token'], 'token-1');
    expect(api.descriptorCalls, 1);
    expect(api.clientIds.toSet(), hasLength(1));
  });

  test('subscribes once and suppresses duplicate messages', () async {
    final socket = FakeKickSocket();
    final client = await _connect(socket, resolver: _resolverFor(42));
    final messages = <ChatMessage>[];
    client.messages.listen(messages.add);
    socket.handshake();

    await client.joinBySlug('creator');
    await client.joinBySlug('creator');
    expect(socket.subscribedChannels(), hasLength(3));

    socket.emit(_chatFrame(id: 'same', content: 'hello'));
    socket.emit(_chatFrame(id: 'same', content: 'hello'));
    await _flush();
    expect(messages, hasLength(1));
    expect(messages.single.content, 'hello');
  });

  test('joins made before the handshake are subscribed once it completes',
      () async {
    final socket = FakeKickSocket();
    final client = await _connect(socket, resolver: _resolverFor(42));
    final states = <KickConnectionState>[];
    client.connections.listen((update) => states.add(update.state));

    await client.joinBySlug('creator');
    expect(socket.subscribedChannels(), isEmpty,
        reason: 'commands are invalid before the connect reply');

    socket.handshake();
    await _flush();
    expect(socket.subscribedChannels(), hasLength(3));
    expect(states, contains(KickConnectionState.connected));
  });

  test('answers server pings and reports corrupt frames without leaking them',
      () async {
    final socket = FakeKickSocket();
    final logs = <String>[];
    final client = await _connect(socket, logger: logs.add);
    final errors = <Exception>[];
    client.errors.listen(errors.add);

    socket.emit('{}');
    socket.emit('SECRET CHAT CONTENT');
    await _flush();

    expect(socket.sent, contains('{}'));
    expect(errors.single, isA<KickProtocolException>());
    expect(logs.join(' '), isNot(contains('SECRET CHAT CONTENT')));
  });

  test('handles several newline-separated frames in one message', () async {
    final socket = FakeKickSocket();
    final client = await _connect(socket, resolver: _resolverFor(42));
    final messages = <ChatMessage>[];
    client.messages.listen(messages.add);
    socket.handshake();
    await client.joinBySlug('creator');

    socket.emit([
      _chatFrame(id: 'a', content: 'one'),
      _chatFrame(id: 'b', content: 'two'),
      '{}',
    ].join('\n'));
    await _flush();

    expect(messages.map((m) => m.id), ['a', 'b']);
    expect(socket.sent, contains('{}'));
  });

  test('exposes special events and subscribes to every public chat topic',
      () async {
    final socket = FakeKickSocket();
    final client = await _connect(socket, resolver: _resolverFor(42));
    socket.handshake();
    final event = client.events.first;

    await client.joinBySlug('creator');
    expect(socket.subscribedChannels(), {
      'chatrooms.42.v2',
      'chatroom_42',
      'chatrooms.42',
    });

    socket.emit(_push('chatroom_42', 'GiftedSubscriptionsEvent', {
      'gifter_username': 'gifter',
      'gifted_usernames': ['member'],
      'gifted_total': 1,
    }));
    expect(await event, isA<KickGiftedSubscriptionsEvent>());
  });

  test('subscribes to channel events when resolution exposes channel ID',
      () async {
    final socket = FakeKickSocket();
    final client = await _connect(
      socket,
      resolver: _targetResolver(chatroomId: 42, channelId: 91),
    );
    socket.handshake();

    await client.joinBySlug('creator');

    expect(socket.subscribedChannels(), contains('channel_91'));
  });

  test('reports confirmed subscriptions and rejections', () async {
    final socket = FakeKickSocket();
    final client = await _connect(
      socket,
      resolver: _targetResolver(chatroomId: 42, channelId: 91),
    );
    final confirmed = <String>[];
    final errors = <Exception>[];
    client.subscriptions.listen(confirmed.add);
    client.errors.listen(errors.add);
    socket.handshake();
    await client.joinBySlug('creator');

    final ids = socket.subscriptionIds();
    socket.emit(jsonEncode({'id': ids['chatrooms.42.v2'], 'subscribe': {}}));
    socket.emit(jsonEncode({
      'id': ids['chatroom_42'],
      'error': {'code': 105, 'message': 'already subscribed'},
    }));
    socket.emit(jsonEncode({
      'id': ids['channel_91'],
      'error': {'code': 103, 'message': 'permission denied'},
    }));
    await _flush();

    expect(confirmed, ['chatrooms.42.v2', 'chatroom_42']);
    expect(errors.single.toString(), contains('channel_91'));
    expect(errors.single.toString(), contains('103'));
  });

  test('deduplicates every event', () async {
    final socket = FakeKickSocket();
    final client = await _connect(socket);
    final events = <KickEvent>[];
    client.events.listen(events.add);

    final frame = _push('channel_91', 'GoalUpdatedEvent', {'id': 7});
    socket.emit(frame);
    socket.emit(frame);
    await _flush();

    expect(events, hasLength(1));
  });

  test('refreshes subscriptions periodically', () async {
    final socket = FakeKickSocket();
    final client = await _connect(
      socket,
      resolver: _resolverFor(42),
      subscriptionRefreshInterval: const Duration(milliseconds: 5),
    );
    socket.handshake();
    await client.joinBySlug('creator');
    final before = socket.subscribedChannelFrames().length;

    await _until(() => socket.subscribedChannelFrames().length > before);
  });

  test('refreshes the guest token before it expires', () async {
    final socket = FakeKickSocket();
    final api = FakeRealtime();
    final client = await _connect(socket, realtime: api);
    socket.handshake(ttlSeconds: 1); // refresh after ~0.8 s

    await _until(
      () => socket.commands.any((c) => c.containsKey('refresh')),
      timeout: const Duration(seconds: 3),
    );
    final refresh = socket.commands.firstWhere((c) => c.containsKey('refresh'));
    expect((refresh['refresh'] as Map)['token'], 'token-2');

    socket.emit(jsonEncode({
      'id': refresh['id'],
      'refresh': {'expires': true, 'ttl': 2700},
    }));
    await _flush();
    expect(client.connectionState, KickConnectionState.connected);
    expect(socket.isClosed, isFalse);
  });

  test('reconnects with a new token and re-subscribes joined channels',
      () async {
    final first = FakeKickSocket();
    final second = FakeKickSocket();
    final sockets = [first, second];
    var connection = 0;
    final api = FakeRealtime();
    final client = await KickClient.connect(
      socketConnector: (_) => sockets[connection++],
      channelResolver: _resolverFor(19),
      realtimeApi: api.client,
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    first.handshake();
    await client.joinBySlug('creator');

    await first.end();
    await _until(() => second.commands.isNotEmpty);
    expect((second.commands.first['connect'] as Map)['token'], 'token-2');

    second.handshake();
    await _flush();
    expect(connection, 2);
    expect(second.subscribedChannels(), hasLength(3));
  });

  test('a rejected handshake is reported and the client reconnects', () async {
    final first = FakeKickSocket();
    final second = FakeKickSocket();
    final sockets = [first, second];
    var connection = 0;
    final client = await KickClient.connect(
      socketConnector: (_) => sockets[connection++],
      realtimeApi: FakeRealtime().client,
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    final errors = <Exception>[];
    client.errors.listen(errors.add);

    first.emit(jsonEncode({
      'id': first.connectId,
      'error': {'code': 109, 'message': 'token expired'},
    }));
    await _until(() => connection == 2);

    expect(errors.first.toString(), contains('109'));
    expect(first.isClosed, isTrue);
  });

  test('a server disconnect push triggers a reconnect', () async {
    final first = FakeKickSocket();
    final second = FakeKickSocket();
    final sockets = [first, second];
    var connection = 0;
    final client = await KickClient.connect(
      socketConnector: (_) => sockets[connection++],
      realtimeApi: FakeRealtime().client,
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    first.handshake();

    first.emit(jsonEncode({
      'push': {
        'disconnect': {'code': 3001, 'reason': 'shutdown'},
      },
    }));
    await _until(() => connection == 2);
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
      realtimeApi: FakeRealtime().client,
      reconnectDelay: Duration.zero,
    );
    addTearDown(client.close);
    final errors = <Exception>[];
    client.errors.listen(errors.add);
    first.handshake();
    await client.joinBySlug('creator');

    await first.end();
    await _until(() => recovered.commands.isNotEmpty);
    recovered.handshake();
    await _flush();

    expect(errors, hasLength(1));
    expect(connection, 3);
    expect(recovered.subscribedChannels(), hasLength(3));
  });

  test('a realtime API failure fails the initial connection', () async {
    final api = FakeRealtime(descriptorStatus: 503);

    await expectLater(
      KickClient.connect(
        socketConnector: (_) => FakeKickSocket(),
        realtimeApi: api.client,
      ),
      throwsA(isA<KickRealtimeException>()),
    );
  });

  test('bounds initial connection time and closes failed socket', () async {
    final socket = FakeKickSocket(ready: Completer<void>().future);

    await expectLater(
      KickClient.connect(
        socketConnector: (_) => socket,
        realtimeApi: FakeRealtime().client,
        connectionTimeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(socket.isClosed, isTrue);
  });

  test('close is idempotent and prevents future joins', () async {
    final socket = FakeKickSocket();
    final client = await KickClient.connect(
      socketConnector: (_) => socket,
      realtimeApi: FakeRealtime().client,
    );

    await client.close();
    await client.close();

    expect(socket.closeCalls, 1);
    expect(() => client.joinChatroom(1), throwsStateError);
  });
}

Future<KickClient> _connect(
  FakeKickSocket socket, {
  KickChannelResolver? resolver,
  FakeRealtime? realtime,
  KickLogSink? logger,
  Duration subscriptionRefreshInterval = const Duration(minutes: 30),
}) async {
  final client = await KickClient.connect(
    socketConnector: (_) => socket,
    channelResolver: resolver,
    realtimeApi: (realtime ?? FakeRealtime()).client,
    logger: logger,
    reconnectDelay: Duration.zero,
    subscriptionRefreshInterval: subscriptionRefreshInterval,
  );
  addTearDown(client.close);
  return client;
}

KickChannelResolver _resolverFor(int id) => KickChannelResolver(
      http2Get: (_, __) async => KickHttpResponse(
        statusCode: 200,
        body: '{"chatroom_id":$id}',
      ),
      httpGet: (_, __) async =>
          const KickHttpResponse(statusCode: 500, body: ''),
    );

KickChannelResolver _targetResolver({
  required int chatroomId,
  required int channelId,
}) =>
    KickChannelResolver(
      http2Get: (_, __) async => KickHttpResponse(
        statusCode: 200,
        body: '{"id":$channelId,"slug":"creator",'
            '"chatroom":{"id":$chatroomId}}',
      ),
      httpGet: (_, __) async =>
          const KickHttpResponse(statusCode: 500, body: ''),
    );

/// A realtime publication as Kick sends it: the event data is a JSON string.
String _push(String channel, String event, Map<String, Object?> data) =>
    jsonEncode({
      'push': {
        'channel': channel,
        'pub': {
          'data': {'event': event, 'data': jsonEncode(data)},
        },
      },
    });

String _chatFrame({required String id, required String content}) =>
    _push('chatrooms.42.v2', r'App\Events\ChatMessageEvent', {
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
    });

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

/// Answers the two realtime API calls the client makes before dialing.
final class FakeRealtime {
  FakeRealtime({this.descriptorStatus = 200});

  static const socketUrl = 'wss://realtime.test/connection/websocket';

  final int descriptorStatus;
  int descriptorCalls = 0;
  int tokenCalls = 0;
  final List<String> clientIds = <String>[];

  KickRealtimeApi get client => KickRealtimeApi(httpPost: _post);

  Future<KickHttpResponse> _post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final payload = jsonDecode(body) as Map<String, dynamic>;
    if (uri.path.endsWith('/v1/realtime/connection')) {
      descriptorCalls++;
      clientIds.add((payload['client'] as Map)['id'] as String);
      if (descriptorStatus != 200) {
        return KickHttpResponse(statusCode: descriptorStatus, body: '');
      }
      return KickHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'data': {
            'connections': [
              {
                'provider': 'centrifugo',
                'credentials': {'url': socketUrl},
              },
            ],
          },
        }),
      );
    }
    if (uri.path.endsWith('/v1/realtime/auth/connection')) {
      tokenCalls++;
      clientIds.add(payload['client_id'] as String);
      return KickHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'data': {'token': 'token-$tokenCalls'},
        }),
      );
    }
    return const KickHttpResponse(statusCode: 404, body: '');
  }
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

  /// Every command the client sent (pongs excluded).
  List<Map<String, dynamic>> get commands => [
        for (final frame in sent)
          if (frame != '{}') jsonDecode(frame) as Map<String, dynamic>,
      ];

  int get connectId =>
      commands.firstWhere((c) => c.containsKey('connect'))['id'] as int;

  /// Replies to the connect command, completing the handshake.
  void handshake({int ttlSeconds = 2700}) => emit(jsonEncode({
        'id': connectId,
        'connect': {
          'client': 'c',
          'version': '6',
          'expires': true,
          'ttl': ttlSeconds,
          'ping': 25,
          'pong': true,
        },
      }));

  List<Map<String, dynamic>> subscribedChannelFrames() =>
      commands.where((c) => c.containsKey('subscribe')).toList();

  Set<String> subscribedChannels() => {
        for (final c in subscribedChannelFrames())
          (c['subscribe'] as Map)['channel'] as String,
      };

  Map<String, int> subscriptionIds() => {
        for (final c in subscribedChannelFrames())
          (c['subscribe'] as Map)['channel'] as String: c['id'] as int,
      };

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
