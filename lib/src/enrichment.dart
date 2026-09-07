import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'channel.dart';
import 'types.dart';

/// Loads the broadcaster's 7TV emote set through its public Kick mapping.
final class KickExternalEmoteLoader {
  KickExternalEmoteLoader({
    KickHttpGet? httpGet,
    this.requestTimeout = const Duration(seconds: 5),
  }) : _httpGet = httpGet ?? kickHttpGet;

  final KickHttpGet _httpGet;
  final Duration requestTimeout;

  Future<Map<String, ParsedEmote>> loadSevenTv(int kickUserId) async {
    if (kickUserId <= 0) return const {};
    final uri = Uri.parse('https://7tv.io/v3/users/kick/$kickUserId');
    final response = await _httpGet(uri, const {'Accept': 'application/json'})
        .timeout(requestTimeout);
    if (response.statusCode == 404) return const {};
    if (response.statusCode != 200) {
      throw KickEnrichmentHttpException(uri, response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw const FormatException('Invalid 7TV response');
    final set = decoded['emote_set'];
    final emotes = set is Map ? set['emotes'] : null;
    if (emotes is! List) return const {};
    final result = <String, ParsedEmote>{};
    for (final value in emotes.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final id = item['id']?.toString() ?? '';
      final name = item['name']?.toString() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      result[name] = ParsedEmote(
        id: id,
        name: name,
        url: 'https://cdn.7tv.app/emote/$id/1x.webp',
      );
    }
    return Map.unmodifiable(result);
  }
}

/// Resolves public Kick avatars with bounded concurrency and an in-memory LRU.
final class KickProfileResolver {
  KickProfileResolver({
    KickHttpGet? httpGet,
    this.requestTimeout = const Duration(seconds: 5),
    this.cacheTtl = const Duration(hours: 12),
    this.maximumCacheEntries = 500,
    this.maximumConcurrentRequests = 3,
    DateTime Function()? now,
  })  : _httpGet = httpGet ?? kickHttpGet,
        _now = now ?? DateTime.now {
    if (maximumCacheEntries <= 0) {
      throw ArgumentError.value(maximumCacheEntries, 'maximumCacheEntries');
    }
    if (maximumConcurrentRequests <= 0) {
      throw ArgumentError.value(
        maximumConcurrentRequests,
        'maximumConcurrentRequests',
      );
    }
  }

  final KickHttpGet _httpGet;
  final Duration requestTimeout;
  final Duration cacheTtl;
  final int maximumCacheEntries;
  final int maximumConcurrentRequests;
  final DateTime Function() _now;
  final LinkedHashMap<String, _ProfileCacheEntry> _cache = LinkedHashMap();
  final Map<String, Future<String>> _pending = {};
  final Queue<Completer<void>> _waiting = Queue();
  int _active = 0;

  String? peek(String channelSlug, String username) {
    final key = _key(channelSlug, username);
    final entry = _cache[key];
    if (entry == null) return null;
    if (_now().difference(entry.storedAt) > cacheTtl) {
      _cache.remove(key);
      return null;
    }
    _cache
      ..remove(key)
      ..[key] = entry;
    return entry.url;
  }

  Future<String> resolve(String channelSlug, String username) {
    if (channelSlug.trim().isEmpty || username.trim().isEmpty) {
      return Future.value('');
    }
    final cached = peek(channelSlug, username);
    if (cached != null) return Future.value(cached);
    final key = _key(channelSlug, username);
    return _pending.putIfAbsent(key, () async {
      await _acquire();
      try {
        final uri = Uri.parse(
          'https://kick.com/channels/${Uri.encodeComponent(channelSlug)}/'
          '${Uri.encodeComponent(username)}',
        );
        final response = await _httpGet(uri, const {
          'Accept': 'application/json',
          'Referer': 'https://kick.com/',
        }).timeout(requestTimeout);
        var avatar = '';
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            avatar = (decoded['profilepic'] ??
                    decoded['profile_pic'] ??
                    decoded['profile_picture'] ??
                    '')
                .toString();
          }
        } else if (response.statusCode != 404) {
          throw KickEnrichmentHttpException(uri, response.statusCode);
        }
        _store(key, avatar);
        return avatar;
      } finally {
        _release();
        _pending.remove(key);
      }
    });
  }

  String _key(String channelSlug, String username) =>
      '${channelSlug.trim().toLowerCase()}\u0000${username.trim().toLowerCase()}';

  void _store(String key, String url) {
    _cache[key] = _ProfileCacheEntry(url, _now());
    while (_cache.length > maximumCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<void> _acquire() {
    if (_active < maximumConcurrentRequests) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }
}

final class KickProfileUpdate {
  const KickProfileUpdate({
    required this.username,
    required this.slug,
    required this.avatarUrl,
  });

  final String username;
  final String slug;
  final String avatarUrl;
}

final class KickEnrichmentHttpException implements Exception {
  const KickEnrichmentHttpException(this.uri, this.statusCode);
  final Uri uri;
  final int statusCode;

  @override
  String toString() => 'Kick enrichment request failed ($statusCode): $uri';
}

final class _ProfileCacheEntry {
  const _ProfileCacheEntry(this.url, this.storedAt);
  final String url;
  final DateTime storedAt;
}
