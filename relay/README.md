# muesli-relay

Record meetings on your phone and get the transcript in Emacs. This is a small Clojure service with a ClojureScript PWA. The phone records. The relay cuts the audio into chunks with ffmpeg, sends each chunk to your speech-to-text server while the meeting is still going, and diarizes the result. Emacs pulls the transcript and does the rest: naming speakers, summarizing with your notes, and writing the org heading. Emacs therefore needs no audio stack, which also makes muesli work on Windows.

A meeting can start in Emacs (`muesli-start` with `muesli-recording-source` set to `phone`, then tap *Record* on the waiting banner in the app) or on the phone (`M-x muesli-relay-fetch` imports it later). The design is in [`../docs/muesli-relay-spec.md`](../docs/muesli-relay-spec.md) (hand-off, auth, PWA) and [`../docs/muesli-relay-transcription-spec.md`](../docs/muesli-relay-transcription-spec.md) (server-side transcription). The Emacs side is described in the main `README.org`.

## Run it

Requirements: Java 21+, the Clojure CLI, ffmpeg, Node (needed only to build the PWA), and a speech-to-text server with an OpenAI-compatible `/v1/audio/transcriptions` endpoint, such as LocalAI serving Parakeet. That is the same server the Emacs side uses for local recordings.

```sh
cd relay
npm install                      # shadow-cljs, for the PWA build
clojure -T:build uber            # builds the PWA and target/muesli-relay.jar

export RELAY_BASE_URL=https://relay.example   # the URL your phone uses
export RELAY_STT_URL=http://localhost:8080/v1  # your speech-to-text server
export RELAY_DIARIZATION=localai               # or none
java -jar target/muesli-relay.jar user add alice --admin   # prompts for a password
java -jar target/muesli-relay.jar                          # serves on 127.0.0.1:8787
```

The phone needs **HTTPS** for the microphone and the service worker (`localhost` is the only exception). The relay speaks plain HTTP and expects a proxy in front of it to terminate TLS:

- **Tailscale:** `tailscale serve --bg --https=443 8787`, then use `https://<machine>.<tailnet>.ts.net`.
- **Caddy:** `relay.example { reverse_proxy 127.0.0.1:8787 }`.

Set `RELAY_BEHIND_PROXY=true` behind a proxy so client IPs (for login rate limiting) and the scheme come from `X-Forwarded-*`. If Emacs runs on the same machine, it can use `http://127.0.0.1:8787` directly.

## Configuration

`resources/config.edn` holds the defaults. Every setting can be overridden with an environment variable, or `RELAY_CONFIG=/path/to/config.edn` replaces the whole file.

| Variable | Default | |
|---|---|---|
| `RELAY_HOST` / `RELAY_PORT` | `127.0.0.1` / `8787` | listen address |
| `RELAY_BASE_URL` | `http://localhost:8787` | public URL; `https://` turns on Secure cookies |
| `RELAY_BEHIND_PROXY` | `false` | trust `X-Forwarded-Proto/For` |
| `RELAY_DB` | `data/relay.sqlite` | SQLite database |
| `RELAY_STORAGE` | `data/audio` | audio while it waits for Emacs |
| `RELAY_SESSION_SECRET` | random, kept in `data/session.key` | cookie encryption |
| `RELAY_SIGNUP` | `false` | allow self sign-up |
| `RELAY_FFMPEG` | `ffmpeg` | ffmpeg used to cut and decode audio |
| `RELAY_STT_URL` | `http://localhost:8080/v1` | OpenAI-compatible speech-to-text server |
| `RELAY_STT_MODEL` | `parakeet-tdt-0.6b-v3` | transcription model |
| `RELAY_STT_API_KEY` / `RELAY_STT_LANGUAGE` | unset | bearer token, language hint |
| `RELAY_STT_CONCURRENCY` | `1` | chunks transcribed at once |
| `RELAY_CHUNK_SECONDS` | `30` | chunk length |
| `RELAY_DIARIZATION` | `none` | `none`, `localai` (`/audio/diarization`) or `diarized-json` |
| `RELAY_DIARIZATION_URL` / `_MODEL` / `_API_KEY` | STT server / `parakeet-cpp-nemotron-3-diarization` / unset | diarization server |

These mirror the Emacs `muesli-stt-*` and `muesli-diarization-*` variables. Retries, timeouts and the speaker-split threshold are in `config.edn`.

Audio, chunks and transcript are deleted as soon as Emacs acknowledges the transcript. Recordings with no new audio for 24 h (and meetings Emacs started that no phone picked up) are marked abandoned and purged after 14 days. When Emacs asks to stop and the phone has sent nothing for 60 s, the relay finishes with what it has.

## Users

```sh
java -jar target/muesli-relay.jar user add NAME [--admin]
java -jar target/muesli-relay.jar user passwd NAME
java -jar target/muesli-relay.jar user disable NAME   # also: enable, list
```

Admins can also add users and turn accounts on or off at `/admin/users`.

## Develop and test

```sh
clojure -M:test          # server tests (ring-mock, temp SQLite; the pipeline tests need ffmpeg)
npx shadow-cljs watch app sw
clojure -M:run           # serve with the dev build
e2e/run.sh               # full end-to-end test, see below
```

`e2e/run.sh` starts a real relay and a fake speech server (`e2e/fake_stt.py`, real HTTP), creates a user and a key through the web forms, and links a batch Emacs. It then records in the PWA with headless Chrome and a fake microphone, in three scenarios: a normal recording, a network drop mid-recording, and a tab killed mid-recording and recovered. Emacs fetches the transcribed recordings and checks that each one finished the pipeline. A fourth scenario starts a meeting in Emacs. The phone picks it up from the waiting banner, Emacs sees live segments and calls `muesli-stop`, and the phone stops on its own. Finally it checks that the relay deleted all audio. Emacs runs without ffmpeg throughout. It needs Chrome (`CHROME=` to point at it), ffmpeg, Python 3, Emacs 29+ and Node.
