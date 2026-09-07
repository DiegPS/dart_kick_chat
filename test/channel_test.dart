import 'dart:async';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  group('Kick channel parsing', () {
    test('parses direct and nested JSON IDs', () {
      expect(parseKickChatroomId('{"chatroom_id": 12}'), 12);
      expect(parseKickChatroomId('{"chatroom":{"id":34}}'), 34);
      expect(parseKickChatroomId('{}'), 0);
      expect(parseKickChatroomId('[]'), 0);
    });

    test('parses the channel target required by chat and channel topics', () {
      final target = parseKickChannelTarget(
        '{"id":91,"user_id":73,"slug":"Creator","chatroom":{"id":42}}',
      );

      expect(target?.slug, 'creator');
      expect(target?.chatroomId, 42);
      expect(target?.channelId, 91);
      expect(target?.userId, 73);
    });

    test('parses both known HTML representations', () {
      expect(
        parseKickChatroomIdFromHtml(
          '<script id="__NEXT_DATA__" type="application/json">'
          '{"props":{"pageProps":{"channel":{"chatroom":{"id":55}}}}}'
          '</script>',
        ),
        55,
      );
      expect(
        parseKickChannelIdFromHtml(
          '<script id="__NEXT_DATA__" type="application/json">'
          '{"props":{"pageProps":{"channel":{"id":77,'
          '"chatroom":{"id":55}}}}}'
          '</script>',
        ),
        77,
      );
      expect(
        parseKickChatroomIdFromHtml('<div data-x="{&quot;chatroom&quot;}">'
            '"chatroom": { "id": 89 }</div>'),
        89,
      );
    });

    test('malformed next data still uses direct HTML fallback', () {
      expect(
        parseKickChatroomIdFromHtml(
          '<script id="__NEXT_DATA__" type="application/json">{bad}</script>'
          '"chatroom":{"id":144}',
        ),
        144,
      );
    });
  });

  group('KickChannelResolver', () {
    test('normalizes URL and succeeds on first v2 HTTP/2 response', () async {
      late Uri requested;
      final resolver = KickChannelResolver(
        http2Get: (uri, headers) async {
          requested = uri;
          return const KickHttpResponse(
            statusCode: 200,
            body: '{"chatroom":{"id":42}}',
          );
        },
        httpGet: (_, __) async =>
            const KickHttpResponse(statusCode: 500, body: ''),
      );

      expect(await resolver.resolve('https://kick.com/Some_Channel'), 42);
      expect(requested.path, '/api/v2/channels/some_channel');
    });

    test('falls through HTTP/2, v2 and v1 to HTML', () async {
      final paths = <String>[];
      final resolver = KickChannelResolver(
        http2Get: (_, __) async => throw Exception('no h2'),
        httpGet: (uri, headers) async {
          paths.add(uri.path);
          if (uri.path == '/creator') {
            return const KickHttpResponse(
              statusCode: 200,
              body: '"chatroom":{"id":81}',
            );
          }
          return const KickHttpResponse(statusCode: 404, body: 'not found');
        },
      );

      expect(await resolver.resolve('@Creator'), 81);
      expect(paths, [
        '/api/v2/channels/creator',
        '/api/v1/channels/creator',
        '/creator',
      ]);
    });

    test('times out a transport and continues to the next strategy', () async {
      final never = Completer<KickHttpResponse>();
      var httpCalls = 0;
      final resolver = KickChannelResolver(
        requestTimeout: const Duration(milliseconds: 5),
        http2Get: (_, __) => never.future,
        httpGet: (_, __) async {
          httpCalls++;
          return const KickHttpResponse(
            statusCode: 200,
            body: '{"chatroom_id":7}',
          );
        },
      );

      expect(await resolver.resolve('creator'), 7);
      expect(httpCalls, 1);
    });

    test('throws a typed, content-free error after all fallbacks fail',
        () async {
      final resolver = KickChannelResolver(
        http2Get: (_, __) async =>
            const KickHttpResponse(statusCode: 403, body: 'private response'),
        httpGet: (_, __) async =>
            const KickHttpResponse(statusCode: 403, body: 'private response'),
      );

      await expectLater(
        resolver.resolve('creator'),
        throwsA(isA<KickChannelLookupException>()),
      );
    });

    test('rejects invalid or foreign channel input before network access', () {
      final resolver = KickChannelResolver(
        http2Get: (_, __) => throw StateError('must not be called'),
        httpGet: (_, __) => throw StateError('must not be called'),
      );

      expect(() => resolver.resolve('https://example.com/user'),
          throwsArgumentError);
      expect(() => resolver.resolve(''), throwsArgumentError);
    });
  });
}
