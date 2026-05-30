import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'types.dart';

const _pusherUrl = 'wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679'
    '?protocol=7&client=js&version=8.4.0-rc2&flash=false';

const _reconnectDelay = Duration(seconds: 5);

void _log(String msg) => print('[kick-dart] $msg');

/// Anonymous Kick.com chat client.
///
/// Connects to Kick's Pusher WebSocket — no OAuth or authentication required.
/// Reconnects automatically on disconnect.
///
/// ```dart
/// final client = await KickClient.connect();
/// await client.joinBySlug('xqc');
///
/// client.messages.listen((msg) {
///   for (final part in msg.parts) {
///     if (part.isEmote) {
///       print('[${part.emote!.name}]');
///     } else {
///       print(part.text);
///     }
///   }
/// });
///
/// // when done:
/// await client.close();
/// ```
class KickClient {
  final StreamController<ChatMessage> _msgController =
      StreamController.broadcast();
  final StreamController<Exception> _errController =
      StreamController.broadcast();

  WebSocketChannel? _channel;
  final Set<int> _joinedIds = {};
  bool _closed = false;

  KickClient._();

  /// Dials the Pusher WebSocket and starts the read loop.
  /// Throws if the initial connection fails.
  static Future<KickClient> connect() async {
    final client = KickClient._();
    _log('connecting to Pusher...');
    await client._dial();
    _log('WebSocket connected');
    client._readLoop().ignore();
    return client;
  }

  /// Delivered chat messages. The stream is broadcast — multiple listeners
  /// are allowed. Closes when [close] is called.
  Stream<ChatMessage> get messages => _msgController.stream;

  /// Non-fatal errors (e.g. failed reconnect attempts). Does not close
  /// [messages] — the client keeps retrying.
  Stream<Exception> get errors => _errController.stream;

  /// Joins a Kick channel by its public slug.
  Future<void> joinBySlug(String slug) async {
    _log('resolving channel "$slug"...');
    final id = await getChatroomId(slug);
    _log('resolved "$slug"');
    _subscribeToResolvedChannel(id);
  }

  void _subscribeToResolvedChannel(int id) {
    if (_joinedIds.contains(id)) return;
    _subscribe(id);
    _joinedIds.add(id);
  }

  /// Closes the client and all streams.
  Future<void> close() async {
    _closed = true;
    await _channel?.sink.close();
    await _msgController.close();
    await _errController.close();
  }

  // ── internals ──────────────────────────────────────────────────────────────

  Future<void> _dial() async {
    _channel = WebSocketChannel.connect(Uri.parse(_pusherUrl));
    await _channel!.ready;
  }

  void _subscribe(int chatroomId) {
    _channel?.sink.add(jsonEncode({
      'event': 'pusher:subscribe',
      'data': {
        'channel': 'chatrooms.$chatroomId.v2',
        'auth': '',
      },
    }));
  }

  Future<void> _readLoop() async {
    while (!_closed) {
      try {
        await for (final dynamic raw in _channel!.stream) {
          if (raw is String) _handleFrame(raw);
        }
        _log('WebSocket stream ended (normal close)');
      } on Exception catch (e) {
        _log('WebSocket read error: $e');
        if (!_closed) _addError(e);
      } catch (e) {
        _log('WebSocket unexpected error: $e');
        if (!_closed) _addError(Exception(e.toString()));
      }

      if (_closed) break;
      _log('scheduling reconnect in 5s...');
      await _reconnect();
    }

    if (!_msgController.isClosed) await _msgController.close();
  }

  Future<void> _reconnect() async {
    await Future<void>.delayed(_reconnectDelay);
    if (_closed) return;

    final toRejoin = Set<int>.from(_joinedIds);
    _joinedIds.clear();

    try {
      _log('reconnecting...');
      await _dial();
      _log('reconnected, rejoining ${toRejoin.length} channel(s)');
      for (final id in toRejoin) {
        _subscribe(id);
        _joinedIds.add(id);
      }
    } on Exception catch (e) {
      _log('reconnect failed: $e');
      if (!_closed) _addError(e);
    }
  }

  void _handleFrame(String raw) {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      _log('frame JSON parse error: $e  raw=$raw');
      return;
    }

    final event = env['event'] as String? ?? '';
    _log('frame event="$event"');

    // Respond to Pusher keepalive pings.
    if (event == 'pusher:ping') {
      _log('sending pusher:pong');
      _channel?.sink.add(jsonEncode({'event': 'pusher:pong', 'data': {}}));
      return;
    }

    if (event != r'App\Events\ChatMessageEvent') return;

    final dataStr = env['data'] as String?;
    if (dataStr == null) {
      _log('ChatMessageEvent with null data field — skipping');
      return;
    }

    // Pusher double-encodes the data field as a JSON string.
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(dataStr) as Map<String, dynamic>;
    } catch (e) {
      _log('double-decode error: $e  dataStr=$dataStr');
      return;
    }

    _log(
        'parsing ChatMessage id=${data['id']} from=${data['sender']?['username']}');
    try {
      _msgController.add(ChatMessage.fromJson(data));
    } catch (e, st) {
      _log('ChatMessage.fromJson error: $e\n$st\njson=$data');
    }
  }

  void _addError(Exception e) {
    if (!_errController.isClosed) _errController.add(e);
  }
}
