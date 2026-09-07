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
- Typed realtime moderation, subscription, gift, pin, poll, reward, KICK gift,
  host, goal, livestream lifecycle, and chat-move events.
- Lossless `raw` payloads on every evolving event and a fallback for future
  event names.
- Confirmed Pusher handshake, inactivity watchdog, periodic re-subscription,
  and exponential reconnection with jitter.
- Duplicate event suppression using stable payload identities.
- Token and structured-fragment parsing for emotes and stickers.
- Channel-specific 7TV emotes resolved anonymously from the broadcaster ID.
- Optional profile-avatar enrichment with bounded concurrency and an LRU cache.
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

For a serialized live metadata stream, including anonymous viewer count, use
`KickChannelMonitor`. It polls every 15 seconds by default and never overlaps
requests:

```dart
final monitor = KickChannelMonitor();
monitor.states.listen((channel) {
  print(channel.livestream?.viewerCount);
});
await monitor.start('creator');
```

`fetchChatroom` provides the public slow, followers-only, subscribers-only,
and emotes-only state. `fetchChatHistory` optionally accepts `startTime` for
the same incremental history request used by the web application.

When Kick omits a sender avatar, the client emits the message immediately and
resolves the public profile in the background. Requests are deduplicated,
limited to three concurrent calls, cached in a 500-entry LRU for 12 hours, and
reported separately through `enrichmentErrors`. Successful late results appear
on `profileUpdates`, allowing a UI to refresh already visible messages. Set
`enrichProfiles: false` in `KickClient.connect` to disable these requests.

The broadcaster's channel-specific 7TV set is also loaded in the background.
Set `loadExternalEmotes: false` to retain native Kick emotes only.

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

The client subscribes to `chatrooms.{id}.v2`, `chatroom_{id}`,
`chatrooms.{id}`, and `channel_{channelId}`. This is required because Kick
distributes ordinary chat, gifted subscriptions, hosted streams, goals, polls,
and lifecycle events across different public topics.
Public evolving events have dedicated types such as `KickPollUpdatedEvent`,
`KickRewardRedeemedEvent`, `KickKicksGiftedEvent`, `KickGoalEvent`,
`KickStreamHostedEvent`, and `KickLivestreamEvent`. Optional fields tolerate
the payload variants Kick has used over time, and every type preserves the
complete decoded object in `raw`. Recognized events that are not yet modeled
become `KickKnownEvent`; genuinely new names become `KickUnknownEvent`.

These types describe only events received from Kick's anonymous public Pusher
topics. Availability is controlled by Kick and can vary per channel; the
package never authenticates to fill missing data.

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
