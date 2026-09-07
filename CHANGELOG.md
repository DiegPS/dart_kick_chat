## 0.5.0

- Add anonymous channel-specific 7TV emotes using Kick's public user ID.
- Add optional non-blocking avatar enrichment with request deduplication,
  bounded concurrency, timeouts, and an LRU cache.
- Expose profile updates and separate optional-enrichment errors without
  changing chat connection state.

## 0.4.0

- Added typed anonymous models for polls, rewards, KICK gifts, creator goals,
  hosts, livestream lifecycle, and chat migration events.
- Expanded public sender parsing for alternate IDs, slugs, avatars, display
  names, and username colors used by evolving Kick payloads.
- Preserved every original event field while exposing stable optional values.
- Added regression coverage based on a captured public `KicksGifted` payload,
  partial payloads, unsafe gift IDs, and every modeled lifecycle transition.

## 0.3.0

- Added complete anonymous channel, livestream, chatroom, and initial-history
  models with injectable HTTP transport.
- Added typed modern badges, reply references, message metadata, and stable raw
  payload fallbacks.
- Added a realtime event stream for moderation, subscriptions, gifts, pins,
  polls, rewards, hosts, goals, and future event types.
- Subscribed to all three public chat topics and preserved reconnection and
  de-duplication behavior.
- Added a privacy-safe live surface inspector and expanded regression tests.

## 0.2.0

- Added injectable HTTP and WebSocket transports.
- Added typed channel lookup and protocol exceptions.
- Added connection and request timeouts.
- Added automatic reconnection, re-subscription, and message deduplication.
- Removed raw response, identity, and chat-content logging.
- Added parser, fallback, lifecycle, timeout, corruption, and reconnect tests.

## 0.1.0

- Initial anonymous Kick chat client.
