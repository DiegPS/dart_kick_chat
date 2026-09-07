/// Anonymous Kick.com chat client for Dart.
/// Connects via Pusher WebSocket — no OAuth required.
library dart_kick_chat;

export 'src/api.dart'
    show
        KickApiClient,
        KickApiException,
        KickCategory,
        KickChannel,
        KickChannelUser,
        KickChatHistory,
        KickChatroom,
        KickLivestream,
        KickPinnedMessage;
export 'src/channel.dart'
    show
        getChatroomId,
        parseKickChatroomId,
        parseKickChatroomIdFromHtml,
        parseKickChannelIdFromHtml,
        parseKickChannelTarget,
        KickChannelTarget,
        KickChannelLookupException,
        KickChannelResolver,
        KickHttpGet,
        KickHttpResponse,
        kickHttp2Get,
        kickHttpGet,
        normalizeKickSlug;
export 'src/channel_monitor.dart' show KickChannelFetch, KickChannelMonitor;
export 'src/emotes.dart' show parseEmotes, parseMessage, parseMessagePayload;
export 'src/events.dart'
    show
        KickChatMessageEvent,
        KickChatroomClearedEvent,
        KickEvent,
        KickGiftChunk,
        KickGiftedSubscriptionsEvent,
        KickKnownEvent,
        KickMessageDeletedEvent,
        KickPinnedMessageCreatedEvent,
        KickPinnedMessageDeletedEvent,
        KickProtocolException,
        KickSubscriptionEvent,
        KickUnknownEvent,
        KickUserBannedEvent,
        KickUserUnbannedEvent,
        parseKickEvent;
export 'src/kick_client.dart'
    show
        KickClient,
        KickConnectionState,
        KickConnectionUpdate,
        KickLogSink,
        KickSocket,
        KickSocketConnector;
export 'src/types.dart'
    show
        Badge,
        BadgeV2,
        ChatCelebration,
        ChatMessage,
        ChatMessageMetadata,
        Identity,
        MessagePart,
        MessageReference,
        MessageReferenceSender,
        ParsedEmote,
        Sender;
