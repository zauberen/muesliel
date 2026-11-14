# muesli-relay — Spec 3: the relay transcribes, Emacs summarizes

Status: implemented · 2026-11-14 · builds on Spec 2 (`muesli-relay-spec.md`)

## 1. Summary

Spec 2 made the relay a pure store-and-forward box: Emacs downloaded the
phone's audio, cut it with ffmpeg, and ran speech-to-text and diarization
itself. Spec 3 moves the whole **transcript** to the relay. Emacs keeps only
the parts that need your notes and your judgment: naming speakers,
summarizing, and writing the org heading.

```
 phone (PWA)                 muesli-relay                          Emacs
 ───────────                 ────────────                          ─────
                             recording "waiting"  ◀── POST ──────  M-x muesli-start  (source: phone)
 "Emacs is waiting: Standup" ◀── GET sessions
 tap Record, upload parts ─▶ ffmpeg → 30 s WAV chunks              you type notes in the heading
                             STT per chunk → segments ── GET ───▶  live transcript (polled)
 stop (or Emacs asks) ◀───── stop_requested  ◀──────── POST stop   M-x muesli-stop
                             finish → last chunks, diarize
                             status "transcribed"     ── GET ───▶  segments + speaker labels
                                                       ◀── ack ──  name speakers, summarize, org
```

Because Emacs no longer touches audio, a phone-backed meeting needs only
`curl`, SQLite and an LLM on the Emacs side. That is what makes muesli usable
on **Windows** (and on any machine without PipeWire/ffmpeg).

### Goals

- Start the meeting from the org heading in Emacs, record on the phone, type
  notes in Emacs. The phone recording is bound to that heading.
- The transcript grows during the meeting (as with local recordings), so
  little work is left after stop.
- Emacs needs no ffmpeg, no audio device and no STT server for phone
  meetings. Local recording on Linux keeps working unchanged.
- Phone-first recordings (Spec 2 flow) keep working, now transcribed by the
  relay as well.

### Non-goals

- Summarizing on the relay. The LLM, the prompts and the notes stay with
  Emacs.
- Speaker naming on the relay. Emacs does it with the existing prompt.
- Multi-track (call/hybrid) phone capture. Phone meetings are `room` mode.

## 2. What changes from Spec 2

| Area | Spec 2 | Spec 3 |
|---|---|---|
| Who starts a recording | the phone | Emacs (`muesli-start`) or the phone |
| ffmpeg, STT, diarization | Emacs | relay |
| What Emacs downloads | the audio file | segments (JSON) |
| Recording statuses | recording → ready → delivered | waiting → recording → processing → transcribed → delivered (+ failed, abandoned) |
| Audio on the relay | until ack | until ack (then deleted with the transcript, per retention) |

Auth, API keys, clients, profiles, the upload protocol, part durability and
the service worker are unchanged (Spec 2 §4–§8).

## 3. User flows

### 3.1 Emacs-started meeting (primary)

1. With point in a meeting heading, `M-x muesli-start`. If
   `muesli-recording-source` is `phone` (the default on Windows), or with
   `C-u C-u`, Emacs creates a **waiting** recording on the relay (id, title,
   expected speaker count from `ATTENDEES`). The mode line shows
   `• REC waiting for phone`.
2. The PWA's record screen shows a banner, *laptop is waiting: Standup*, with
   a **Record** button. The PWA polls for waiting sessions every 5 s while it
   is visible and idle.
3. Recording on the phone works as in Spec 2 (5 s parts, IndexedDB first,
   retrying upload queue). The relay feeds the parts in order into an ffmpeg
   process that writes 30 s WAV chunks, and transcribes each finished chunk.
4. Emacs polls the recording every `muesli-relay-live-interval` seconds,
   pulls new segments into its database, keeps the mode line clock in step
   with the phone, and refreshes `muesli-show-transcript`.
5. Stop from either side:
   - Emacs: `M-x muesli-stop` asks the relay to stop. The next part-upload
     reply carries `stop_requested: true` and the phone stops. If the phone
     has not uploaded anything for `:phone-gone-seconds` (default 60), the
     relay finishes the recording itself with the parts it has.
   - Phone: tapping Stop finishes as before.
6. The relay finishes the last chunks, diarizes the whole recording (when
   configured) and marks it **transcribed**.
7. Emacs replaces its live segments with the final, speaker-labelled ones,
   acks, and continues with the normal pipeline: speaker naming →
   summarizing → done.

`M-x muesli-abort` deletes the remote recording. A waiting recording that no
phone picks up is abandoned after `:abandon-after-hours`.

### 3.2 Phone-started recording

As in Spec 2 §3.2, except that the relay transcribes the recording after
finish. `muesli-relay-fetch` (or the poll timer) lists **transcribed**
phone-origin recordings, creates the heading from the profile, stores the
segments and starts the pipeline at the naming step.

### 3.3 Failures

- A chunk that fails `:max-attempts` times stays failed. When the recording
  is finished and only failed chunks remain, its status becomes `failed`
  (`failed_step: "transcribing"`). Emacs asks, as it does locally:
  **retry** (`POST retry`), **proceed** (`POST retry {skip: true}`, continue
  without them) or **later** (`muesli-resume`).
- A diarization error gives `failed_step: "diarizing"`. Retrying runs it
  again; skipping finishes the recording without speaker labels.
- Emacs restarting during a phone meeting: the orphan check resumes polling
  instead of looking for chunks on disk. While the relay still says
  `recording`, Emacs is put back in the recording state.

## 4. The relay

### 4.1 Configuration additions

```clojure
:ffmpeg #or [#env RELAY_FFMPEG "ffmpeg"]
:transcription {:base-url #or [#env RELAY_STT_URL "http://localhost:8080/v1"]
                :model #or [#env RELAY_STT_MODEL "parakeet-tdt-0.6b-v3"]
                :api-key #env RELAY_STT_API_KEY
                :language nil :extra-fields {}
                :chunk-seconds 30 :concurrency 1
                :max-attempts 4 :retry-delay-seconds 5 :timeout-seconds 600}
:diarization {:backend #keyword #or [#env RELAY_DIARIZATION "none"] ; none | localai | diarized-json
              :base-url nil                 ; nil: same as :transcription
              :model "parakeet-cpp-nemotron-3-diarization"
              :api-key nil :split-threshold 0.3 :timeout-seconds 3600}
:recording {:phone-gone-seconds 60}
```

These mirror the Emacs variables of the same name (`muesli-stt-*`,
`muesli-diarization-*`). The relay speaks the same OpenAI-compatible
`/audio/transcriptions` and LocalAI `/audio/diarization` APIs.

### 4.2 Schema (migration 2)

```sql
ALTER TABLE recordings ADD COLUMN origin TEXT NOT NULL DEFAULT 'phone';  -- phone | emacs
ALTER TABLE recordings ADD COLUMN speakers INTEGER;             -- expected speaker count
ALTER TABLE recordings ADD COLUMN stop_requested INTEGER NOT NULL DEFAULT 0;
ALTER TABLE recordings ADD COLUMN chunks_complete INTEGER NOT NULL DEFAULT 0;
ALTER TABLE recordings ADD COLUMN failed_step TEXT;
ALTER TABLE recordings ADD COLUMN error TEXT;
UPDATE recordings SET status = 'processing' WHERE status = 'ready';

CREATE TABLE chunks (
  recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
  chunk_no     INTEGER NOT NULL,
  path         TEXT NOT NULL,
  status       TEXT NOT NULL,        -- pending | uploading | done | failed
  attempts     INTEGER NOT NULL DEFAULT 0,
  not_before   INTEGER NOT NULL DEFAULT 0,
  offset_ms    INTEGER NOT NULL,
  duration_ms  INTEGER NOT NULL,
  error        TEXT,
  PRIMARY KEY (recording_id, chunk_no));

CREATE TABLE segments (
  id           INTEGER PRIMARY KEY,
  recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
  chunk_no     INTEGER NOT NULL,
  start_ms     INTEGER NOT NULL,     -- from the start of the recording
  end_ms       INTEGER NOT NULL,
  speaker      TEXT,                 -- "mic:SPEAKER_00" after diarization
  text         TEXT NOT NULL,
  words        TEXT);                -- JSON [[start_ms, end_ms, word], ...]
CREATE INDEX segments_recording ON segments(recording_id, id);
```

`recordings.profile` stays `NOT NULL`. Emacs-origin rows store `""`.

### 4.3 State machine

```
        Emacs POST                   phone PUT (claim)
 (none) ─────────▶ waiting ────────────────────────▶ recording ──finish / phone gone──▶ processing
                     │                                   │                                 │  ▲
                     │ no phone for 24 h                 │ no part for 24 h        failed  │  │ retry
                     ▼                                   ▼                                 ▼  │
                 abandoned                           abandoned                           failed
                                                                                           │
                         processing ── all chunks done, diarized ──▶ transcribed ── ack ──▶ delivered
```

### 4.4 Processing pipeline (`muesli.relay.pipeline`)

- **Segmenter** (one per recording that is receiving parts): `ffmpeg -i
  pipe:0 … -f segment -segment_time 30 chunks-<gen>/mic-%05d.wav` (16 kHz
  mono s16, as `muesli-record-ffmpeg`). After every committed part, the
  contiguous run of parts from `next-seq` is written to its stdin. Every
  chunk except the newest is complete. Once stdin is closed and ffmpeg has
  exited, all of them are. Complete chunks get a `chunks` row. Their offset
  is the sum of the previous chunks' WAV durations, and their duration comes
  from the WAV header.
- **Recovery**: the segmenter lives in memory. After a relay restart the
  next part (or the processing tick, for a finished recording) starts a new
  generation that re-feeds every part from 0 into a fresh `chunks-<gen>`
  directory and registers only chunk numbers not yet known. Part files are
  kept until the chunks are complete, so this is always possible.
- **Finish**: feed the rest, close stdin, wait for ffmpeg, register the last
  chunks, assemble `audio.<ext>` (Spec 2) and set `chunks_complete`, then
  delete the parts.
- **STT worker**: a scheduled tick (1 s) claims pending chunks whose
  `not_before` has passed, up to `:concurrency`, and posts each one to
  `/audio/transcriptions` (`response_format=verbose_json`). The response is
  parsed like `muesli-stt-parse-response` (segments, words, plain-text
  fallback), shifted by the chunk offset and stored. Errors back off
  `retry-delay × 2^attempt`.
- **Completion**: a `processing` recording with `chunks_complete` and no
  pending or uploading chunk either fails (some chunk failed) or goes on to
  diarize. Diarization decodes `audio.<ext>` to a 16 kHz WAV, posts it with
  `num_speakers` = `recordings.speakers`, and assigns turns to segments with
  the same overlap/split rules as `muesli-diarize-assign-segment`. Labels are
  `mic:<label>`. Then the recording is `transcribed`.
- **Ack** marks the recording `delivered`. It deletes the audio, chunk WAVs
  and segments when `:after-ack-hours` is 0, otherwise the sweeper does it
  later.

### 4.5 Emacs-facing API additions (`/api/v1/client`)

| Method & path | Purpose |
|---|---|
| `POST /recordings` | `{"id", "title", "speakers", "started_at"}`. Creates a `waiting`, Emacs-origin recording for this client. Idempotent per id. |
| `GET /recordings/:id` | Status: `{"id", "status", "origin", "title", "notes", "started_at", "ended_at", "duration_ms", "speakers", "last_part_at", "server_time", "parts", "stop_requested", "chunks": {"pending", "uploading", "done", "failed", "total"}, "segments", "failed_step", "error"}`. While recording, `duration_ms` is the end of the last complete chunk. Emacs runs its mode line clock from the phone's `started_at`. |
| `GET /recordings/:id/segments?after=N` | Segments with `id > N`, ordered by id: `[{"id", "chunk_no", "start_ms", "end_ms", "speaker", "text", "words"}]`. |
| `POST /recordings/:id/stop` | Waiting: becomes abandoned. Recording: sets `stop_requested`, and finishes at once when the phone is gone. Otherwise a no-op. Returns the status. |
| `POST /recordings/:id/retry` | `{"skip": bool}`. From `failed`: reset failed chunks (or drop them, with skip; skip on a diarizing failure finishes without labels) and go back to `processing`. |
| `DELETE /recordings/:id` | Discard an undelivered recording (abort). |
| `GET /recordings?status=transcribed` | Recordings to import (replaces `ready`). Emacs imports phone-origin ones and ignores Emacs-origin ones it already tracks. |
| `POST /recordings/:id/ack` | As before, but from `transcribed`. |

`GET /recordings/:id/audio` stays, for the web UI and for debugging.
`reject` stays, for phone-origin recordings with an unknown profile.

### 4.6 PWA-facing API changes (`/app/api`)

- `GET /app/api/sessions` lists the user's `waiting` recordings:
  `[{"id", "client_id", "client_name", "title", "created_at"}]`.
- `PUT /app/api/recordings/:id` on a `waiting` recording of the same user
  **claims** it: it sets `mime_type`, `started_at` and the status
  `recording`. `client_id` and `profile` are then optional. This is the same
  idempotent call the upload queue already makes.
- The `PUT …/parts/:seq` reply gains `"stop_requested": bool`.

## 5. The PWA

- The record screen shows waiting sessions above the pickers, each with its
  own **Record** button. Recording a session hides the client/profile/title
  pickers, because Emacs already chose them.
- When a part reply says `stop_requested` for the current recording, the
  recorder stops exactly as if Stop were tapped (notes are sent with
  finish).
- History chips: *waiting for phone*, *recording*, *transcribing*,
  *transcribed* (waiting for Emacs), *delivered*, *failed: reason*.

## 6. Emacs

### 6.1 New and changed variables

| Variable | Meaning |
|---|---|
| `muesli-recording-source` | `local` (ffmpeg on this machine) or `phone` (record through the relay). The default is `phone` on `windows-nt` and `local` elsewhere. `C-u C-u M-x muesli-start` picks the other one. |
| `muesli-relay-live-interval` | Seconds between status polls of an active phone meeting (default 5). |

`muesli-relay-keep-original` and `muesli-relay-download-timeout` are removed,
because Emacs no longer downloads audio.

### 6.2 Integration with the pipeline (`muesli.el`)

`muesli.el` does not require `muesli-relay`. It dispatches through it when a
meeting has a `relay_imports` row, or when the source is `phone`:

- `muesli-start` skips the ffmpeg check and calls `muesli-relay-start-meeting`.
  That function creates the meeting row (mode `room`, no `audio_dir`) and the
  `relay_imports` row in one transaction, and returns a recording-state
  plist with the same `:stop` / `:watch-stop` / `:exited` contract the local
  recorder uses. So `muesli-stop`, `muesli-abort` and the mode line work
  unchanged.
- `muesli--step-transcribe` for a relay meeting calls
  `muesli-relay-await-transcript`. It polls until `transcribed`, replaces the
  segments and speakers, acks, and continues with `muesli--after-diarize`.
  The local `diarizing` step is skipped because the relay already diarized.
- `muesli-resume` and the orphan check call `muesli-relay-resume` for relay
  meetings instead of scanning the audio directory.

### 6.3 Database

No migration. `relay_imports` (`remote_id`, `meeting_id`, `relay_url`,
`profile`, `imported_at`, `acked_at`) already maps any remote recording to a
meeting. Emacs-origin rows use profile `""`. Live segments are inserted with
`track = "mic"` and the relay's `chunk_no`. The final pull deletes and
re-inserts them, because diarization may split segments.

## 7. Windows notes

- Emacs 29+ for Windows ships with SQLite, and Windows 10+ ships `curl.exe`.
  Nothing else is needed for phone meetings.
- `muesli-recording-source` defaults to `phone` there, so the plain
  `muesli-start` / `muesli-stop` bindings work as is.
- Local recording on Windows would still need an ffmpeg `dshow` preset in
  `muesli-recorder-command`. That is out of scope here.

## 8. Open questions

1. Safari/iOS fragmented MP4 through an ffmpeg pipe. WebM/Opus is covered by
   the tests. MP4 needs a real device test (Spec 2 §10.1 still applies).
2. Long-poll instead of polling for the live transcript.
3. Encryption at rest is harder now that the relay must read the audio. It
   could still encrypt the transcript to an Emacs key after processing.
