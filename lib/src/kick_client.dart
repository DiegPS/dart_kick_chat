import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

enum KickConnectionState { connecting, connected, reconnecting, disconnected }

final class KickConnectionUpdate {
  const KickConnectionUpdate(this.state, {this.error});
  final KickConnectionState state;
  final Exception? error;
}

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
    required Duration maximumReconnectDelay,
    required Duration connectionTimeout,
    required Duration subscriptionRefreshInterval,
    required Duration minimumStaleInterval,
    required double Function() randomDouble,
    required KickLogSink? logger,
  })  : _channelResolver = channelResolver,
        _socketConnector = socketConnector,
        _reconnectDelay = reconnectDelay,
        _maximumReconnectDelay = maximumReconnectDelay,
        _connectionTimeout = connectionTimeout,
        _subscriptionRefreshInterval = subscriptionRefreshInterval,
        _minimumStaleInterval = minimumStaleInterval,
        _randomDouble = randomDouble,
        _logger = logger;

  final KickChannelResolver _channelResolver;
  final KickSocketConnector _socketConnector;
  final Duration _reconnectDelay;
  final Duration _maximumReconnectDelay;
  final Duration _connectionTimeout;
  final Duration _subscriptionRefreshInterval;
  final Duration _minimumStaleInterval;
  final double Function() _randomDouble;
  final KickLogSink? _logger;
  final StreamController<ChatMessage> _msgController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<Exception> _errController =
      StreamController<Exception>.broadcast();
  final StreamController<KickEvent> _eventController =
      StreamController<KickEvent>.broadcast();
  final StreamController<KickConnectionUpdate> _connectionController =
      StreamController<KickConnectionUpdate>.broadcast();
  final StreamController<String> _subscriptionController =
      StreamController<String>.broadcast();
  final Map<int, int> _joinedTargets = <int, int>{};
  final Set<String> _seenMessageIds = <String>{};
  final List<String> _seenMessageOrder = <String>[];
  final Set<String> _seenEventKeys = <String>{};
  final List<String> _seenEventOrder = <String>[];

  KickSocket? _socket;
  Future<void>? _readTask;
  Timer? _watchdogTimer;
  Timer? _subscriptionRefreshTimer;
  DateTime _lastActivity = DateTime.now().toUtc();
  Duration _activityTimeout = const Duration(seconds: 60);
  int _reconnectAttempts = 0;
  bool _closed = false;
  KickConnectionState _connectionState = KickConnectionState.disconnected;

  /// Dials Kick's Pusher WebSocket and starts reading frames.
  static Future<KickClient> connect({
    KickChannelResolver? channelResolver,
    KickSocketConnector? socketConnector,
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration maximumReconnectDelay = const Duration(seconds: 30),
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration subscriptionRefreshInterval = const Duration(minutes: 30),
    Duration minimumStaleInterval = const Duration(minutes: 3),
    double Function()? randomDouble,
    KickLogSink? logger,
  }) async {
    final client = KickClient._(
      channelResolver: channelResolver ?? KickChannelResolver(),
      socketConnector:
          socketConnector ?? (uri) => _WebSocketChannelAdapter(uri),
      reconnectDelay: reconnectDelay,
      maximumReconnectDelay: maximumReconnectDelay,
      connectionTimeout: connectionTimeout,
      subscriptionRefreshInterval: subscriptionRefreshInterval,
      minimumStaleInterval: minimumStaleInterval,
      randomDouble: randomDouble ?? Random().nextDouble,
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

  Stream<KickConnectionUpdate> get connections => _connectionController.stream;
  KickConnectionState get connectionState => _connectionState;

  /// Public Pusher topics explicitly confirmed by the server.
  Stream<String> get subscriptions => _subscriptionController.stream;

  /// Joins a Kick channel by its public slug.
  Future<void> joinBySlug(String slug) async {
    _ensureOpen();
    final target = await _channelResolver.resolveTarget(slug);
    _subscribeToResolvedChannel(target.chatroomId, target.channelId);
  }

  /// Joins an already resolved numeric chatroom ID.
  void joinChatroom(int chatroomId) {
    _ensureOpen();
    if (chatroomId <= 0) {
      throw ArgumentError.value(chatroomId, 'chatroomId', 'must be positive');
    }
    _subscribeToResolvedChannel(chatroomId, 0);
  }

  /// Closes the socket and output streams. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _watchdogTimer?.cancel();
    _subscriptionRefreshTimer?.cancel();
    _emitConnection(KickConnectionState.disconnected);
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _readTask;
    if (!_msgController.isClosed) await _msgController.close();
    if (!_eventController.isClosed) await _eventController.close();
    if (!_connectionController.isClosed) await _connectionController.close();
    if (!_subscriptionController.isClosed) {
      await _subscriptionController.close();
    }
    if (!_errController.isClosed) await _errController.close();
  }

  Future<void> _dial() async {
    _emitConnection(_reconnectAttempts == 0
        ? KickConnectionState.connecting
        : KickConnectionState.reconnecting);
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
    _noteActivity();
    _log('WebSocket connected');
  }

  void _subscribeToResolvedChannel(int chatroomId, int channelId) {
    final previous = _joinedTargets[chatroomId];
    if (previous == channelId) return;
    _joinedTargets[chatroomId] = channelId;
    _sendSubscription(chatroomId, channelId);
  }

  void _sendSubscription(int chatroomId, [int channelId = 0]) {
    for (final channel in <String>[
      'chatrooms.$chatroomId.v2',
      'chatroom_$chatroomId',
      'chatrooms.$chatroomId',
      if (channelId > 0) 'channel_$channelId',
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
        _watchdogTimer?.cancel();
        _subscriptionRefreshTimer?.cancel();
        await _reconnect();
      }
    }
  }

  Future<void> _reconnect() async {
    _reconnectAttempts++;
    final exponential = _reconnectDelay.inMilliseconds *
        pow(2, min(_reconnectAttempts - 1, 10));
    final capped =
        min(exponential.round(), _maximumReconnectDelay.inMilliseconds);
    final jittered = (capped * (0.8 + _randomDouble() * 0.4)).round();
    if (jittered > 0) {
      await Future<void>.delayed(Duration(milliseconds: jittered));
    }
    if (_closed) return;
    try {
      await _dial();
      for (final target in _joinedTargets.entries) {
        _sendSubscription(target.key, target.value);
      }
    } on Exception catch (error) {
      if (!_closed) _addError(error);
    } catch (error) {
      if (!_closed) _addError(Exception(error.toString()));
    }
  }

  void _handleFrame(String raw) {
    _noteActivity();
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
    if (event == 'pusher:connection_established') {
      final data = _decodePusherData(decoded['data']);
      final seconds = (data['activity_timeout'] as num?)?.toInt() ?? 60;
      _activityTimeout = Duration(seconds: max(1, seconds));
      _reconnectAttempts = 0;
      _startWatchdog();
      _startSubscriptionRefresh();
      for (final target in _joinedTargets.entries) {
        _sendSubscription(target.key, target.value);
      }
      _emitConnection(KickConnectionState.connected);
      return;
    }
    if (event == 'pusher:ping') {
      _socket?.add(jsonEncode({'event': 'pusher:pong', 'data': {}}));
      return;
    }
    if (event == 'pusher:error') {
      final data = _decodePusherData(decoded['data']);
      _addError(KickProtocolException(
        'Pusher error${data['code'] == null ? '' : ' ${data['code']}'}',
      ));
      unawaited(_socket?.close());
      return;
    }
    if (event == 'pusher_internal:subscription_succeeded') {
      final channel = decoded['channel']?.toString() ?? '';
      if (channel.isNotEmpty && !_subscriptionController.isClosed) {
        _subscriptionController.add(channel);
      }
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
    if (!_rememberEvent(parsed)) return;
    if (!_eventController.isClosed) _eventController.add(parsed);
    if (parsed is KickChatMessageEvent) {
      final message = parsed.message;
      if (!_rememberMessage(message.id)) return;
      if (!_msgController.isClosed) _msgController.add(message);
    }
  }

  bool _rememberEvent(KickEvent event) {
    final identity = event.raw['id'] ??
        event.raw['message_id'] ??
        event.raw['correlation_id'] ??
        (event is KickGiftedSubscriptionsEvent
            ? event.chunk?.correlationId
            : null);
    final key = identity == null || identity.toString().isEmpty
        ? '${event.eventName}:${jsonEncode(event.raw)}'
        : '${event.eventName}:$identity';
    if (!_seenEventKeys.add(key)) return false;
    _seenEventOrder.add(key);
    const maximumRememberedEvents = 2000;
    if (_seenEventOrder.length > maximumRememberedEvents) {
      _seenEventKeys.remove(_seenEventOrder.removeAt(0));
    }
    return true;
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

  void _noteActivity() => _lastActivity = DateTime.now().toUtc();

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    final staleAfter = _activityTimeout * 3 > _minimumStaleInterval
        ? _activityTimeout * 3
        : _minimumStaleInterval;
    _watchdogTimer = Timer.periodic(
      Duration(milliseconds: max(100, staleAfter.inMilliseconds ~/ 3)),
      (_) {
        if (_closed ||
            DateTime.now().toUtc().difference(_lastActivity) <= staleAfter) {
          return;
        }
        _addError(
            const KickProtocolException('Pusher connection became stale'));
        unawaited(_socket?.close());
      },
    );
  }

  void _startSubscriptionRefresh() {
    _subscriptionRefreshTimer?.cancel();
    if (_subscriptionRefreshInterval <= Duration.zero) return;
    _subscriptionRefreshTimer =
        Timer.periodic(_subscriptionRefreshInterval, (_) {
      for (final target in _joinedTargets.entries) {
        _sendSubscription(target.key, target.value);
      }
    });
  }

  void _emitConnection(KickConnectionState state, [Exception? error]) {
    _connectionState = state;
    if (!_connectionController.isClosed) {
      _connectionController.add(KickConnectionUpdate(state, error: error));
    }
  }

  static Map<String, dynamic> _decodePusherData(Object? value) {
    Object? decoded = value;
    if (value is String) {
      try {
        decoded = jsonDecode(value);
      } catch (_) {
        return const {};
      }
    }
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : const <String, dynamic>{};
  }

  void _log(String message) => _logger?.call(message);
}
