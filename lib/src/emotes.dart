import 'package:dart_kick_chat/src/types.dart';

const _emoteCdn = 'https://files.kick.com/emotes/%s/fullsize';
final _emotePattern = RegExp(r'\[emote:(\d+):([^\]]+)\]');

/// Extracts all unique [emote:id:name] tokens from raw message [content]
/// and returns them as a deduplicated list with CDN URLs.
List<ParsedEmote> parseEmotes(String content) {
  final matches = _emotePattern.allMatches(content);
  if (matches.isEmpty) return const [];

  final seen = <String>{};
  final emotes = <ParsedEmote>[];

  for (final m in matches) {
    final id = m.group(1)!;
    final name = m.group(2)!;
    final key = '$id:$name';
    if (seen.contains(key)) continue;
    seen.add(key);
    emotes.add(ParsedEmote(
      id: id,
      name: name,
      url: _emoteCdn.replaceFirst('%s', id),
    ));
  }
  return emotes;
}

/// Splits raw message [content] into an ordered list of [MessagePart]s —
/// plain text and emote items interleaved exactly as they appear.
/// Suitable for direct rendering without any further parsing.
List<MessagePart> parseMessage(String content) {
  final parts = <MessagePart>[];
  var last = 0;

  for (final m in _emotePattern.allMatches(content)) {
    if (m.start > last) {
      parts.add(MessagePart.text(content.substring(last, m.start)));
    }
    final id = m.group(1)!;
    final name = m.group(2)!;
    parts.add(MessagePart.emote(ParsedEmote(
      id: id,
      name: name,
      url: _emoteCdn.replaceFirst('%s', id),
    )));
    last = m.end;
  }

  if (last < content.length) {
    parts.add(MessagePart.text(content.substring(last)));
  }
  if (parts.isEmpty) return [MessagePart.text(content)];
  return parts;
}
