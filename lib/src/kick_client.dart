import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'events.dart';
import 'types.dart';

const _pusherUrl = 'wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679'
    '?protocol=7&client=js&version=8.4.0-rc2&flash=false';

/// Receives diagnostic messages that never contain chat content or identities.
typedef KickLogSink = void Function(String message);

/// Minimal WebSocket surface used by [KickClient].
abstract interface class KickSocket {
  Future<void> get ready;
  Stream<Object?> get stream;
  void add(String data);
  Future<void> close();
}

/// Opens a [KickSocket] for [uri].
typedef KickSocketConnector = KickSocket Function(Uri uri);

final class _WebSocketChannelAdapter implements KickSocket {
  _WebSocketChannelAdapter(Uri uri) : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  void add(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async => _channel.sink.close();
}

/// Anonymous Kick.com chat client.
///
/// Connects to Kick's public Pusher WebSocket without OAuth. A disconnected
/// client reconnects automatically and re-subscribes to joined chatrooms.
class KickClient {
  KickClient._({
    required KickChannelResolver channelResolver,
    required KickSocketConnector socketConnector,
    required Duration reconnectDelay,
    required Duration connectionTimeout,
    required KickLogSink? logger,
  })  : _channelResolver = channelResolver,
        _socketConnector = socketConnector,
        _reconnectDelay = reconnectDelay,
        _connectionTimeout = connectionTimeout,
        _logger = logger;

  final KickChannelResolver _channelResolver;
  final KickSocketConnector _socketConnector;
  final Duration _reconnectDelay;
  final Duration _connectionTimeout;
  final KickLogSink? _logger;
  final StreamController<ChatMessage> _msgController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<Exception> _errController =
      StreamController<Exception>.broadcast();
  final StreamController<KickEvent> _eventController =
      StreamController<KickEvent>.broadcast();
  final Set<int> _joinedIds = <int>{};
  final Set<String> _seenMessageIds = <String>{};
  final List<String> _seenMessageOrder = <String>[];

  KickSocket? _socket;
  Future<void>? _readTask;
  bool _closed = false;

  /// Dials Kick's Pusher WebSocket and starts reading frames.
  static Future<KickClient> connect({
    KickChannelResolver? channelResolver,
    KickSocketConnector? socketConnector,
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration connectionTimeout = const Duration(seconds: 15),
    KickLogSink? logger,
  }) async {
    final client = KickClient._(
      channelResolver: channelResolver ?? KickChannelResolver(),
      socketConnector:
          socketConnector ?? (uri) => _WebSocketChannelAdapter(uri),
      reconnectDelay: reconnectDelay,
      connectionTimeout: connectionTimeout,
      logger: logger,
    );
    await client._dial();
    client._readTask = client._readLoop();
    return client;
  }

  /// Delivered chat messages. Duplicate non-empty message IDs are suppressed.
  Stream<ChatMessage> get messages => _msgController.stream;

  /// Non-fatal connection and protocol errors.
  Stream<Exception> get errors => _errController.stream;

  /// Every recognized or future public realtime event, with its raw fields.
  Stream<KickEvent> get events => _eventController.stream;

  /// Joins a Kick channel by its public slug.
  Future<void> joinBySlug(String slug) async {
    _ensureOpen();
    final id = await _channelResolver.resolve(slug);
    _subscribeToResolvedChannel(id);
  }

  /// Joins an already resolved numeric chatroom ID.
  void joinChatroom(int chatroomId) {
    _ensureOpen();
    if (chatroomId <= 0) {
      throw ArgumentError.value(chatroomId, 'chatroomId', 'must be positive');
    }
    _subscribeToResolvedChannel(chatroomId);
  }

  /// Closes the socket and output streams. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _readTask;
    if (!_msgController.isClosed) await _msgController.close();
    if (!_eventController.isClosed) await _eventController.close();
    if (!_errController.isClosed) await _errController.close();
  }

  Future<void> _dial() async {
    final socket = _socketConnector(Uri.parse(_pusherUrl));
    try {
      await socket.ready.timeout(_connectionTimeout);
    } catch (_) {
      await socket.close();
      rethrow;
    }
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;
    _log('WebSocket connected');
  }

  void _subscribeToResolvedChannel(int id) {
    if (!_joinedIds.add(id)) return;
    _sendSubscription(id);
  }

  void _sendSubscription(int chatroomId) {
    for (final channel in <String>[
      'chatrooms.$chatroomId.v2',
      'chatroom_$chatroomId',
      'chatrooms.$chatroomId',
    ]) {
      _socket?.add(
        jsonEncode({
          'event': 'pusher:subscribe',
          'data': {'channel': channel, 'auth': ''},
        }),
      );
    }
  }

  Future<void> _readLoop() async {
    while (!_closed) {
      final socket = _socket;
      if (socket == null) {
        await _reconnect();
        continue;
      }
      try {
        await for (final raw in socket.stream) {
          if (_closed) break;
          if (raw is String) _handleFrame(raw);
        }
      } on Exception catch (error) {
        if (!_closed) _addError(error);
      } catch (error) {
        if (!_closed) _addError(Exception(error.toString()));
      }
      if (!_closed) {
        _socket = null;
        await _reconnect();
      }
    }
  }

  Future<void> _reconnect() async {
    if (_reconnectDelay > Duration.zero) {
      await Future<void>.delayed(_reconnectDelay);
    }
    if (_closed) return;
    try {
      await _dial();
      for (final id in _joinedIds) {
        _sendSubscription(id);
      }
    } on Exception catch (error) {
      if (!_closed) _addError(error);
    } catch (error) {
      if (!_closed) _addError(Exception(error.toString()));
    }
  }

  void _handleFrame(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      _addError(const KickProtocolException('invalid frame JSON'));
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _addError(const KickProtocolException('frame is not a JSON object'));
      return;
    }

    final event = decoded['event'];
    if (event == 'pusher:ping') {
      _socket?.add(jsonEncode({'event': 'pusher:pong', 'data': {}}));
      return;
    }
    if (event is! String || event.startsWith('pusher')) return;

    final KickEvent parsed;
    try {
      parsed = parseKickEvent(event, decoded['data']);
    } on KickProtocolException catch (error) {
      _addError(error);
      return;
    }
    if (!_eventController.isClosed) _eventController.add(parsed);
    if (parsed is KickChatMessageEvent) {
      final message = parsed.message;
      if (!_rememberMessage(message.id)) return;
      if (!_msgController.isClosed) _msgController.add(message);
    }
  }

  bool _rememberMessage(String id) {
    if (id.isEmpty) return true;
    if (!_seenMessageIds.add(id)) return false;
    _seenMessageOrder.add(id);
    const maximumRememberedIds = 2000;
    if (_seenMessageOrder.length > maximumRememberedIds) {
      _seenMessageIds.remove(_seenMessageOrder.removeAt(0));
    }
    return true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('KickClient is closed');
  }

  void _addError(Exception error) {
    _log(error.toString());
    if (!_errController.isClosed) _errController.add(error);
  }

  void _log(String message) => _logger?.call(message);
}
