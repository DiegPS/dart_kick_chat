import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http2/transport.dart' as http2;

const _kickBase = 'https://kick.com';

const _browserHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Referer': 'https://kick.com/',
  'Origin': 'https://kick.com',
};

final _nextDataRe = RegExp(
  r'<script id="__NEXT_DATA__" type="application/json">(.+?)</script>',
  dotAll: true,
);
final _chatroomIdRe = RegExp(r'"chatroom"\s*:\s*\{\s*"id"\s*:\s*(\d+)');

/// Immutable response used by injectable Kick HTTP transports.
final class KickHttpResponse {
  const KickHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Performs an HTTP GET request.
typedef KickHttpGet = Future<KickHttpResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

/// Resolves public Kick channel slugs to numeric chatroom IDs.
class KickChannelResolver {
  KickChannelResolver({
    KickHttpGet? httpGet,
    KickHttpGet? http2Get,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _httpGet = httpGet ?? kickHttpGet,
        _http2Get = http2Get ?? kickHttp2Get;

  final KickHttpGet _httpGet;
  final KickHttpGet _http2Get;
  final Duration requestTimeout;

  Future<int> resolve(String slug) async {
    final normalizedSlug = normalizeKickSlug(slug);
    final attempts = <Future<int> Function()>[
      () => _tryJson(
            _http2Get,
            Uri.parse('$_kickBase/api/v2/channels/$normalizedSlug'),
          ),
      () => _tryJson(
            _httpGet,
            Uri.parse('$_kickBase/api/v2/channels/$normalizedSlug'),
          ),
      () => _tryJson(
            _httpGet,
            Uri.parse('$_kickBase/api/v1/channels/$normalizedSlug'),
          ),
      () => _tryHtml(normalizedSlug),
    ];

    for (final attempt in attempts) {
      try {
        final id = await attempt();
        if (id > 0) return id;
      } catch (_) {
        // Strategies are independent; exhaust every anonymous fallback.
      }
    }
    throw KickChannelLookupException(normalizedSlug);
  }

  Future<int> _tryJson(KickHttpGet get, Uri uri) async {
    final response = await get(uri, _browserHeaders).timeout(requestTimeout);
    if (response.statusCode != HttpStatus.ok) return 0;
    return parseKickChatroomId(response.body);
  }

  Future<int> _tryHtml(String slug) async {
    final response = await _httpGet(
      Uri.parse('$_kickBase/$slug'),
      {
        ..._browserHeaders,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    ).timeout(requestTimeout);
    if (response.statusCode != HttpStatus.ok) return 0;
    return parseKickChatroomIdFromHtml(response.body);
  }
}

/// Indicates that every anonymous channel-resolution strategy failed.
final class KickChannelLookupException implements Exception {
  const KickChannelLookupException(this.slug);

  final String slug;

  @override
  String toString() => 'Unable to resolve Kick channel "$slug"';
}

/// Resolves a Kick channel using the default anonymous transports.
Future<int> getChatroomId(String slug) => KickChannelResolver().resolve(slug);

/// Parses the chatroom ID exposed by Kick's v1 or v2 channel JSON.
int parseKickChatroomId(String body) {
  if (body.isEmpty) return 0;
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return 0;
  final directId = (decoded['chatroom_id'] as num?)?.toInt() ?? 0;
  if (directId > 0) return directId;
  final chatroom = decoded['chatroom'];
  if (chatroom is! Map<String, dynamic>) return 0;
  return (chatroom['id'] as num?)?.toInt() ?? 0;
}

/// Parses a chatroom ID from a public Kick channel HTML document.
int parseKickChatroomIdFromHtml(String body) {
  final nextMatch = _nextDataRe.firstMatch(body);
  if (nextMatch != null) {
    try {
      final decoded = jsonDecode(nextMatch.group(1)!);
      if (decoded is Map<String, dynamic>) {
        final id = _extractChatroomIdFromNextData(decoded);
        if (id > 0) return id;
      }
    } catch (_) {
      // Malformed __NEXT_DATA__ can occur during site rollouts; try the direct
      // HTML pattern before considering the response unusable.
    }
  }
  final directMatch = _chatroomIdRe.firstMatch(body);
  return directMatch == null ? 0 : int.tryParse(directMatch.group(1)!) ?? 0;
}

/// Normalizes a public Kick slug, handle, or channel URL.
String normalizeKickSlug(String value) {
  var slug = value.trim();
  final uri = Uri.tryParse(slug);
  if (uri != null && (uri.host == 'kick.com' || uri.host == 'www.kick.com')) {
    slug = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
  }
  if (slug.startsWith('@')) slug = slug.substring(1);
  slug = slug.trim().toLowerCase();
  if (slug.isEmpty || !RegExp(r'^[a-z0-9_-]+$').hasMatch(slug)) {
    throw ArgumentError.value(value, 'slug', 'invalid Kick channel slug');
  }
  return slug;
}

int _extractChatroomIdFromNextData(Map<String, dynamic> data) {
  final props = data['props'];
  final pageProps = props is Map<String, dynamic> ? props['pageProps'] : null;
  final nestedChannel =
      pageProps is Map<String, dynamic> ? pageProps['channel'] : null;
  final nestedChatroom =
      nestedChannel is Map<String, dynamic> ? nestedChannel['chatroom'] : null;
  final nestedId = nestedChatroom is Map<String, dynamic>
      ? (nestedChatroom['id'] as num?)?.toInt() ?? 0
      : 0;
  if (nestedId > 0) return nestedId;

  final channel = data['channel'];
  final chatroom = channel is Map<String, dynamic> ? channel['chatroom'] : null;
  return chatroom is Map<String, dynamic>
      ? (chatroom['id'] as num?)?.toInt() ?? 0
      : 0;
}

/// Performs a standard HTTP/1.1-compatible Kick request.
Future<KickHttpResponse> kickHttpGet(
  Uri uri,
  Map<String, String> headers,
) async {
  final response = await http.get(uri, headers: headers);
  return KickHttpResponse(statusCode: response.statusCode, body: response.body);
}

/// Performs a direct HTTP/2 Kick request, including ALPN negotiation.
Future<KickHttpResponse> kickHttp2Get(
  Uri uri,
  Map<String, String> headers,
) async {
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
    throw Exception('ALPN did not negotiate h2');
  }

  final transport = http2.ClientTransportConnection.viaSocket(socket);
  final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  final authority = uri.hasPort ? '${uri.host}:$port' : uri.host;
  final stream = transport.makeRequest(
    <http2.Header>[
      http2.Header.ascii(':method', 'GET'),
      http2.Header.ascii(':scheme', uri.scheme),
      http2.Header.ascii(':authority', authority),
      http2.Header.ascii(':path', path),
      for (final entry in headers.entries)
        http2.Header.ascii(entry.key, entry.value),
    ],
    endStream: true,
  );
  final body = <int>[];
  var statusCode = 0;
  try {
    await for (final message in stream.incomingMessages) {
      if (message is http2.HeadersStreamMessage) {
        for (final header in message.headers) {
          if (utf8.decode(header.name) == ':status') {
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
  return KickHttpResponse(
    statusCode: statusCode,
    body: utf8.decode(body, allowMalformed: true),
  );
}
