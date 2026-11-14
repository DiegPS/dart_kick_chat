import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'channel.dart' show KickHttpResponse;

const _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Performs an HTTP POST request with a JSON [body].
typedef KickHttpPost = Future<KickHttpResponse> Function(
  Uri uri,
  Map<String, String> headers,
  String body,
);

/// Performs a standard HTTP POST request.
Future<KickHttpResponse> kickHttpPost(
  Uri uri,
  Map<String, String> headers,
  String body,
) async {
  final response = await http.post(uri, headers: headers, body: body);
  return KickHttpResponse(statusCode: response.statusCode, body: response.body);
}

/// A failure while asking Kick where and how to open the realtime socket.
final class KickRealtimeException implements Exception {
  const KickRealtimeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'KickRealtimeException: $message';
}

/// Kick's public realtime API: where to connect and the anonymous token
/// required by the realtime (Centrifugo) WebSocket.
///
/// Kick replaced its Pusher app in 2026. The browser client first asks this
/// API for a connection descriptor, then for a short-lived guest token, and
/// only then opens the WebSocket. Both calls need no account.
final class KickRealtimeApi {
  KickRealtimeApi({
    KickHttpPost? httpPost,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 15),
  })  : _httpPost = httpPost ?? kickHttpPost,
        _baseUri = baseUri ?? Uri.parse('https://web.kick.com/api/');

  final KickHttpPost _httpPost;
  final Uri _baseUri;
  final Duration timeout;

  static const _headers = <String, String>{
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'Origin': 'https://kick.com',
    'Referer': 'https://kick.com/',
    'User-Agent': _browserUserAgent,
  };

  /// Returns the WebSocket URL to use for [clientId].
  Future<Uri> connectionUrl(String clientId) async {
    final body = await _post('v1/realtime/connection', {
      'client': {'id': clientId, 'type': 'web'},
      'capabilities': {
        'accepted_providers': [
          {'provider': 'centrifugo'},
        ],
      },
    });
    final data = body['data'];
    final connections = data is Map ? data['connections'] : null;
    final offered = <String>[];
    if (connections is List) {
      for (final connection in connections) {
        if (connection is! Map) continue;
        final provider = connection['provider']?.toString() ?? '';
        offered.add(provider);
        final credentials = connection['credentials'];
        final url = credentials is Map ? credentials['url'] : null;
        if (provider == 'centrifugo' && url is String && url.isNotEmpty) {
          final uri = Uri.tryParse(url);
          if (uri != null && (uri.scheme == 'wss' || uri.scheme == 'ws')) {
            return uri;
          }
        }
      }
    }
    throw KickRealtimeException(
      'no supported realtime provider (offered: ${offered.join(', ')})',
    );
  }

  /// Returns a guest connection token for [clientId].
  Future<String> connectionToken(String clientId) async {
    final body = await _post(
      'v1/realtime/auth/connection',
      {'client_id': clientId},
    );
    final data = body['data'];
    final token = data is Map ? data['token'] : null;
    if (token is String && token.isNotEmpty) return token;
    throw const KickRealtimeException('connection token missing in response');
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> payload,
  ) async {
    final uri = _baseUri.resolve(path);
    final response =
        await _httpPost(uri, _headers, jsonEncode(payload)).timeout(timeout);
    if (response.statusCode != 200) {
      throw KickRealtimeException(
        'HTTP ${response.statusCode} from ${uri.path}',
        statusCode: response.statusCode,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw KickRealtimeException('invalid JSON from ${uri.path}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw KickRealtimeException('unexpected response from ${uri.path}');
    }
    return decoded;
  }
}
