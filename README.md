# The Oracle

The Oracle is a YouTube Live Chat bot written in [Odin](https://odin-lang.org/).
It is named after the Oracle at Camp Half-Blood: the mummified body in the attic which gives prophecies, except this one replies in a live chat.

The bot responds to the `!oracle` prefix and moderates chat using a local
SQLite word list plus a rolling spam detector.

## Commands

| Command | Response |
| --- | --- |
| `!oracle github` | `https://swarn.space/github` |
| `!oracle twitter` | `https://swarn.space/twitter` |
| `!oracle help` | Lists the commands |

The prefix and both links are configurable. A bare `!oracle` is treated as
`help`.

## Moderation

Two independent checks run before command handling:

1. **Offensive words** are looked up in `offensive.db` (SQLite). Matching
   messages are deleted. Matching is case-insensitive and normalizes common
   leetspeak (`1d10t` matches `idiot`) and punctuation, while still respecting
   word boundaries (`class` does not match `ass`). Single words and phrases are
   supported.
2. **Spam** is detected when the same user sends the same normalized message
   `spam_threshold` times inside `spam_window_seconds`. The default is 10
   identical messages in 120 seconds. When the threshold is reached the user
   is timed out for `timeout_seconds` using a temporary live-chat ban.

Moderators and the channel owner are exempt by default. The bot ignores its own
messages (it discovers the bot account's channel id from OAuth when possible).

Both actions require the authorized account to be a moderator (or owner) of
the live chat. If the bot is not a moderator, YouTube returns `403` and the
action is only logged.

### Managing `offensive.db`

The repository includes a starter database created from
[`tools/offensive.example.txt`](tools/offensive.example.txt). Use your own list
for your community.

```sh
# Create the schema (safe to run on an existing database).
./oracle db init offensive.db

# Import one word/phrase per line. "word|2" sets severity.
./oracle db import tools/offensive.example.txt offensive.db

# Inspect the database.
./oracle db list offensive.db
```

Schema:

```sql
CREATE TABLE offensive_words (
    word     TEXT PRIMARY KEY COLLATE NOCASE,
    severity INTEGER NOT NULL DEFAULT 1 CHECK (severity >= 1),
    added_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

The current moderation policy deletes every offensive match; `severity` is
stored so future policies can distinguish levels.

## Requirements

- Odin `dev-2026-10` or newer
- `libcurl` (headers are not needed; Odin links the system library)
- `libsqlite3`
- A Google Cloud project with the **YouTube Data API v3** enabled

On Arch Linux the runtime packages are normally already present; for building on
a minimal system install `curl` and `sqlite`.

## Build

```sh
./build.sh
```

`build.sh` is the single build entry point. It compiles a release build and
passes `-show-timings` to Odin. Extra arguments are forwarded, so
`./build.sh -debug` produces a debug build.

Run the tests with:

```sh
odin test .
```

## Setup

### 1. Create Google credentials

1. Open the [Google Cloud Console](https://console.cloud.google.com/).
2. Create or select a project.
3. Enable **YouTube Data API v3** under *APIs & Services → Library*.
4. Create an **API key** under *APIs & Services → Credentials*. Restrict it to
   the YouTube Data API.
5. Create an **OAuth client ID**:
   - Application type: **Desktop app**
   - Name it something like `The Oracle`
6. Configure the OAuth consent screen. For a personal bot, add your Google
   account as a test user. Note that refresh tokens issued by an app in
   "Testing" mode expire after 7 days; publish the app if you want a durable
   token.

The OAuth flow uses the loopback redirect `http://127.0.0.1:8765`. Desktop OAuth
clients accept loopback redirects without pre-registering every port. If Google
asks for a redirect URI, add `http://127.0.0.1:8765`.

### 2. Configure the bot

```sh
cp config.example.json config.json
```

Edit `config.json`:

```json
{
  "youtube": {
    "api_key": "AIza...",
    "client_id": "....apps.googleusercontent.com",
    "client_secret": "GOCSPX-...",
    "refresh_token": "",
    "live_chat_id": "",
    "video_id": "",
    "channel_id": "UC...",
    "bot_channel_id": ""
  }
}
```

At least one of `live_chat_id`, `video_id`, or `channel_id` is required. The
first one that is set wins:

- `live_chat_id` — a specific live chat id (advanced; the chat id changes when
  a stream restarts).
- `video_id` — the current stream's video id. The bot resolves its active live
  chat with `videos.list` (about 1 quota unit, checked when connecting).
- `channel_id` — the **target streamer's** channel id. The bot reads the
  channel's uploads playlist and checks recent videos for an active live chat.
  This is the most convenient option for recurring streams and is inexpensive
  (`channels.list` once, then `playlistItems.list` and `videos.list` while
  waiting). The bot waits for a stream to start and reconnects when a chat ends.

`bot_channel_id` is optional. Leave it empty and the bot will query
`channels.list?mine=true` with OAuth to avoid reacting to its own messages.
`channel_id` is the streamer being watched; `bot_channel_id` is the account that
posts the replies. They can be the same account or different accounts.

Other important settings:

| Key | Default | Meaning |
| --- | --- | --- |
| `bot.prefix` | `!oracle` | Chat command prefix |
| `bot.dry_run` | `false` | Log actions instead of calling YouTube |
| `bot.reply_cooldown_seconds` | `10` | Minimum time between identical command replies |
| `moderation.enabled` | `true` | Turn both moderation checks on/off |
| `moderation.delete_offensive` | `true` | Delete messages that match the word list |
| `moderation.spam_threshold` | `10` | Identical messages before a timeout |
| `moderation.spam_window_seconds` | `120` | Window used for identical messages |
| `moderation.timeout_seconds` | `600` | Temporary ban duration |
| `moderation.exempt_moderators` | `true` | Do not moderate owners/mods |
| `poll.idle_seconds` | `60` | Delay while waiting for a live chat |
| `poll.min_interval_ms` | `10000` | Minimum chat poll interval |
| `poll.max_backoff_seconds` | `300` | Maximum retry delay after errors |

Environment variables override values from the file, which is useful for
secrets:

```
YOUTUBE_API_KEY
YOUTUBE_CLIENT_ID
YOUTUBE_CLIENT_SECRET
YOUTUBE_REFRESH_TOKEN
YOUTUBE_LIVE_CHAT_ID
YOUTUBE_VIDEO_ID
YOUTUBE_CHANNEL_ID
YOUTUBE_BOT_CHANNEL_ID
ORACLE_OFFENSIVE_DB
```

### 3. Authorize the bot

```sh
./oracle auth --config config.json
```

Open the printed URL while signed in as the **bot account**, approve the
permission, then paste the full `http://127.0.0.1:8765/?code=...` URL back into
the terminal. The command prints a `refresh_token`; put it into
`youtube.refresh_token` in `config.json`.

Keep `config.json` and the refresh token secret. It can post and moderate on
behalf of the authorized account.

### 4. Make the bot a moderator

On the target channel, add the bot account as a moderator for the live chat.
Deleting messages and timing out users will fail without moderator privileges.

### 5. Check and run

```sh
./oracle check --config config.json
./oracle run --config config.json
```

`check` validates the config, prints a redacted summary, and verifies that the
offensive database can be read.

To try actions without touching YouTube:

```sh
./oracle run --config config.json --dry-run
./oracle simulate --config config.json
```

`simulate` reads from stdin. Plain lines are treated as messages from `viewer`;
use `author|message` to change the author:

```
alice|!oracle github
bob|what the fuck
alice|same message
alice|same message
...
```

## Quota notes

YouTube Data API projects get 10,000 units per day by default. `liveChatMessages.list`
costs about 5 units per call, so fast polling can exhaust a project in a few
hours. The Oracle therefore defaults to a **10 second minimum poll interval**.
For a typical three-hour stream that is roughly 1,000 list calls, plus the
occasional reply or moderation action. If you have more quota (or a shorter
stream) you can lower `poll.min_interval_ms`, but watch the quota page in the
Cloud Console.

Channel auto-discovery is intentionally based on the uploads playlist rather
than `search.list`; it costs a couple of units per attempt instead of a search
call.

## How it works

| File | Responsibility |
| --- | --- |
| `main.odin` | CLI, configuration loading, dispatch |
| `config.odin` | Config schema, defaults, environment overrides |
| `http.odin` | Small synchronous libcurl wrapper |
| `youtube.odin` | OAuth refresh, live chat discovery, list/send/delete/ban |
| `bot.odin` | Polling loop and message handling |
| `commands.odin` | Command registry, parsing, cooldowns |
| `moderation.odin` | Normalization, offensive-word matching, spam tracking |
| `sqlite.odin` | Minimal SQLite bindings |
| `db_tools.odin` | `db init`, `db import`, `db list`, `db check` |
| `auth.odin` | OAuth authorization-code helper |
| `simulate.odin` | Offline dry-run harness |
| `tests.odin` | Unit tests for parsing, matching, spam, and cooldowns |

The bot is single-threaded: one poll, process the batch, sleep. Replies and
moderation actions happen inline. This keeps the state machine small and makes
a stream bot's behavior predictable.

## Troubleshooting

- **`HTTP 403` when sending/deleting/banning** — the authorized account is not a
  moderator of that live chat, the OAuth token lacks `youtube.force-ssl`, or the
  daily quota is exhausted.
- **`HTTP 404` / "live chat is no longer available"** — the stream ended or the
  chat id became invalid. With `channel_id` configured the bot looks for the
  next live stream; with a fixed `live_chat_id` it cannot find a new one.
- **No live chat found** — check `channel_id` (target channel), make sure the
  stream is public (unlisted streams may not appear in the uploads playlist),
  or switch to `video_id` / `live_chat_id`.
- **OAuth returns no refresh token** — revoke the app's access in your Google
  account and run `./oracle auth` again. Google only returns a refresh token on
  a fresh consent (the helper uses `prompt=consent`).
- **Refresh token dies after a week** — the OAuth app is in "Testing" mode.
  Publish it or use an account/project configured for long-lived tokens.
- **Database warning at startup** — run `./oracle db init offensive.db` and
  import a word list. The bot continues with spam detection even if the word
  list is missing.
- **Build can't find curl/sqlite** — install the system development libraries;
  Odin links `system:curl` and `system:sqlite3`.
