import 'dart:async';

import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  test('publishes current anonymous viewer metadata', () async {
    var viewers = 10;
    final monitor = KickChannelMonitor(
      interval: Duration.zero,
      fetchChannel: (_) async => _channel(viewers++),
    );
    addTearDown(monitor.close);

    final initial = await monitor.start('creator');
    final next = await monitor.poll();

    expect(initial.livestream?.viewerCount, 10);
    expect(next.livestream?.viewerCount, 11);
    expect(monitor.latest, same(next));
  });

  test('serializes overlapping polls', () async {
    final completer = Completer<KickChannel>();
    var calls = 0;
    final monitor = KickChannelMonitor(
      interval: Duration.zero,
      fetchChannel: (_) {
        calls++;
        return completer.future;
      },
    );
    addTearDown(monitor.close);

    final first = monitor.start('creator');
    await Future<void>.delayed(Duration.zero);
    final second = monitor.poll();
    completer.complete(_channel(25));

    expect((await first).livestream?.viewerCount, 25);
    expect((await second).livestream?.viewerCount, 25);
    expect(calls, 1);
  });

  test('emits sanitized transport failures and can recover', () async {
    var attempt = 0;
    final monitor = KickChannelMonitor(
      interval: Duration.zero,
      fetchChannel: (_) async {
        if (attempt++ == 0) throw Exception('offline');
        return _channel(7);
      },
    );
    addTearDown(monitor.close);
    final error = monitor.errors.first;

    await expectLater(monitor.start('creator'), throwsException);
    expect(await error, isA<Exception>());
    expect((await monitor.poll()).livestream?.viewerCount, 7);
  });

  test('keeps scheduled polling alive when the initial request fails',
      () async {
    var attempt = 0;
    final monitor = KickChannelMonitor(
      interval: const Duration(milliseconds: 5),
      fetchChannel: (_) async {
        if (attempt++ == 0) throw Exception('offline');
        return _channel(19);
      },
    );
    addTearDown(monitor.close);

    await expectLater(monitor.start('creator'), throwsException);

    expect((await monitor.states.first).livestream?.viewerCount, 19);
  });
}

KickChannel _channel(int viewers) => KickChannel.fromJson({
      'id': 1,
      'slug': 'creator',
      'user': const <String, Object?>{},
      'chatroom': {'id': 2, 'channel_id': 1},
      'livestream': {
        'id': 3,
        'session_title': 'Live',
        'is_live': true,
        'viewer_count': viewers,
      },
    });
