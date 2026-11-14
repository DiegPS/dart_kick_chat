import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'enrichment.dart';
import 'events.dart';
import 'realtime.dart';
import 'types.dart';

/// Centrifugo error code for a channel that is already subscribed.
const _alreadySubscribed = 105;

/// Fraction of the token lifetime after which the token is refreshed.
const _tokenRefreshRatio = 0.8;

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
/// Connects to Kick's public realtime (Centrifugo) WebSocket without OAuth:
/// it asks Kick's realtime API where to connect, obtains a guest token, then
/// speaks the Centrifuge JSON protocol. A disconnected client reconnects
/// automatically with a fresh token and re-subscribes to joined chatrooms.
class KickClient {
  KickClient._({
    required KickChannelResolver channelResolver,
    required KickRealtimeApi realtimeApi,
    required KickSocketConnector socketConnector,
    required Duration reconnectDelay,
    required Duration maximumReconnectDelay,
    required Duration connectionTimeout,
    required Duration subscriptionRefreshInterval,
    required Duration minimumStaleInterval,
    required double Function() randomDouble,
    required KickLogSink? logger,
    required KickExternalEmoteLoader? emoteLoader,
    required KickProfileResolver? profileResolver,
  })  : _channelResolver = channelResolver,
        _realtimeApi = realtimeApi,
        _socketConnector = socketConnector,
        _reconnectDelay = reconnectDelay,
        _maximumReconnectDelay = maximumReconnectDelay,
        _connectionTimeout = connectionTimeout,
        _subscriptionRefreshInterval = subscriptionRefreshInterval,
        _minimumStaleInterval = minimumStaleInterval,
        _randomDouble = randomDouble,
        _logger = logger,
        _emoteLoader = emoteLoader,
        _profileResolver = profileResolver;

  final KickChannelResolver _channelResolver;
  final KickRealtimeApi _realtimeApi;
  final KickSocketConnector _socketConnector;
  final Duration _reconnectDelay;
  final Duration _maximumReconnectDelay;
  final Duration _connectionTimeout;
  final Duration _subscriptionRefreshInterval;
  final Duration _minimumStaleInterval;
  final double Function() _randomDouble;
  final KickLogSink? _logger;
  final KickExternalEmoteLoader? _emoteLoader;
  final KickProfileResolver? _profileResolver;
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
  final StreamController<KickProfileUpdate> _profileController =
      StreamController<KickProfileUpdate>.broadcast();
  final StreamController<Exception> _enrichmentErrorController =
      StreamController<Exception>.broadcast();
  final Map<int, int> _joinedTargets = <int, int>{};
  final Map<int, String> _joinedSlugs = <int, String>{};
  final Set<String> _seenMessageIds = <String>{};
  final List<String> _seenMessageOrder = <String>[];
  final Set<String> _seenEventKeys = <String>{};
  final List<String> _seenEventOrder = <String>[];

  final String _clientId = _newClientId();

  KickSocket? _socket;
  Future<void>? _readTask;
  Timer? _watchdogTimer;
  Timer? _subscriptionRefreshTimer;
  Timer? _tokenRefreshTimer;
  bool _handshakeDone = false;
  int _nextCommandId = 0;
  int _connectCommandId = 0;
  final Map<int, String> _pendingSubscriptions = <int, String>{};
  final Map<int, Completer<Map<String, dynamic>>> _pendingReplies =
      <int, Completer<Map<String, dynamic>>>{};
  DateTime _lastActivity = DateTime.now().toUtc();
  Duration _activityTimeout = const Duration(seconds: 60);
  int _reconnectAttempts = 0;
  bool _closed = false;
  KickConnectionState _connectionState = KickConnectionState.disconnected;
  Map<String, ParsedEmote> _externalEmotes = const {};

  /// Opens Kick's realtime WebSocket and starts reading frames.
  ///
  /// [realtimeApi] tells the client where to connect and provides guest
  /// tokens; inject one to point at other endpoints or to test.
  static Future<KickClient> connect({
    KickChannelResolver? channelResolver,
    KickRealtimeApi? realtimeApi,
    KickSocketConnector? socketConnector,
    Duration reconnectDelay = const Duration(seconds: 5),
    Duration maximumReconnectDelay = const Duration(seconds: 30),
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration subscriptionRefreshInterval = const Duration(minutes: 30),
    Duration minimumStaleInterval = const Duration(minutes: 3),
    double Function()? randomDouble,
    KickLogSink? logger,
    KickHttpGet? enrichmentHttpGet,
    bool loadExternalEmotes = true,
    bool enrichProfiles = true,
    int maximumConcurrentProfileRequests = 3,
  }) async {
    final client = KickClient._(
      channelResolver: channelResolver ?? KickChannelResolver(),
      realtimeApi: realtimeApi ?? KickRealtimeApi(),
      socketConnector:
          socketConnector ?? (uri) => _WebSocketChannelAdapter(uri),
      reconnectDelay: reconnectDelay,
      maximumReconnectDelay: maximumReconnectDelay,
      connectionTimeout: connectionTimeout,
      subscriptionRefreshInterval: subscriptionRefreshInterval,
      minimumStaleInterval: minimumStaleInterval,
      randomDouble: randomDouble ?? Random().nextDouble,
      logger: logger,
      emoteLoader: loadExternalEmotes
          ? KickExternalEmoteLoader(httpGet: enrichmentHttpGet)
          : null,
      profileResolver: enrichProfiles
          ? KickProfileResolver(
              httpGet: enrichmentHttpGet,
              maximumConcurrentRequests: maximumConcurrentProfileRequests,
            )
          : null,
    );
    await client._dial();
    client._readTask = client._readLoop();
    return client;
  }

  /// Delivered chat messages. Duplicate non-empty message IDs are suppressed.
  Stream<ChatMessage> get messages => _msgController.stream;

  /// Non-fatal connection and protocol errors.
  Stream<Exception> get errors => _errController.stream;

  /// Optional enrichment failures; these never change connection state.
  Stream<Exception> get enrichmentErrors => _enrichmentErrorController.stream;

  /// Every recognized or future public realtime event, with its raw fields.
  Stream<KickEvent> get events => _eventController.stream;

  Stream<KickConnectionUpdate> get connections => _connectionController.stream;
  Stream<KickProfileUpdate> get profileUpdates => _profileController.stream;
  KickConnectionState get connectionState => _connectionState;

  /// Public realtime topics explicitly confirmed by the server.
  Stream<String> get subscriptions => _subscriptionController.stream;

  /// Joins a Kick channel by its public slug.
  Future<void> joinBySlug(String slug) async {
    _ensureOpen();
    final target = await _channelResolver.resolveTarget(slug);
    _joinedSlugs[target.chatroomId] = target.slug;
    _subscribeToResolvedChannel(target.chatroomId, target.channelId);
    if (_emoteLoader != null && target.userId > 0) {
      unawaited(_loadExternalEmotes(target.userId));
    }
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
    _stopSessionTimers();
    _failPendingReplies();
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
    if (!_profileController.isClosed) await _profileController.close();
    if (!_enrichmentErrorController.isClosed) {
      await _enrichmentErrorController.close();
    }
  }

  Future<void> _dial() async {
    _emitConnection(_reconnectAttempts == 0
        ? KickConnectionState.connecting
        : KickConnectionState.reconnecting);
    final url = await _realtimeApi.connectionUrl(_clientId);
    final token = await _realtimeApi.connectionToken(_clientId);
    final socket = _socketConnector(url);
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
    _handshakeDone = false;
    _nextCommandId = 0;
    _pendingSubscriptions.clear();
    _noteActivity();
    _connectCommandId = _send(
      (id) => {
        'id': id,
        'connect': {'token': token, 'name': 'js'},
      },
    );
    _log('WebSocket connected');
  }

  /// Sends a command built with a fresh ID and returns that ID.
  int _send(Map<String, Object?> Function(int id) build) {
    final id = ++_nextCommandId;
    _socket?.add(jsonEncode(build(id)));
    return id;
  }

  void _subscribeToResolvedChannel(int chatroomId, int channelId) {
    final previous = _joinedTargets[chatroomId];
    if (previous == channelId) return;
    _joinedTargets[chatroomId] = channelId;
    _sendSubscription(chatroomId, channelId);
  }

  void _sendSubscription(int chatroomId, [int channelId = 0]) {
    // Commands are only valid after the handshake; joined topics are sent
    // once it completes.
    if (!_handshakeDone) return;
    for (final channel in <String>[
      'chatrooms.$chatroomId.v2',
      'chatroom_$chatroomId',
      'chatrooms.$chatroomId',
      if (channelId > 0) 'channel_$channelId',
    ]) {
      final id = _send(
        (id) => {
          'id': id,
          'subscribe': {'channel': channel},
        },
      );
      _pendingSubscriptions[id] = channel;
    }
  }

  void _subscribeAllJoined() {
    for (final target in _joinedTargets.entries) {
      _sendSubscription(target.key, target.value);
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
        _handshakeDone = false;
        _stopSessionTimers();
        _failPendingReplies();
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
    } on Exception catch (error) {
      if (!_closed) _addError(error);
    } catch (error) {
      if (!_closed) _addError(Exception(error.toString()));
    }
  }

  /// Handles one WebSocket message, which may carry several
  /// newline-separated Centrifuge frames.
  void _handleFrame(String raw) {
    _noteActivity();
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      _handleCommandFrame(line);
    }
  }

  void _handleCommandFrame(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      _addError(const KickProtocolException('invalid frame JSON'));
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _addError(const KickProtocolException('frame is not a JSON object'));
      return;
    }

    // An empty frame is a server ping; answer with an empty frame.
    if (decoded.isEmpty) {
      _socket?.add('{}');
      return;
    }

    final id = (decoded['id'] as num?)?.toInt() ?? 0;
    if (id > 0) {
      _handleReply(id, decoded);
      return;
    }

    final push = decoded['push'];
    if (push is! Map) return;
    final disconnect = push['disconnect'];
    if (disconnect is Map) {
      final code = disconnect['code'];
      _addError(KickProtocolException(
        'realtime server disconnected the client'
        '${code == null ? '' : ' ($code)'}',
      ));
      unawaited(_socket?.close());
      return;
    }
    final publication = push['pub'];
    if (publication is! Map) return;
    final envelope = _decodeMap(publication['data']);
    final event = envelope['event'];
    if (event is! String || event.isEmpty) return;
    _handleEvent(event, envelope['data']);
  }

  void _handleReply(int id, Map<String, dynamic> reply) {
    final error = reply['error'];
    final code = error is Map ? (error['code'] as num?)?.toInt() : null;
    final suffix = code == null ? '' : ' ($code)';

    if (id == _connectCommandId) {
      if (error != null) {
        _addError(KickProtocolException('realtime connect rejected$suffix'));
        unawaited(_socket?.close());
        return;
      }
      _onConnected(_decodeMap(reply['connect']));
      return;
    }

    final channel = _pendingSubscriptions.remove(id);
    if (channel != null) {
      if (error == null || code == _alreadySubscribed) {
        if (!_subscriptionController.isClosed) {
          _subscriptionController.add(channel);
        }
      } else {
        _addError(
          KickProtocolException('subscription to $channel rejected$suffix'),
        );
      }
      return;
    }

    final pending = _pendingReplies.remove(id);
    if (pending != null && !pending.isCompleted) {
      if (error == null) {
        pending.complete(reply);
      } else {
        pending.completeError(
          KickProtocolException('realtime command rejected$suffix'),
        );
      }
    }
  }

  void _onConnected(Map<String, dynamic> connect) {
    _handshakeDone = true;
    final pingSeconds = (connect['ping'] as num?)?.toInt() ?? 25;
    _activityTimeout = Duration(seconds: max(1, pingSeconds));
    _reconnectAttempts = 0;
    _startWatchdog();
    _startSubscriptionRefresh();
    final ttl = (connect['ttl'] as num?)?.toInt() ?? 0;
    if (connect['expires'] == true && ttl > 0) {
      _scheduleTokenRefresh(Duration(seconds: ttl));
    }
    _subscribeAllJoined();
    _emitConnection(KickConnectionState.connected);
  }

  /// Refreshes the guest token before it expires. If refreshing fails the
  /// socket is closed so the client reconnects with a new token.
  void _scheduleTokenRefresh(Duration ttl) {
    _tokenRefreshTimer?.cancel();
    final delay = Duration(
      milliseconds: max(1, (ttl.inMilliseconds * _tokenRefreshRatio).round()),
    );
    final socket = _socket;
    _tokenRefreshTimer = Timer(delay, () async {
      if (_closed || socket == null || !identical(socket, _socket)) return;
      try {
        final token = await _realtimeApi.connectionToken(_clientId);
        if (_closed || !identical(socket, _socket)) return;
        final reply = await _request(
          (id) => {
            'id': id,
            'refresh': {'token': token},
          },
        );
        final refresh = _decodeMap(reply['refresh']);
        final next = (refresh['ttl'] as num?)?.toInt() ?? 0;
        if (refresh['expires'] == true && next > 0) {
          _scheduleTokenRefresh(Duration(seconds: next));
        }
        _log('realtime token refreshed');
      } on Exception catch (error) {
        if (_closed || !identical(socket, _socket)) return;
        _addError(error);
        unawaited(socket.close());
      }
    });
  }

  /// Sends a command and waits for its reply.
  Future<Map<String, dynamic>> _request(
    Map<String, Object?> Function(int id) build,
  ) {
    final completer = Completer<Map<String, dynamic>>();
    final id = _send(build);
    _pendingReplies[id] = completer;
    return completer.future.timeout(_connectionTimeout, onTimeout: () {
      _pendingReplies.remove(id);
      throw const KickProtocolException('realtime command timed out');
    });
  }

  void _failPendingReplies() {
    for (final pending in _pendingReplies.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const KickProtocolException('realtime connection closed'),
        );
      }
    }
    _pendingReplies.clear();
    _pendingSubscriptions.clear();
  }

  void _stopSessionTimers() {
    _watchdogTimer?.cancel();
    _subscriptionRefreshTimer?.cancel();
    _tokenRefreshTimer?.cancel();
  }

  void _handleEvent(String event, Object? data) {
    final KickEvent parsed;
    try {
      parsed = parseKickEvent(
        event,
        data,
        externalEmotes: _externalEmotes,
      );
    } on KickProtocolException catch (error) {
      _addError(error);
      return;
    }
    if (!_rememberEvent(parsed)) return;
    if (!_eventController.isClosed) _eventController.add(parsed);
    if (parsed is KickChatMessageEvent) {
      var message = parsed.message;
      if (!_rememberMessage(message.id)) return;
      final channelSlug = _joinedSlugs[message.chatroomId] ?? '';
      final cachedAvatar = _profileResolver?.peek(
        channelSlug,
        message.sender.slug,
      );
      if (message.sender.profilePictureUrl.isEmpty &&
          cachedAvatar?.isNotEmpty == true) {
        message = message.copyWith(
          sender: message.sender.copyWith(profilePictureUrl: cachedAvatar),
        );
      }
      if (!_msgController.isClosed) _msgController.add(message);
      if (message.sender.profilePictureUrl.isEmpty &&
          channelSlug.isNotEmpty &&
          message.sender.slug.isNotEmpty) {
        unawaited(_resolveProfile(channelSlug, message.sender));
      }
    }
  }

  Future<void> _loadExternalEmotes(int userId) async {
    try {
      final loaded = await _emoteLoader!.loadSevenTv(userId);
      if (!_closed) _externalEmotes = loaded;
    } on Exception catch (error) {
      _addEnrichmentError(error);
    }
  }

  Future<void> _resolveProfile(String channelSlug, Sender sender) async {
    try {
      final avatar = await _profileResolver!.resolve(channelSlug, sender.slug);
      if (!_closed && avatar.isNotEmpty && !_profileController.isClosed) {
        _profileController.add(
          KickProfileUpdate(
            username: sender.username,
            slug: sender.slug,
            avatarUrl: avatar,
          ),
        );
      }
    } on Exception catch (error) {
      _addEnrichmentError(error);
    }
  }

  void _addEnrichmentError(Exception error) {
    _log(error.toString());
    if (!_closed && !_enrichmentErrorController.isClosed) {
      _enrichmentErrorController.add(error);
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
            const KickProtocolException('realtime connection became stale'));
        unawaited(_socket?.close());
      },
    );
  }

  void _startSubscriptionRefresh() {
    _subscriptionRefreshTimer?.cancel();
    if (_subscriptionRefreshInterval <= Duration.zero) return;
    // Re-subscribing is harmless (the server answers "already subscribed")
    // and recovers a subscription the server dropped silently.
    _subscriptionRefreshTimer =
        Timer.periodic(_subscriptionRefreshInterval, (_) {
      _subscribeAllJoined();
    });
  }

  void _emitConnection(KickConnectionState state, [Exception? error]) {
    _connectionState = state;
    if (!_connectionController.isClosed) {
      _connectionController.add(KickConnectionUpdate(state, error: error));
    }
  }

  /// Decodes a JSON object that may arrive as a map or as a JSON string.
  static Map<String, dynamic> _decodeMap(Object? value) {
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

  static String _newClientId() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _log(String message) => _logger?.call(message);
}
