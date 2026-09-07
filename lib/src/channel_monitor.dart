import 'dart:async';

import 'api.dart';

/// Fetches current public metadata for a Kick channel.
typedef KickChannelFetch = Future<KickChannel> Function(String slug);

/// Polls Kick's anonymous channel endpoint and publishes metadata changes.
///
/// The monitor never authenticates and never sends channel actions. Calls are
/// serialized, so a slow request cannot overlap the following poll.
final class KickChannelMonitor {
  KickChannelMonitor({
    KickApiClient? apiClient,
    KickChannelFetch? fetchChannel,
    this.interval = const Duration(seconds: 15),
  }) : _fetchChannel =
            fetchChannel ?? (apiClient ?? KickApiClient()).fetchChannel;

  final KickChannelFetch _fetchChannel;
  final Duration interval;
  final StreamController<KickChannel> _states =
      StreamController<KickChannel>.broadcast();
  final StreamController<Exception> _errors =
      StreamController<Exception>.broadcast();
  Timer? _timer;
  String? _slug;
  bool _polling = false;
  bool _closed = false;
  KickChannel? _latest;

  Stream<KickChannel> get states => _states.stream;
  Stream<Exception> get errors => _errors.stream;
  KickChannel? get latest => _latest;

  Future<KickChannel> start(String slug) async {
    if (_closed) throw StateError('KickChannelMonitor is closed');
    _slug = slug;
    _timer?.cancel();
    if (interval > Duration.zero) {
      _timer = Timer.periodic(interval, (_) => unawaited(poll()));
    }
    return poll();
  }

  Future<KickChannel> poll() async {
    if (_closed) throw StateError('KickChannelMonitor is closed');
    final slug = _slug;
    if (slug == null) throw StateError('KickChannelMonitor has not started');
    if (_polling) return _latest ?? await _waitForFirstState();
    _polling = true;
    try {
      final channel = await _fetchChannel(slug);
      _latest = channel;
      if (!_states.isClosed) _states.add(channel);
      return channel;
    } on Exception catch (error) {
      if (!_errors.isClosed) _errors.add(error);
      rethrow;
    } catch (error) {
      final exception = Exception(error.toString());
      if (!_errors.isClosed) _errors.add(exception);
      throw exception;
    } finally {
      _polling = false;
    }
  }

  Future<KickChannel> _waitForFirstState() async {
    final latest = _latest;
    if (latest != null) return latest;
    return states.first;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await _states.close();
    await _errors.close();
  }
}
