import 'dart:async';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  test('loads channel-specific Kick 7TV emotes by public user ID', () async {
    Uri? requested;
    final loader = KickExternalEmoteLoader(httpGet: (uri, _) async {
      requested = uri;
      return const KickHttpResponse(
        statusCode: 200,
        body: '{"emote_set":{"emotes":['
            '{"id":"abc","name":"KickLaugh"}]}}',
      );
    });

    final emotes = await loader.loadSevenTv(42);

    expect(requested.toString(), 'https://7tv.io/v3/users/kick/42');
    expect(emotes['KickLaugh']?.url, 'https://cdn.7tv.app/emote/abc/1x.webp');
  });

  test('external Kick emotes preserve whitespace and native tokens', () {
    const external = ParsedEmote(
      id: 'seven',
      name: 'Wave7',
      url: 'https://cdn.7tv.app/emote/seven/1x.webp',
    );
    final parts = parseMessageWithExternalEmotes(
      'hello Wave7  [emote:2:Native]',
      externalEmotes: const {'Wave7': external},
    );

    expect(parts.map((part) => part.isEmote ? part.emote!.name : part.text),
        ['hello', ' ', 'Wave7', '  ', 'Native']);
  });

  test('profile resolver deduplicates requests and caches the result',
      () async {
    var requests = 0;
    final gate = Completer<void>();
    final resolver = KickProfileResolver(httpGet: (uri, _) async {
      requests++;
      await gate.future;
      return const KickHttpResponse(
        statusCode: 200,
        body: '{"profilepic":"https://kick/avatar.webp"}',
      );
    });

    final first = resolver.resolve('streamer', 'viewer');
    final second = resolver.resolve('streamer', 'VIEWER');
    gate.complete();

    expect(await Future.wait([first, second]),
        everyElement('https://kick/avatar.webp'));
    expect(await resolver.resolve('streamer', 'viewer'),
        'https://kick/avatar.webp');
    expect(requests, 1);
  });

  test('profile resolver never exceeds configured concurrency', () async {
    var active = 0;
    var maximum = 0;
    final gates = List.generate(3, (_) => Completer<void>());
    final resolver = KickProfileResolver(
      maximumConcurrentRequests: 2,
      httpGet: (uri, _) async {
        final index = int.parse(uri.pathSegments.last.substring(1));
        active++;
        if (active > maximum) maximum = active;
        await gates[index].future;
        active--;
        return const KickHttpResponse(statusCode: 404, body: '');
      },
    );

    final futures = List.generate(
      3,
      (index) => resolver.resolve('streamer', 'u$index'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(maximum, 2);
    gates[0].complete();
    await Future<void>.delayed(Duration.zero);
    expect(maximum, 2);
    gates[1].complete();
    gates[2].complete();
    await Future.wait(futures);
  });
}
