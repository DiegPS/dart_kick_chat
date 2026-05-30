/// Anonymous Kick.com chat client for Dart.
/// Connects via Pusher WebSocket — no OAuth required.
library dart_kick_chat;

export 'src/channel.dart' show getChatroomId;
export 'src/emotes.dart' show parseEmotes, parseMessage;
export 'src/kick_client.dart' show KickClient;
export 'src/types.dart'
    show Badge, ChatMessage, Identity, MessagePart, ParsedEmote, Sender;
