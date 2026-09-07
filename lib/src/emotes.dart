import 'package:dart_kick_chat/src/types.dart';

const _emoteCdn = 'https://files.kick.com/emotes/%s/fullsize';
final _mediaPattern = RegExp(
  r'\[(emote|sticker):(\d+):([^\]]+)\]',
  caseSensitive: false,
);

/// Extracts all unique `emote:id:name` tokens from raw message [content].
///
/// Returns a deduplicated list with CDN URLs.
List<ParsedEmote> parseEmotes(String content) {
  final matches = _mediaPattern.allMatches(content);
  if (matches.isEmpty) return const [];

  final seen = <String>{};
  final emotes = <ParsedEmote>[];

  for (final m in matches) {
    final id = m.group(2)!;
    final name = m.group(3)!;
    final key = '$id:$name';
    if (seen.contains(key)) continue;
    seen.add(key);
    emotes.add(ParsedEmote(
      id: id,
      name: name,
      url: _emoteCdn.replaceFirst('%s', id),
      isSticker: m.group(1)!.toLowerCase() == 'sticker',
    ));
  }
  return emotes;
}

/// Splits raw message [content] into an ordered list of [MessagePart]s.
///
/// Plain text and emote items remain interleaved exactly as they appear, ready
/// for direct rendering without further parsing.
List<MessagePart> parseMessage(String content) {
  final parts = <MessagePart>[];
  var last = 0;

  for (final m in _mediaPattern.allMatches(content)) {
    if (m.start > last) {
      parts.add(MessagePart.text(content.substring(last, m.start)));
    }
    final id = m.group(2)!;
    final name = m.group(3)!;
    parts.add(MessagePart.emote(ParsedEmote(
      id: id,
      name: name,
      url: _emoteCdn.replaceFirst('%s', id),
      isSticker: m.group(1)!.toLowerCase() == 'sticker',
    )));
    last = m.end;
  }

  if (last < content.length) {
    parts.add(MessagePart.text(content.substring(last)));
  }
  if (parts.isEmpty) return [MessagePart.text(content)];
  return parts;
}

/// Parses current structured Kick message fragments, falling back to tokens.
List<MessagePart> parseMessagePayload(Object? value, {String fallback = ''}) {
  final fragments = _fragments(value);
  if (fragments.isEmpty) return parseMessage(fallback);
  final parts = <MessagePart>[];
  for (final fragment in fragments) {
    final kind =
        (fragment['type'] ?? fragment['kind'])?.toString().toLowerCase();
    final text = (fragment['text'] ?? fragment['content'])?.toString() ?? '';
    if (kind == 'emote' || kind == 'sticker') {
      final nested = fragment[kind];
      final media =
          nested is Map ? Map<String, dynamic>.from(nested) : fragment;
      final id = (media['id'] ??
              media['emoteId'] ??
              media['stickerId'] ??
              media['emote_id'] ??
              media['sticker_id'])
          ?.toString();
      final name = (media['name'] ?? media['text'] ?? text).toString();
      final suppliedUrl = (media['url'] ?? media['src'])?.toString() ?? '';
      if (id != null && id.isNotEmpty) {
        parts.add(MessagePart.emote(ParsedEmote(
          id: id,
          name: name,
          url: suppliedUrl.isEmpty
              ? _emoteCdn.replaceFirst('%s', id)
              : suppliedUrl,
          isSticker: kind == 'sticker',
        )));
        continue;
      }
    }
    if (text.isNotEmpty) parts.addAll(parseMessage(text));
  }
  return parts.isEmpty ? parseMessage(fallback) : parts;
}

List<Map<String, dynamic>> _fragments(Object? value) {
  if (value is List) {
    return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }
  if (value is! Map) return const [];
  final map = Map<String, dynamic>.from(value);
  for (final key in const ['fragments', 'content', 'parts', 'messages']) {
    final nested = map[key];
    if (nested is List) {
      return nested.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
  }
  return const [];
}
