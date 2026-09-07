import 'package:dart_kick_chat/dart_kick_chat.dart';
import 'package:test/test.dart';

void main() {
  group('parseEmotes', () {
    test('returns empty for plain text', () {
      expect(parseEmotes('hello world'), isEmpty);
    });

    test('extracts single emote', () {
      final emotes = parseEmotes('[emote:37225:KEKLEO]');
      expect(emotes, hasLength(1));
      expect(emotes.first.id, '37225');
      expect(emotes.first.name, 'KEKLEO');
      expect(emotes.first.url, 'https://files.kick.com/emotes/37225/fullsize');
    });

    test('deduplicates repeated emotes', () {
      final emotes = parseEmotes('[emote:37225:KEKLEO] [emote:37225:KEKLEO]');
      expect(emotes, hasLength(1));
    });

    test('extracts multiple distinct emotes', () {
      final emotes = parseEmotes('[emote:111:PogChamp] hello [emote:222:LUL]');
      expect(emotes, hasLength(2));
      expect(emotes.map((e) => e.name), containsAll(['PogChamp', 'LUL']));
    });
  });

  group('parseMessage', () {
    test('plain text returns single text part', () {
      final parts = parseMessage('hello world');
      expect(parts, hasLength(1));
      expect(parts.first.isEmote, isFalse);
      expect(parts.first.text, 'hello world');
    });

    test('emote only returns single emote part', () {
      final parts = parseMessage('[emote:37225:KEKLEO]');
      expect(parts, hasLength(1));
      expect(parts.first.isEmote, isTrue);
      expect(parts.first.emote!.name, 'KEKLEO');
    });

    test('text before emote is preserved', () {
      final parts = parseMessage('nice [emote:37225:KEKLEO]');
      expect(parts, hasLength(2));
      expect(parts[0].text, 'nice ');
      expect(parts[1].emote!.name, 'KEKLEO');
    });

    test('text after emote is preserved', () {
      final parts = parseMessage('[emote:37225:KEKLEO] lol');
      expect(parts, hasLength(2));
      expect(parts[0].isEmote, isTrue);
      expect(parts[1].text, ' lol');
    });

    test('interleaved text and emotes preserve order', () {
      final parts = parseMessage('hello [emote:1:A] world [emote:2:B] bye');
      expect(parts, hasLength(5));
      expect(parts[0].text, 'hello ');
      expect(parts[1].emote!.name, 'A');
      expect(parts[2].text, ' world ');
      expect(parts[3].emote!.name, 'B');
      expect(parts[4].text, ' bye');
    });

    test('repeated emote appears multiple times in parts', () {
      final parts = parseMessage('[emote:1:A] [emote:1:A]');
      expect(parts, hasLength(3)); // emote, text " ", emote
      expect(parts[0].isEmote, isTrue);
      expect(parts[2].isEmote, isTrue);
    });
  });

  group('ChatMessage.fromJson', () {
    test('parses basic message', () {
      final msg = ChatMessage.fromJson({
        'id': 'abc123',
        'chatroom_id': 42,
        'content': 'hello [emote:37225:KEKLEO]',
        'type': 'message',
        'created_at': '2026-01-01T12:00:00.000Z',
        'sender': {
          'id': 1,
          'username': 'testuser',
          'slug': 'testuser',
          'identity': {'color': '#FF0000', 'badges': []},
        },
      });

      expect(msg.id, 'abc123');
      expect(msg.chatroomId, 42);
      expect(msg.sender.username, 'testuser');
      expect(msg.emotes, hasLength(1));
      expect(msg.parts, hasLength(2));
    });

    test('badges are parsed correctly', () {
      final msg = ChatMessage.fromJson({
        'id': 'x',
        'chatroom_id': 1,
        'content': '',
        'type': 'message',
        'created_at': '2026-01-01T00:00:00.000Z',
        'sender': {
          'id': 99,
          'username': 'mod',
          'slug': 'mod',
          'identity': {
            'color': '#00FF00',
            'badges': [
              {'type': 'moderator', 'text': 'Mod', 'count': 0}
            ],
          },
        },
      });

      expect(msg.sender.identity.badges, hasLength(1));
      expect(msg.sender.identity.badges.first.type, 'moderator');
    });
  });
}
