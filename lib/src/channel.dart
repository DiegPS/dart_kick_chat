import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http2/transport.dart' as http2;

void _log(String msg) => print('[kick-channel] $msg');

const _kickBase = 'https://kick.com';

// Minimal headers matching what the Go library sends. Avoid sec-* and
// Accept-Encoding because those can make a non-browser TLS fingerprint look
// more suspicious to Cloudflare.
const _browserHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Referer': 'https://kick.com/',
  'Origin': 'https://kick.com',
};

// Extracts chatroom ID from __NEXT_DATA__ JSON embedded in the channel page HTML.
final _nextDataRe = RegExp(
  r'<script id="__NEXT_DATA__" type="application/json">(.+?)</script>',
  dotAll: true,
);
final _chatroomIdRe = RegExp(r'"chatroom"\s*:\s*\{\s*"id"\s*:\s*(\d+)');

/// Resolves a Kick channel [slug] to its numeric chatroom ID.
///
/// Strategy:
///  1. Try v2 API over explicit HTTP/2.
///  2. Try v2 API through package:http as a fallback.
///  3. Try v1 API.
///  4. Fall back to parsing the channel page HTML for the chatroom ID.
///
/// Throws if all methods fail.
Future<int> getChatroomId(String slug) async {
  try {
    final id = await _tryV2ApiHttp2(slug);
    if (id > 0) {
      _log('v2 HTTP/2 API resolved "$slug" -> $id');
      return id;
    }
    _log('v2 HTTP/2 API returned id=0 for "$slug"');
  } catch (e) {
    _log('v2 HTTP/2 API failed for "$slug": $e');
  }

  try {
    final id = await _tryV2Api(slug);
    if (id > 0) {
      _log('v2 API resolved "$slug" -> $id');
      return id;
    }
    _log('v2 API returned id=0 for "$slug"');
  } catch (e) {
    _log('v2 API failed for "$slug": $e');
  }

  try {
    final id = await _tryV1Api(slug);
    if (id > 0) {
      _log('v1 API resolved "$slug" -> $id');
      return id;
    }
    _log('v1 API returned id=0 for "$slug"');
  } catch (e) {
    _log('v1 API failed for "$slug": $e');
  }

  try {
    final id = await _tryHtmlPage(slug);
    if (id > 0) {
      _log('HTML fallback resolved "$slug" -> $id');
      return id;
    }
  } catch (e) {
    _log('HTML fallback failed for "$slug": $e');
  }

  throw Exception(
    'Cloudflare blocked the channel lookup for "$slug" (HTTP 403).\n'
    'Try again later or check that the Kick slug is correct.',
  );
}

Future<int> _tryV2ApiHttp2(String slug) async {
  final body = await _http2Get(
    Uri.parse('$_kickBase/api/v2/channels/$slug'),
    _browserHeaders,
  );
  return _parseChatroomFromJson(body);
}

Future<int> _tryV2Api(String slug) async {
  final res = await http.get(
    Uri.parse('$_kickBase/api/v2/channels/$slug'),
    headers: _browserHeaders,
  );
  _log('v2 HTTP ${res.statusCode} for "$slug"');
  if (res.statusCode != 200) {
    _log(
      'v2 response body: '
      '${res.body.length > 300 ? res.body.substring(0, 300) : res.body}',
    );
    return 0;
  }
  return _parseChatroomFromJson(res.body);
}

Future<int> _tryV1Api(String slug) async {
  final res = await http.get(
    Uri.parse('$_kickBase/api/v1/channels/$slug'),
    headers: _browserHeaders,
  );
  _log('v1 HTTP ${res.statusCode} for "$slug"');
  if (res.statusCode != 200) {
    _log(
      'v1 response body: '
      '${res.body.length > 300 ? res.body.substring(0, 300) : res.body}',
    );
    return 0;
  }
  return _parseChatroomFromJson(res.body);
}

Future<int> _tryHtmlPage(String slug) async {
  final res = await http.get(
    Uri.parse('$_kickBase/$slug'),
    headers: {
      ..._browserHeaders,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    },
  );
  if (res.statusCode != 200) {
    throw Exception(
      'kick: HTML page for "$slug" returned HTTP ${res.statusCode}',
    );
  }

  final nextMatch = _nextDataRe.firstMatch(res.body);
  if (nextMatch != null) {
    try {
      final json = jsonDecode(nextMatch.group(1)!) as Map<String, dynamic>;
      final id = _extractChatroomIdFromNextData(json);
      if (id > 0) return id;
    } catch (_) {}
  }

  final directMatch = _chatroomIdRe.firstMatch(res.body);
  if (directMatch != null) {
    final id = int.tryParse(directMatch.group(1)!) ?? 0;
    if (id > 0) return id;
  }

  throw Exception('kick: chatroom ID not found in page HTML for "$slug"');
}

Future<String> _http2Get(Uri uri, Map<String, String> headers) async {
  if (uri.scheme != 'https') {
    throw ArgumentError('HTTP/2 lookup expects an https URI: $uri');
  }

  final port = uri.hasPort ? uri.port : 443;
  final socket = await SecureSocket.connect(
    uri.host,
    port,
    supportedProtocols: const ['h2'],
  );

  if (socket.selectedProtocol != 'h2') {
    await socket.close();
    throw Exception(
        'ALPN did not negotiate h2 (got ${socket.selectedProtocol})');
  }

  final transport = http2.ClientTransportConnection.viaSocket(socket);
  final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  final authority = uri.hasPort ? '${uri.host}:$port' : uri.host;
  final requestHeaders = <http2.Header>[
    http2.Header.ascii(':method', 'GET'),
    http2.Header.ascii(':scheme', uri.scheme),
    http2.Header.ascii(':authority', authority),
    http2.Header.ascii(':path', path),
    for (final entry in headers.entries)
      http2.Header.ascii(entry.key, entry.value),
  ];

  final stream = transport.makeRequest(requestHeaders, endStream: true);
  final body = <int>[];
  var statusCode = 0;

  try {
    await for (final message in stream.incomingMessages) {
      if (message is http2.HeadersStreamMessage) {
        for (final header in message.headers) {
          final name = utf8.decode(header.name);
          if (name == ':status') {
            statusCode = int.tryParse(utf8.decode(header.value)) ?? 0;
          }
        }
      } else if (message is http2.DataStreamMessage) {
        body.addAll(message.bytes);
      }
    }
  } finally {
    await transport.finish();
  }

  final text = utf8.decode(body, allowMalformed: true);
  _log('v2 HTTP/2 $statusCode for "${uri.pathSegments.last}"');
  if (statusCode != 200) {
    _log(
      'v2 HTTP/2 response body: '
      '${text.length > 300 ? text.substring(0, 300) : text}',
    );
    return '';
  }

  return text;
}

int _parseChatroomFromJson(String body) {
  if (body.isEmpty) return 0;

  final json = jsonDecode(body) as Map<String, dynamic>;
  var id = (json['chatroom_id'] as num?)?.toInt() ?? 0;
  if (id == 0) {
    final chatroom = json['chatroom'] as Map<String, dynamic>?;
    id = (chatroom?['id'] as num?)?.toInt() ?? 0;
  }

  final chatroom = json['chatroom'] as Map?;
  final nestedId =
      chatroom?.containsKey('id') == true ? chatroom!['id'] : 'absent';
  _log(
    'parsed chatroom id=$id '
    '(chatroom_id=${json['chatroom_id']}, chatroom.id=$nestedId)',
  );
  return id;
}

int _extractChatroomIdFromNextData(Map<String, dynamic> data) {
  try {
    final props = data['props'] as Map<String, dynamic>?;
    final pageProps = props?['pageProps'] as Map<String, dynamic>?;
    final channel = pageProps?['channel'] as Map<String, dynamic>?;
    final chatroom = channel?['chatroom'] as Map<String, dynamic>?;
    final id = (chatroom?['id'] as num?)?.toInt() ?? 0;
    if (id > 0) return id;
  } catch (e) {
    _log('__NEXT_DATA__ path 1 parse error: $e');
  }

  try {
    final channel = data['channel'] as Map<String, dynamic>?;
    final chatroom = channel?['chatroom'] as Map<String, dynamic>?;
    final id = (chatroom?['id'] as num?)?.toInt() ?? 0;
    if (id > 0) return id;
  } catch (e) {
    _log('__NEXT_DATA__ path 2 parse error: $e');
  }

  return 0;
}
