import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_kick_chat/dart_kick_chat.dart';

const _socketUrl = 'wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679'
    '?protocol=7&client=js&version=8.4.0-rc2&flash=false';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr
        .writeln('Usage: dart run tool/inspect_live.dart <channel> [seconds]');
    exitCode = 64;
    return;
  }
  final slug = arguments.first.trim().replaceFirst(RegExp(r'^@'), '');
  final seconds = arguments.length > 1 ? int.tryParse(arguments[1]) ?? 30 : 30;
  final api = KickApiClient();
  final channel = await api.fetchChannel(slug);
  final history = await api.fetchChatHistory(channel.id);
  final channelId = channel.id;
  final chatroomId = channel.chatroom.id;
  stdout.writeln(
    'channelId=$channelId chatroomId=$chatroomId '
    'history=${history.messages.length} pinned=${history.pinnedMessage != null}',
  );

  final socket = await WebSocket.connect(_socketUrl);
  for (final topic in <String>[
    'chatrooms.$chatroomId.v2',
    'chatroom_$chatroomId',
    'chatrooms.$chatroomId',
    'channel_$channelId',
    'channel.$channelId',
  ]) {
    socket.add(jsonEncode({
      'event': 'pusher:subscribe',
      'data': {'channel': topic, 'auth': ''},
    }));
  }

  final seen = <String>{};
  final subscription = socket.listen((Object? frame) {
    if (frame is! String) return;
    final decoded = jsonDecode(frame);
    if (decoded is! Map<String, dynamic>) return;
    final event = decoded['event']?.toString() ?? '<missing>';
    if (event == 'pusher:ping') {
      socket.add(jsonEncode({'event': 'pusher:pong', 'data': {}}));
      return;
    }
    final data = _decodeData(decoded['data']);
    final signature = '$event ${_shape(data)}';
    if (seen.add(signature)) stdout.writeln(signature);
  });
  await Future<void>.delayed(Duration(seconds: seconds));
  await subscription.cancel();
  await socket.close();
}

Object? _decodeData(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } catch (_) {
    return '<non-json string>';
  }
}

String _shape(Object? value, [int depth = 0]) {
  if (value == null) return 'null';
  if (depth >= 4) return value.runtimeType.toString();
  if (value is Map) {
    final entries = value.entries
        .map((entry) => '${entry.key}:${_shape(entry.value, depth + 1)}')
        .join(',');
    return '{$entries}';
  }
  if (value is List) {
    return value.isEmpty ? '[]' : '[${_shape(value.first, depth + 1)}]';
  }
  return value.runtimeType.toString();
}
