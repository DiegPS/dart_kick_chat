import 'dart:convert';
import 'dart:io';

import 'channel.dart'
    show
        KickHttpGet,
        KickHttpResponse,
        kickHttp2Get,
        kickHttpGet,
        normalizeKickSlug;
import 'events.dart' show KickProtocolException;
import 'types.dart';

const _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Referer': 'https://kick.com/',
  'Origin': 'https://kick.com',
  'x-app-platform': 'web',
};

/// Failure returned by an anonymous Kick HTTP endpoint.
final class KickApiException implements Exception {
  const KickApiException(this.uri, this.statusCode);
  final Uri uri;
  final int statusCode;

  @override
  String toString() => 'Kick request failed ($statusCode): ${uri.path}';
}

class KickCategory {
  const KickCategory(
      {required this.id,
      required this.name,
      required this.slug,
      required this.raw});
  factory KickCategory.fromJson(Map<String, dynamic> json) => KickCategory(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        raw: Map.unmodifiable(json),
      );
  final int id;
  final String name;
  final String slug;
  final Map<String, dynamic> raw;
}

class KickLivestream {
  const KickLivestream({
    required this.id,
    required this.slug,
    required this.title,
    required this.isLive,
    required this.viewerCount,
    required this.startedAt,
    required this.language,
    required this.isMature,
    required this.thumbnailUrl,
    required this.category,
    required this.tags,
    required this.durationSeconds,
    required this.raw,
  });
  factory KickLivestream.fromJson(Map<String, dynamic> json) {
    final categories = _maps(json['categories']).toList();
    final category = _map(json['category']);
    final thumbnail = _map(json['thumbnail']);
    return KickLivestream(
      id: (json['id'] as num?)?.toInt() ?? 0,
      slug: json['slug'] as String? ?? '',
      title: json['session_title'] as String? ?? '',
      isLive: json['is_live'] as bool? ?? true,
      viewerCount: (json['viewer_count'] as num?)?.toInt() ??
          (json['viewers'] as num?)?.toInt() ??
          0,
      startedAt: _date(json['start_time'] ?? json['created_at']),
      language: json['language'] as String? ?? '',
      isMature: json['is_mature'] as bool? ?? false,
      thumbnailUrl:
          thumbnail['url'] as String? ?? thumbnail['src'] as String? ?? '',
      category: categories.isNotEmpty
          ? KickCategory.fromJson(categories.first)
          : category.isEmpty
              ? null
              : KickCategory.fromJson(category),
      tags: _strings(json['tags']),
      durationSeconds: (json['duration'] as num?)?.toInt() ?? 0,
      raw: Map.unmodifiable(json),
    );
  }
  final int id;
  final String slug;
  final String title;
  final bool isLive;
  final int viewerCount;
  final DateTime? startedAt;
  final String language;
  final bool isMature;
  final String thumbnailUrl;
  final KickCategory? category;
  final List<String> tags;
  final int durationSeconds;
  final Map<String, dynamic> raw;
}

class KickChatroom {
  const KickChatroom({
    required this.id,
    required this.channelId,
    required this.mode,
    required this.slowMode,
    required this.messageInterval,
    required this.followersMode,
    required this.followingMinimumMinutes,
    required this.subscribersMode,
    required this.emotesMode,
    required this.accountAgeMode,
    required this.accountAgeMinimumMinutes,
    required this.showQuickEmotes,
    required this.showBanners,
    required this.giftsEnabled,
    required this.weeklyGiftsEnabled,
    required this.monthlyGiftsEnabled,
    required this.pinnedMessage,
    required this.raw,
  });
  factory KickChatroom.fromJson(Map<String, dynamic> json) => KickChatroom(
        id: (json['id'] as num?)?.toInt() ?? 0,
        channelId: (json['channel_id'] as num?)?.toInt() ?? 0,
        mode: json['chat_mode'] as String? ?? '',
        slowMode: _enabled(json['slow_mode']),
        messageInterval: _nestedInt(json['slow_mode'], 'message_interval') ??
            (json['message_interval'] as num?)?.toInt() ??
            0,
        followersMode: _enabled(json['followers_mode']),
        followingMinimumMinutes:
            _nestedInt(json['followers_mode'], 'min_duration') ??
                (json['following_min_duration'] as num?)?.toInt() ??
                0,
        subscribersMode: _enabled(json['subscribers_mode']),
        emotesMode: _enabled(json['emotes_mode']),
        accountAgeMode: _enabled(json['account_age']),
        accountAgeMinimumMinutes:
            _nestedInt(json['account_age'], 'min_duration') ?? 0,
        showQuickEmotes: _enabled(json['show_quick_emotes']),
        showBanners: _enabled(json['show_banners']),
        giftsEnabled: _enabled(json['gifts_enabled']),
        weeklyGiftsEnabled: _enabled(json['gifts_week_enabled']),
        monthlyGiftsEnabled: _enabled(json['gifts_month_enabled']),
        pinnedMessage: _map(json['pinned_message']).isEmpty
            ? null
            : KickPinnedMessage.fromJson(_map(json['pinned_message'])),
        raw: Map.unmodifiable(json),
      );
  final int id;
  final int channelId;
  final String mode;
  final bool slowMode;
  final int messageInterval;
  final bool followersMode;
  final int followingMinimumMinutes;
  final bool subscribersMode;
  final bool emotesMode;
  final bool accountAgeMode;
  final int accountAgeMinimumMinutes;
  final bool showQuickEmotes;
  final bool showBanners;
  final bool giftsEnabled;
  final bool weeklyGiftsEnabled;
  final bool monthlyGiftsEnabled;
  final KickPinnedMessage? pinnedMessage;
  final Map<String, dynamic> raw;
}

class KickChannelUser {
  const KickChannelUser(
      {required this.id,
      required this.username,
      required this.profilePictureUrl,
      required this.bio,
      required this.socialLinks,
      required this.raw});
  factory KickChannelUser.fromJson(Map<String, dynamic> json) =>
      KickChannelUser(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        profilePictureUrl: json['profile_pic'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
        socialLinks: {
          for (final key in const [
            'instagram',
            'twitter',
            'youtube',
            'discord',
            'tiktok',
            'facebook',
            'club',
          ])
            if ((json[key] as String?)?.isNotEmpty ?? false)
              key: json[key] as String,
        },
        raw: Map.unmodifiable(json),
      );
  final int id;
  final String username;
  final String profilePictureUrl;
  final String bio;
  final Map<String, String> socialLinks;
  final Map<String, dynamic> raw;
}

/// Public channel metadata used to establish chat and describe the live stream.
class KickChannel {
  const KickChannel({
    required this.id,
    required this.userId,
    required this.slug,
    required this.followersCount,
    required this.verified,
    required this.isBanned,
    required this.playbackUrl,
    required this.vodEnabled,
    required this.subscriptionEnabled,
    required this.isAffiliate,
    required this.muted,
    required this.canHost,
    required this.bannerUrl,
    required this.offlineBannerUrl,
    required this.recentCategories,
    required this.user,
    required this.chatroom,
    required this.livestream,
    required this.raw,
  });
  factory KickChannel.fromJson(Map<String, dynamic> json) {
    final livestream = _map(json['livestream']);
    return KickChannel(
      id: (json['id'] as num?)?.toInt() ?? 0,
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      slug: json['slug'] as String? ?? '',
      followersCount:
          int.tryParse(json['followers_count']?.toString() ?? '') ?? 0,
      verified: json['verified'] as bool? ?? false,
      isBanned: json['is_banned'] as bool? ?? false,
      playbackUrl: json['playback_url'] as String? ?? '',
      vodEnabled: json['vod_enabled'] as bool? ?? false,
      subscriptionEnabled: json['subscription_enabled'] as bool? ?? false,
      isAffiliate: json['is_affiliate'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
      canHost: json['can_host'] as bool? ?? false,
      bannerUrl: _map(json['banner_image'])['url'] as String? ?? '',
      offlineBannerUrl:
          _map(json['offline_banner_image'])['src'] as String? ?? '',
      recentCategories:
          _maps(json['recent_categories']).map(KickCategory.fromJson).toList(),
      user: KickChannelUser.fromJson(_map(json['user'])),
      chatroom: KickChatroom.fromJson(_map(json['chatroom'])),
      livestream:
          livestream.isEmpty ? null : KickLivestream.fromJson(livestream),
      raw: Map.unmodifiable(json),
    );
  }
  final int id;
  final int userId;
  final String slug;
  final int followersCount;
  final bool verified;
  final bool isBanned;
  final String playbackUrl;
  final bool vodEnabled;
  final bool subscriptionEnabled;
  final bool isAffiliate;
  final bool muted;
  final bool canHost;
  final String bannerUrl;
  final String offlineBannerUrl;
  final List<KickCategory> recentCategories;
  final KickChannelUser user;
  final KickChatroom chatroom;
  final KickLivestream? livestream;
  final Map<String, dynamic> raw;
}

class KickPinnedMessage {
  const KickPinnedMessage(
      {required this.message, required this.pinnedBy, required this.raw});
  factory KickPinnedMessage.fromJson(Map<String, dynamic> json) =>
      KickPinnedMessage(
        message: ChatMessage.fromJson(_map(json['message'])),
        pinnedBy: Sender.fromJson(_map(json['pinned_by'])),
        raw: Map.unmodifiable(json),
      );
  final ChatMessage message;
  final Sender pinnedBy;
  final Map<String, dynamic> raw;
}

class KickChatHistory {
  const KickChatHistory(
      {required this.messages,
      required this.cursor,
      required this.pinnedMessage,
      required this.raw});
  factory KickChatHistory.fromJson(Map<String, dynamic> json) {
    final pin = _map(json['pinned_message']);
    return KickChatHistory(
      messages: _maps(json['messages']).map(ChatMessage.fromJson).toList(),
      cursor: json['cursor'] as String? ?? '',
      pinnedMessage: pin.isEmpty ? null : KickPinnedMessage.fromJson(pin),
      raw: Map.unmodifiable(json),
    );
  }
  final List<ChatMessage> messages;
  final String cursor;
  final KickPinnedMessage? pinnedMessage;
  final Map<String, dynamic> raw;
}

/// Anonymous client for the public data used by Kick's own channel page.
class KickApiClient {
  KickApiClient(
      {KickHttpGet? httpGet,
      KickHttpGet? http2Get,
      this.requestTimeout = const Duration(seconds: 15)})
      : _primaryGet = http2Get ?? httpGet ?? kickHttp2Get,
        _fallbackGet =
            http2Get != null ? httpGet : (httpGet != null ? null : kickHttpGet);
  final KickHttpGet _primaryGet;
  final KickHttpGet? _fallbackGet;
  final Duration requestTimeout;

  Future<KickChannel> fetchChannel(String slug) async {
    final normalized = normalizeKickSlug(slug);
    final json =
        await _get(Uri.parse('https://kick.com/api/v2/channels/$normalized'));
    return KickChannel.fromJson(json);
  }

  Future<KickChatroom> fetchChatroom(String slug) async {
    final normalized = normalizeKickSlug(slug);
    final json = await _get(
        Uri.parse('https://kick.com/api/v2/channels/$normalized/chatroom'));
    return KickChatroom.fromJson(json);
  }

  Future<KickChatHistory> fetchChatHistory(int channelId,
      {DateTime? startTime}) async {
    if (channelId <= 0) {
      throw ArgumentError.value(channelId, 'channelId', 'must be positive');
    }
    var uri = Uri.parse('https://web.kick.com/api/v1/chat/$channelId/history');
    if (startTime != null) {
      uri = uri.replace(
          queryParameters: {'start_time': startTime.toUtc().toIso8601String()});
    }
    final response = await _get(uri);
    final data = _map(response['data']);
    if (data.isEmpty) {
      throw const KickProtocolException('history data is missing');
    }
    return KickChatHistory.fromJson(data);
  }

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final fallback = _fallbackGet;
    KickHttpResponse response;
    var usedFallback = false;
    try {
      response = await _request(_primaryGet, uri);
    } catch (_) {
      if (fallback == null) rethrow;
      usedFallback = true;
      response = await _request(fallback, uri);
    }
    if (response.statusCode != HttpStatus.ok &&
        fallback != null &&
        !usedFallback) {
      response = await _request(fallback, uri);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw KickApiException(uri, response.statusCode);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Converted below to a sanitized protocol error without response content.
    }
    throw const KickProtocolException('response is not a JSON object');
  }

  Future<KickHttpResponse> _request(KickHttpGet get, Uri uri) =>
      get(uri, _headers).timeout(requestTimeout);
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};
Iterable<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from)
    : const [];
List<String> _strings(Object? value) =>
    value is List ? value.map((item) => item.toString()).toList() : const [];
DateTime? _date(Object? value) => DateTime.tryParse(value?.toString() ?? '');
bool _enabled(Object? value) =>
    value is Map ? value['enabled'] as bool? ?? false : value as bool? ?? false;
int? _nestedInt(Object? value, String key) =>
    value is Map ? (value[key] as num?)?.toInt() : null;
