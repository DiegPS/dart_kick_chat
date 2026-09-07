# dart_kick_chat

An anonymous, read-only Kick live-chat client for Dart. It resolves a public
channel to its chatroom and consumes Kick's public Pusher WebSocket without an
account, OAuth token, cookies, message sending, or moderation privileges.

## Features

- Public channel resolution with HTTP/2, HTTP/1.1, v1, and HTML fallbacks.
- Typed messages, authors, legacy and image badges, emotes, replies, metadata,
  timestamps, and chatroom IDs.
- Public channel/livestream metadata, chat restrictions, initial history, and
  pinned messages.
- Realtime moderation, subscription, gift, pin, poll, reward, host, goal, and
  lifecycle events, with lossless fallback for future event types.
- Automatic WebSocket reconnection and re-subscription.
- Duplicate message suppression using stable Kick message IDs.
- Explicit connection and channel-lookup timeouts.
- Injectable HTTP and WebSocket transports for deterministic tests.
- Opt-in diagnostics that never include chat content or user identities.

## Usage

```dart
import 'package:dart_kick_chat/dart_kick_chat.dart';

Future<void> main() async {
  final client = await KickClient.connect();
  await client.joinBySlug('creator');

  final messages = client.messages.listen((message) {
    print('${message.sender.username}: ${message.content}');
  });
  final errors = client.errors.listen((error) {
    print('Non-fatal Kick error: $error');
  });
  final events = client.events.listen((event) {
    if (event is KickGiftedSubscriptionsEvent) {
      print('${event.giftedTotal} subscriptions gifted');
    }
  });

  // Later:
  await messages.cancel();
  await errors.cancel();
  await events.cancel();
  await client.close();
}
```

`messages`, `events`, and `errors` are broadcast streams. `messages` is the
convenient filtered stream of ordinary chat messages; `events` also carries
deletions, subscriptions, gifts, pins, moderation, and unknown future events.
Protocol and reconnect errors are non-fatal.

## Channel metadata and initial history

`KickApiClient` models the anonymous data used by Kick's own channel page. The
models expose useful stable fields and retain the full decoded object in `raw`
so a newly added server field is never silently discarded.

```dart
final api = KickApiClient();
final channel = await api.fetchChannel('creator');
final history = await api.fetchChatHistory(channel.id);

print(channel.livestream?.title);
print(channel.livestream?.viewerCount);
print(history.messages.length);
print(history.pinnedMessage?.message.content);
```

`fetchChatroom` provides the public slow, followers-only, subscribers-only,
and emotes-only state. `fetchChatHistory` optionally accepts `startTime` for
the same incremental history request used by the web application.

The package intentionally does not call per-user profile endpoints for every
message. Doing so would create an expensive N+1 request pattern. A sender
avatar is exposed when Kick includes `profile_pic`; applications can otherwise
render initials or implement their own explicitly cached enrichment policy.

## Channel resolution

`KickChannelResolver` accepts a slug, `@slug`, or a `kick.com/slug` URL. It
tries the public v2 API over HTTP/2, v2 over the standard Dart HTTP client, v1,
and the public HTML page in that order. Invalid and foreign URLs are rejected
before any request is made.

```dart
final resolver = KickChannelResolver();
final chatroomId = await resolver.resolve('https://kick.com/creator');
```

The lower-level `parseKickChatroomId` and `parseKickChatroomIdFromHtml`
functions are exposed for consumers that already own the response body.

## Realtime event coverage

The client subscribes to `chatrooms.{id}.v2`, `chatroom_{id}`, and
`chatrooms.{id}`. This is required because Kick distributes ordinary chat,
gifted subscriptions, and hosted-stream events across different public topics.
Known evolving events are represented by `KickKnownEvent`; genuinely new
event names become `KickUnknownEvent`. Both preserve every field in `raw`.

For development, `dart run tool/inspect_live.dart <channel> [seconds]` prints
only event names and field shapes. It deliberately omits message text and user
values.

## Testing custom transports

`KickHttpGet`, `KickSocket`, and `KickSocketConnector` are intentionally small
interfaces. They allow applications to simulate timeouts, corrupt frames,
remote closes, and reconnects without contacting Kick. Production callers can
normally use the defaults.

## Privacy and stability

The package does not authenticate and cannot send messages or moderation
commands. A logger is disabled by default. When supplied, it receives only
connection and sanitized protocol diagnostics, never raw frames, response
bodies, usernames, or message content.

Kick now also offers an official authenticated developer API. This package does
not use it because its scope is anonymous, read-only chat. The public web
endpoints and Pusher topics used here are not a versioned contract and can
change.
Consumers should listen to `errors`, tolerate temporary resolution failures,
and keep this package updated.
