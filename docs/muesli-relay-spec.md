# muesli-relay — Spec 2: record on a phone, hand off to Emacs

Status: draft · 2026-11-13

## 1. Summary

`muesli-relay` is a small Clojure web service plus a PWA. You log in on a
phone, record a meeting in the browser, and when you're done the recording
waits on the relay until a linked Emacs pulls it in and runs it through the
normal muesli pipeline (chunks → transcription → segments → speakers →
summary → org).

The relay only stores and forwards audio. It does not transcribe,
summarize or know about org. Everything about *how* a recording is
processed (mode, category, transcription backend, prompts) stays in the
Emacs config. The relay knows only the names of the setups Emacs offers.

```
 phone (PWA)                  muesli-relay (Clojure)              Emacs (muesli)
 ───────────                  ──────────────────────              ──────────────
 login (session cookie) ───▶  users, sessions
                              API keys  ◀── created in web UI ──  stored in auth-source
                              clients   ◀── M-x muesli-relay-link (POST profiles)
 pick client + profile  ◀───  GET /app/api/clients
 record, upload parts   ───▶  recordings/parts on disk
 finish                 ───▶  status = ready
                              GET ready recordings ◀───────────  M-x muesli-relay-fetch
                              download audio       ◀───────────  (or poll timer)
                              ack → delete audio   ◀───────────  import → existing pipeline
```

### Goals

- Record from any phone with a modern browser. No native app.
- Recordings survive bad connectivity: nothing is lost if the network drops
  mid-meeting or the upload fails.
- Emacs never has to accept inbound connections. It only makes outbound
  HTTPS calls with curl, the same way muesli already talks to transcription
  APIs. Because of this the relay can run on the same machine as Emacs or on
  a separate one.
- One interactive command links an already configured Emacs to the relay.
- Several users can have accounts. Each user can link several Emacs
  instances ("clients").

### Non-goals (v1)

- Transcription or summarization on the relay.
- Live transcription while recording.
- Multi-track capture (call/hybrid modes) from the phone. A phone gives one
  mic track.
- Push to Emacs. Emacs pulls, on command or on a timer.
- Sharing recordings between users.

## 2. Terminology

| Term | Meaning |
|---|---|
| **relay** | The Clojure service in this spec. |
| **PWA** | The installable web app served by the relay and used for recording. |
| **client** | One linked Emacs instance. It belongs to a user and authenticates with one API key. |
| **profile** | A named, preconfigured processing setup that lives in Emacs (`muesli-relay-profiles`). The relay stores only its name, label and description. |
| **recording** | One phone capture. It is assigned to a client and a profile. |
| **part** | One slice of a recording as uploaded by the PWA (sequence-numbered). |
| **meeting** | The existing muesli row (`meetings` table) a recording becomes after import. |

## 3. User flows

### 3.1 First-time setup

1. An admin creates an account (`java -jar relay.jar user add alice`), or
   the user signs up if `:signup-enabled` is true.
2. The user logs in to `https://relay.example/` and opens **API keys →
   New key**, named e.g. "laptop". The full key (`msl_…`) is shown **once**.
3. The user puts the key in `~/.authinfo.gpg`:
   `machine relay.example login muesli password msl_…`
4. In Emacs the user configures the relay URL and profiles (§6.1), then runs
   **`M-x muesli-relay-link`**.
5. Emacs registers itself as a client and uploads its profile list. The
   key is now bound to that client.
6. On the phone the user opens the relay, logs in and taps "Add to Home
   Screen". The PWA now lists "laptop" with its profiles.

### 3.2 Recording

1. Open the PWA and pick a client and profile (the last choice is
   remembered). An optional title can be entered.
2. Tap **Record**. The PWA asks for mic permission, takes a screen wake lock
   and starts the timer and level meter.
3. Audio is sliced every 5 s. Each slice goes to IndexedDB first and then
   into the upload queue (§7.2).
4. **Pause/Resume** are supported. **Stop** finalizes the recording: the
   PWA waits until all parts are uploaded and then calls `finish`.
5. The PWA shows the state: *uploading n/m* → *waiting for Emacs* →
   *delivered*.

### 3.3 Hand-off to Emacs

1. In Emacs, `M-x muesli-relay-fetch` (or the poll timer) lists the ready
   recordings for this client.
2. For each recording Emacs downloads the audio, splits it into
   `chunk_seconds` chunks with ffmpeg, creates a meeting using the profile's
   settings, registers the chunks and starts the normal pipeline.
3. Once the meeting row and its chunks are safely on disk, Emacs sends
   `ack`. The relay marks the recording `delivered` and deletes the audio
   after `:after-ack-hours` (default 0, i.e. immediately).

### 3.4 Re-linking and revocation

- Running `muesli-relay-link` again with the same key updates the client's
  name and profiles. Its id stays the same.
- Revoking a key in the web UI disables its client. Recordings that are
  ready but not yet fetched stay listed in the web UI and can be downloaded
  from there or reassigned to another client.

## 4. The relay (Clojure)

### 4.1 Stack

| Concern | Choice | Why |
|---|---|---|
| Build | `deps.edn` + `tools.build` (uberjar) | Standard and small. |
| HTTP server | `ring-jetty9-adapter` | Streams large request and response bodies without buffering them. |
| Routing | `reitit` (ring + malli coercion) | Data-driven routes with schema validation in one place. |
| Validation | `malli` | Shared schemas for API requests and responses. |
| DB | SQLite via `next.jdbc` + `xerial/sqlite-jdbc` | Matches muesli's own choice. One file, easy to self-host. Postgres is an easy later swap. |
| Migrations | `migratus` | Plain SQL files, append-only (same rule as `muesli-db--migrations`). |
| Lifecycle | `integrant` | Explicit system map for the DB, server, sweeper and config. |
| Config | `aero` (`resources/config.edn`, env overrides) | |
| Passwords | `buddy-hashers` (argon2id) | |
| Sessions/CSRF | `ring.middleware.session` (encrypted cookie store) + `ring-anti-forgery` | |
| HTML | `hiccup2` server-rendered pages for login, keys and clients | No SPA needed for account management. |
| PWA | ClojureScript via `shadow-cljs`, no UI framework (direct DOM interop), service worker written in CLJS too | Keeps the whole thing in Clojure. The recorder is a single screen. |
| Logging | `clojure.tools.logging` + logback | |
| Tests | `clojure.test` + `kaocha`, `ring-mock`, a throwaway SQLite per test | |

### 4.2 Project layout

```
relay/
  deps.edn  shadow-cljs.edn  build.clj
  resources/
    config.edn
    migrations/001-init.up.sql ...
    public/manifest.webmanifest  public/icons/...
  src/muesli/relay/
    main.clj          ; -main, integrant init, CLI dispatch
    system.clj        ; integrant keys
    config.clj
    db.clj            ; next.jdbc datasource, queries
    auth.clj          ; passwords, sessions, api-key lookup middleware
    keys.clj          ; key generation/hashing
    storage.clj       ; part files on disk, assembly, deletion
    api/client.clj    ; Emacs-facing routes (/api/v1/client/...)
    api/app.clj       ; PWA-facing JSON routes (/app/api/...)
    web/pages.clj     ; hiccup pages
    sweeper.clj       ; retention + abandoned-recording cleanup
    cli.clj           ; user add / passwd / disable / list
  src/muesli/pwa/
    core.cljs  recorder.cljs  queue.cljs  idb.cljs  sw.cljs
  test/...
```

### 4.3 Data model (SQLite)

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,           -- uuid
  username      TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  is_admin      INTEGER NOT NULL DEFAULT 0,
  disabled      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL);

CREATE TABLE api_keys (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  prefix       TEXT NOT NULL,               -- first 8 chars after msl_, shown in UI
  key_hash     TEXT NOT NULL UNIQUE,        -- sha256 hex of the full key
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at   INTEGER);

CREATE TABLE clients (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  api_key_id   TEXT NOT NULL UNIQUE REFERENCES api_keys(id),
  name         TEXT NOT NULL,               -- e.g. system-name
  profiles     TEXT NOT NULL,               -- JSON array, see §5.1
  emacs_info   TEXT,                        -- JSON: emacs-version, muesli version
  linked_at    INTEGER NOT NULL,
  last_seen_at INTEGER);

CREATE TABLE recordings (
  id           TEXT PRIMARY KEY,            -- uuid, generated by the PWA (idempotent create)
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_id    TEXT REFERENCES clients(id) ON DELETE SET NULL,
  profile      TEXT NOT NULL,
  title        TEXT,
  notes        TEXT,                        -- optional typed notes from the phone
  mime_type    TEXT NOT NULL,               -- audio/webm;codecs=opus | audio/mp4 | ...
  status       TEXT NOT NULL,               -- recording | ready | delivered | abandoned
  reject_reason TEXT,                       -- last reason Emacs gave for rejecting it
  started_at   INTEGER NOT NULL,            -- phone clock, ms
  ended_at     INTEGER,
  duration_ms  INTEGER,
  part_count   INTEGER,                     -- set by finish
  bytes        INTEGER NOT NULL DEFAULT 0,
  sha256       TEXT,                        -- of the assembled file
  delivered_at INTEGER,
  meeting_id   TEXT,                        -- muesli meeting id reported in ack
  created_at   INTEGER NOT NULL);

CREATE TABLE recording_parts (
  recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,
  bytes        INTEGER NOT NULL,
  sha256       TEXT NOT NULL,
  received_at  INTEGER NOT NULL,
  PRIMARY KEY (recording_id, seq));

CREATE INDEX recordings_client_status ON recordings(client_id, status);
```

The audio lives on disk under
`<storage-dir>/<user-id>/<recording-id>/parts/<seq>.bin`. Parts are written
to a temp file and renamed into place, so a half-written part is never
visible. On `finish` the relay concatenates the parts in `seq` order into
`audio.<ext>`, records the size and sha256, and deletes the parts.

### 4.4 Recording state machine

```
           create            finish (all parts present)       ack
 (none) ──────────▶ recording ─────────────────────────▶ ready ─────▶ delivered
                       │                                  ▲ │       (audio deleted)
                       │ no new part for 24h        reject│ │
                       ▼                                  └─┘
                   abandoned  (kept, visible in web UI, can still be finished manually)
```

`finish` is rejected with `409` if any `seq` in `0..part_count-1` is
missing. The response lists the missing seqs so the PWA can re-send them.
`reject` leaves the recording `ready` and stores `reject_reason`. A
rejected recording is left out of the client's `ready` list until the user
reassigns it or changes its profile in the web UI, so Emacs doesn't keep
rejecting the same one.

### 4.5 Configuration (`config.edn`)

```clojure
{:http      {:host "127.0.0.1" :port 8787}
 :base-url  #or [#env RELAY_BASE_URL "http://localhost:8787"]
 :behind-proxy true
 :db        {:file #or [#env RELAY_DB "data/relay.sqlite"]}
 :storage   {:dir #or [#env RELAY_STORAGE "data/audio"]
             :max-part-bytes 4194304          ; 4 MiB
             :max-recording-bytes 1073741824} ; 1 GiB
 :session   {:secret #env RELAY_SESSION_SECRET :max-age-days 30}
 :signup-enabled false
 :retention {:after-ack-hours 0 :abandon-after-hours 24 :purge-abandoned-days 14}}
```

## 5. Interfaces

All JSON. Timestamps are epoch milliseconds. Errors use the shape
`{"error": {"code": "...", "message": "..."}}` with a matching HTTP status.

### 5.1 Emacs-facing API (`/api/v1/client`, Bearer API key)

The middleware hashes the bearer token, looks up a non-revoked key for a
non-disabled user, loads its client, and updates
`last_used_at`/`last_seen_at`. Every route except `link` returns `412
not_linked` if the key has no client yet.

| Method & path | Purpose |
|---|---|
| `POST /api/v1/client/link` | Create or update the client bound to this key. Body: `{"name": "laptop", "profiles": [Profile], "emacs": {"version": "30.1", "muesli": "0.3"}}`. Returns `{"client_id": "...", "user": "alice"}`. |
| `GET /api/v1/client/recordings?status=ready` | List recordings for this client. Returns `[{"id", "profile", "title", "notes", "mime_type", "duration_ms", "bytes", "sha256", "started_at", "ended_at"}]`. |
| `GET /api/v1/client/recordings/:id/audio` | Stream the assembled file. Supports `Range` so interrupted downloads can resume. |
| `POST /api/v1/client/recordings/:id/ack` | Body `{"meeting_id": "..."}`. Moves the recording to `delivered`. Idempotent. |
| `POST /api/v1/client/recordings/:id/reject` | Body `{"reason": "..."}`. See §4.4. |
| `GET /api/v1/client/ping` | Returns `{"client_id", "user", "pending": n}`. Cheap enough for a timer. |

**Profile** (sent by Emacs, displayed by the PWA):

```json
{"name": "standup", "label": "Daily standup", "description": "room · work"}
```

Only `name` matters for routing. The PWA shows `label` and `description`.
Their meaning lives in Emacs.

Only `POST` and `GET` are used, so the API can be called with muesli's
existing curl wrapper once it supports GET and `--output` (§6.4).

### 5.2 PWA-facing API (`/app/api`, session cookie + CSRF header)

| Method & path | Purpose |
|---|---|
| `GET /app/api/clients` | `[{"id", "name", "profiles", "last_seen_at"}]` for the logged-in user. |
| `PUT /app/api/recordings/:id` | Create a recording. The id comes from the PWA, so retries are safe. Body: `{"client_id", "profile", "title", "mime_type", "started_at"}`. Returns `409` if the id exists under a different user. |
| `PUT /app/api/recordings/:id/parts/:seq` | Raw body = part bytes, header `X-Part-SHA256`. Idempotent: the same seq with the same hash returns `200`, a different hash returns `409`. |
| `POST /app/api/recordings/:id/finish` | Body `{"part_count", "ended_at", "duration_ms", "notes"}`. Assembles the file → `ready`. Returns `409` with `{"missing": [..]}` if parts are missing. |
| `GET /app/api/recordings` | The user's recent recordings with status, for the "history" list. |
| `PATCH /app/api/recordings/:id` | Change `client_id`, `profile` or `title` of a recording that has not been delivered. This clears `reject_reason`. |
| `DELETE /app/api/recordings/:id` | Discard a recording that has not been delivered. |

### 5.3 Web pages (hiccup, session)

`/login`, `/logout`, `/` (recorder PWA shell), `/keys` (list, create, revoke),
`/clients` (list, rename, unlink, reassign recordings), `/recordings`
(history, manual download of undelivered audio), `/admin/users` (admins
only).

## 6. Emacs side (`muesli-relay.el`)

A new module that depends only on `muesli-core`, `muesli-db` and the
existing pipeline entry point used for finished local recordings.

### 6.1 Customization

```elisp
(defcustom muesli-relay-url nil
  "Base URL of the muesli-relay server, e.g. \"https://relay.example\"."
  :type '(choice (const nil) string)
  :group 'muesli)

(defcustom muesli-relay-api-key #'muesli-relay--auth-source-key
  "API key for the relay: a string, or a function returning one.
Resolved with `muesli--resolve-secret'.  The default looks up
login \"muesli\" for the relay's host in `auth-source'."
  :type '(choice string function)
  :group 'muesli)

(defcustom muesli-relay-client-name (system-name)
  "Name this Emacs shows up under in the PWA."
  :type 'string
  :group 'muesli)

(defcustom muesli-relay-profiles
  '((default :label "Meeting" :mode room)
    (standup :label "Daily standup" :mode room :category "work"
             :title "Standup %F"))
  "Setups offered to the phone.  Each entry is (NAME . PLIST).
Recognized keys: :label, :description, :mode, :category, :title
\(a `format-time-string' template used when the phone sends no title),
:hook (a function called with the new meeting id after import), and
:let, a list of (VARIABLE . VALUE) bound dynamically around the
import and pipeline start, so any muesli variable (transcription
backend, language, summary prompt...) can be set per profile."
  :type '(alist :key-type symbol :value-type plist)
  :group 'muesli)

(defcustom muesli-relay-poll-interval nil
  "Seconds between automatic fetches, or nil to fetch only on command."
  :type '(choice (const nil) integer)
  :group 'muesli)

(defcustom muesli-relay-keep-original nil
  "When non-nil, keep the downloaded file after chunking it."
  :type 'boolean
  :group 'muesli)
```

### 6.2 Commands

- **`muesli-relay-link`**: the command from step 4 of §3.1. It checks that
  `muesli-relay-url` and the key resolve, then POSTs `link` with the
  profiles (name, plus a label and a description derived from
  `:mode`/`:category` when not given). It stores the returned `client_id` in
  `muesli-data-directory/relay.eld` and reports
  `Linked "laptop" to relay.example as alice (2 profiles)`. If
  `muesli-relay-poll-interval` is set, it also starts the poll timer.
  It is safe to rerun after editing profiles.
- **`muesli-relay-fetch`**: pulls all ready recordings and imports them
  (§6.3). It reports `Imported 2 recordings; 1 rejected (unknown profile
  "retro")`.
- **`muesli-relay-unlink`**: deletes the local `relay.eld` and stops the
  timer. Revoking the key is done on the web side.
- **`muesli-relay-status`**: shows the link, the pending count (via `ping`)
  and the last fetch result.

### 6.3 Import algorithm

For each ready recording, sequentially:

1. **Dedup**: if `relay_imports` already has `remote_id`, just re-send
   `ack` and skip. This covers a crash between import and ack.
2. **Resolve profile**: if `profile` is not in `muesli-relay-profiles`,
   call `reject` with a reason and continue.
3. **Download** to `<audio_dir>/relay-<id>.<ext>` with curl `--output`
   and `-C -`. Verify size and sha256 (`secure-hash` on the file); on
   mismatch, delete the file and retry once.
4. **Chunk**: run ffmpeg to segment the file into
   `chunk_seconds` pieces in the same format and naming that local recording
   produces (`-f segment -segment_time N -c:a <codec> …`).
5. **Create meeting**: in one SQLite transaction:
   - call `muesli-db-meeting-create` with a fresh muesli meeting id,
     `:mode` and `:category` from the profile, `:title` from the phone or
     the profile template, `:notes_raw` from the phone's notes,
     `:started_at` / `:ended_at` from the recording, `:status` set to the
     pipeline's "recorded, awaiting transcription" status, `:audio_dir` and
     `:chunk_seconds`;
   - call `muesli-db-chunk-add` for each piece on the track name that the
     room-mode recorder uses;
   - insert the `relay_imports` row.
6. **Ack**, then hand the meeting to the pipeline (the same function that
   runs when a local recording is stopped), then run the profile's
   `:hook`.

Everything runs asynchronously through `muesli--run`/`muesli--curl`. Emacs
never blocks on the network. The downloaded original is deleted after
chunking unless `muesli-relay-keep-original` is non-nil. A fetch that is
already running makes a second `muesli-relay-fetch` (or timer tick) a no-op.

### 6.4 Changes to existing modules

- **`muesli-core.el`**: `muesli--curl` gains `:method` (default `"POST"`)
  and `:output-file` (adds `--output FILE -C -`; the body is then not read
  into memory). The bearer token stays in the private config file as it is
  now.
- **`muesli-db.el`**: append migration 2. Released migrations are never
  edited.

  ```elisp
  (2
   "CREATE TABLE relay_imports (
      remote_id   TEXT PRIMARY KEY,
      meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
      relay_url   TEXT NOT NULL,
      profile     TEXT NOT NULL,
      imported_at INTEGER NOT NULL,
      acked_at    INTEGER)")
  ```

  Add helpers `muesli-db-relay-import-add`, `muesli-db-relay-import` and
  `muesli-db-relay-import-mark-acked`.
- The meeting buffer and list show a "relay" origin marker when a
  `relay_imports` row exists (optional, cosmetic).

## 7. The PWA

### 7.1 Capture

- `getUserMedia({audio: {echoCancellation: false, noiseSuppression: false,
  autoGainControl: true, channelCount: 1}})`. Turning off processing gives
  better audio for a room recording. This should be revisited after real
  tests.
- `MediaRecorder` with the first supported type from
  `audio/webm;codecs=opus` (Chrome/Firefox/Android) and `audio/mp4`
  (Safari/iOS). Bitrate 32 kbps (`audioBitsPerSecond`), about 14 MB/hour.
- `start(5000)`: every `dataavailable` blob becomes part `seq`. The slices
  form one continuous stream, so byte-concatenating them on the server gives
  a valid file. The relay needs no ffmpeg, and Emacs does the real
  segmentation.
- Pause/resume use `MediaRecorder.pause()/resume()`, which keeps a single
  stream.
- The PWA takes a Wake Lock (`navigator.wakeLock.request("screen")`) while
  recording and warns that locking the phone or switching apps can stop
  capture, especially on iOS.
- An optional notes field during recording; its text is sent with
  `finish` and becomes the meeting's `notes_raw`.

### 7.2 Durability

- Each blob is written to IndexedDB as `{recording_id, seq, blob, sha256,
  uploaded: false}` **before** the upload is attempted.
- The upload queue sends parts with bounded concurrency (2) and
  exponential backoff. It resumes on the `online` event, on app start and
  from a Background Sync registration where supported.
- On Stop: flush the final blob, wait for the queue to drain, then call
  `finish`. If `finish` returns missing seqs, re-queue them from
  IndexedDB.
- Local blobs are deleted only after `finish` succeeds. If the app is
  killed mid-recording, the next launch shows "Unfinished recording, 23 min:
  upload & finish / discard".
- The PWA requests `navigator.storage.persist()` so the browser does not
  evict pending audio.

### 7.3 Service worker

It caches the app shell (cache-first, versioned) so the recorder opens
offline. API calls are never cached. A web manifest with icons, standalone
display and a theme color makes the app installable.

### 7.4 Screens

1. **Record**: client/profile pickers, title field, big record button,
   timer, level meter, upload indicator, notes field.
2. **History**: recent recordings with status chips (uploading · waiting
   for Emacs · delivered · rejected: reason), with reassign/discard actions.
3. **Settings**: log out, link to the key management page.

## 8. Security

- **API keys**: `msl_` + 32 random bytes, base32-encoded. Only the sha256 is
  stored, which is enough for a 256-bit random secret, and lookup is a
  unique-index hit. The key is shown once. Each key belongs to at most one
  client, and revoking it cuts off that client immediately.
- **Passwords**: argon2id via buddy-hashers. Login is rate-limited per IP
  and per username (in-memory token bucket). The same error is returned for
  an unknown user and a wrong password.
- **Sessions**: an encrypted cookie that is `HttpOnly`, `Secure` and
  `SameSite=Lax`. CSRF tokens on forms and on PWA JSON calls
  (`X-CSRF-Token`).
- **Isolation**: every query is scoped by `user_id`. Client routes are also
  scoped by `client_id`. A recording can be fetched only by the client it is
  assigned to.
- **Limits**: per-part and per-recording byte caps are enforced while
  streaming (no buffering of unbounded bodies). `mime_type` is checked
  against an allowlist. Ids in paths must be UUIDs and `seq` must be a
  non-negative integer below a cap, so no path is ever built from free text.
- **Transport**: `getUserMedia` and service workers need HTTPS. The relay
  speaks plain HTTP on localhost and is meant to sit behind Caddy, nginx or
  `tailscale serve`, which terminate TLS. The relay trusts
  `X-Forwarded-Proto` only when `:behind-proxy true`.
- **Emacs**: the API key never touches the command line or the log. It goes
  through `muesli--resolve-secret` and the curl config file, as it does now.

## 9. Deployment

- **Same machine as Emacs**: run the uberjar as a systemd user service.
  Expose it to the phone over a tailnet with `tailscale serve --https=443
  8787` or a LAN reverse proxy with a real certificate. Emacs points
  `muesli-relay-url` at the same public URL (or at `http://127.0.0.1:8787`,
  see §10.3).
- **Separate machine / VPS**: run the uberjar or Docker image
  (`eclipse-temurin:21-jre`) behind Caddy. Back up the volume holding
  `data/`.
- **Admin CLI**: `java -jar relay.jar user add|passwd|disable|list`.

## 10. Open questions

1. **Track name and status names.** The recorder and pipeline modules are
   not in this repo yet. §6.3 assumes a single room-mode track and an
   "awaiting transcription" meeting status. These need to match whatever
   they actually use.
2. **iOS fragmented MP4.** Safari's `MediaRecorder` timeslice output should
   concatenate into a playable fMP4. This needs a test on a real device. The
   fallback is to stop and restart the recorder every N seconds and upload
   self-contained files, with Emacs concatenating them via ffmpeg's concat
   demuxer.
3. **Loopback shortcut.** When relay and Emacs share a host, should the
   client API also accept plain HTTP on 127.0.0.1? Proposal: yes, but only
   for `/api/v1/client/*`.
4. **Notify instead of poll.** v2 could add `GET
   /api/v1/client/wait?timeout=30` (long-poll) so a timer gets near-instant
   delivery without hammering the server.
5. **Encryption at rest.** Audio sits on the relay until it is acked.
   Optionally the PWA could encrypt to a client public key uploaded at link
   time, so the relay only ever holds ciphertext.

## 11. Milestones

1. **Relay skeleton**: config, DB, migrations, users CLI, login, API keys
   page, `link` and `ping`. Emacs gets `muesli-relay-link` and
   `muesli-relay-status`, plus the `muesli--curl` `:method` change.
2. **Upload path**: recording create, parts, finish and assembly. A minimal
   recorder page without offline support.
3. **Hand-off**: list, audio download with Range, ack and reject. Emacs
   gets `muesli-relay-fetch`, migration 2, ffmpeg chunking and the pipeline
   call.
4. **Durability & PWA polish**: IndexedDB queue, resume after a kill,
   service worker, manifest, wake lock, history screen, reassign.
5. **Hardening**: rate limits, sweeper, byte caps, iOS testing, docs for the
   Caddy and Tailscale setups.
