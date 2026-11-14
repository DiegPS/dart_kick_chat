import 'dart:convert';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

KickRealtimeApi _api(KickHttpResponse Function(Uri uri, Map body) answer,
        {List<Uri>? requested, List<Map<String, String>>? headers}) =>
    KickRealtimeApi(
      httpPost: (uri, h, body) async {
        requested?.add(uri);
        headers?.add(h);
        return answer(uri, jsonDecode(body) as Map);
      },
    );

void main() {
  test('requests a centrifugo descriptor and returns its URL', () async {
    final requested = <Uri>[];
    final headers = <Map<String, String>>[];
    Map? sent;
    final api = _api((uri, body) {
      sent = body;
      return KickHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'data': {
            'connections': [
              {
                'provider': 'pusher',
                'credentials': {'app_key': 'x'},
              },
              {
                'provider': 'centrifugo',
                'credentials': {'url': 'wss://rt.kick/connection/websocket'},
              },
            ],
          },
        }),
      );
    }, requested: requested, headers: headers);

    final url = await api.connectionUrl('client-1');

    expect(url.toString(), 'wss://rt.kick/connection/websocket');
    expect(requested.single.toString(),
        'https://web.kick.com/api/v1/realtime/connection');
    expect((sent!['client'] as Map)['id'], 'client-1');
    expect(jsonEncode(sent!['capabilities']), contains('centrifugo'));
    expect(headers.single['Origin'], 'https://kick.com');
  });

  test('fails clearly when no supported provider is offered', () async {
    final api = _api((_, __) => KickHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'data': {
              'connections': [
                {'provider': 'pusher', 'credentials': <String, Object>{}},
              ],
            },
          }),
        ));

    await expectLater(
      api.connectionUrl('c'),
      throwsA(isA<KickRealtimeException>()
          .having((e) => e.message, 'message', contains('offered: pusher'))),
    );
  });

  test('rejects non-WebSocket descriptor URLs', () async {
    final api = _api((_, __) => KickHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'data': {
              'connections': [
                {
                  'provider': 'centrifugo',
                  'credentials': {'url': 'https://example.com'},
                },
              ],
            },
          }),
        ));

    await expectLater(
        api.connectionUrl('c'), throwsA(isA<KickRealtimeException>()));
  });

  test('returns the guest token', () async {
    final requested = <Uri>[];
    Map? sent;
    final api = _api((uri, body) {
      sent = body;
      return const KickHttpResponse(
        statusCode: 200,
        body: '{"data":{"token":"jwt"},"message":"success"}',
      );
    }, requested: requested);

    expect(await api.connectionToken('client-9'), 'jwt');
    expect(requested.single.path, '/api/v1/realtime/auth/connection');
    expect(sent, {'client_id': 'client-9'});
  });

  test('reports HTTP errors, invalid JSON and missing tokens', () async {
    final failing = _api(
        (_, __) => const KickHttpResponse(statusCode: 403, body: 'blocked'));
    await expectLater(
      failing.connectionToken('c'),
      throwsA(isA<KickRealtimeException>()
          .having((e) => e.statusCode, 'statusCode', 403)),
    );

    final garbage = _api(
        (_, __) => const KickHttpResponse(statusCode: 200, body: '<html>'));
    await expectLater(
        garbage.connectionToken('c'), throwsA(isA<KickRealtimeException>()));

    final empty = _api((_, __) =>
        const KickHttpResponse(statusCode: 200, body: '{"data":{}}'));
    await expectLater(
        empty.connectionToken('c'), throwsA(isA<KickRealtimeException>()));
  });

  test('honors a custom base URI', () async {
    final requested = <Uri>[];
    final api = KickRealtimeApi(
      baseUri: Uri.parse('http://localhost:8080/api/'),
      httpPost: (uri, _, __) async {
        requested.add(uri);
        return const KickHttpResponse(
            statusCode: 200, body: '{"data":{"token":"t"}}');
      },
    );

    await api.connectionToken('c');
    expect(requested.single.toString(),
        'http://localhost:8080/api/v1/realtime/auth/connection');
  });
}
