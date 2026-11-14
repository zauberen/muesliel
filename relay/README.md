# muesli-relay

Record meetings on your phone and hand them to Emacs. This is a small Clojure service with a ClojureScript PWA. Emacs pulls finished recordings with `M-x muesli-relay-fetch` and runs them through muesli's normal pipeline. The design is in [`../docs/muesli-relay-spec.md`](../docs/muesli-relay-spec.md), and the Emacs side is described in the main `README.org`.

## Run it

Requirements: Java 21+, the Clojure CLI, and Node (needed only to build the PWA).

```sh
cd relay
npm install                      # shadow-cljs, for the PWA build
clojure -T:build uber            # builds the PWA and target/muesli-relay.jar

export RELAY_BASE_URL=https://relay.example   # the URL your phone uses
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

Audio is deleted as soon as Emacs acknowledges the import. Recordings with no new audio for 24 h are marked abandoned and purged after 14 days.

## Users

```sh
java -jar target/muesli-relay.jar user add NAME [--admin]
java -jar target/muesli-relay.jar user passwd NAME
java -jar target/muesli-relay.jar user disable NAME   # also: enable, list
```

Admins can also add users and turn accounts on or off at `/admin/users`.

## Develop and test

```sh
clojure -M:test          # server tests (ring-mock, temp SQLite)
npx shadow-cljs watch app sw
clojure -M:run           # serve with the dev build
e2e/run.sh               # full end-to-end test, see below
```

`e2e/run.sh` starts a real relay, creates a user and a key through the web forms, and links a batch Emacs. It then records in the PWA with headless Chrome and a fake microphone, in three scenarios: a normal recording, a network drop mid-recording, and a tab killed mid-recording and recovered. Finally Emacs fetches the recordings and checks that each one finished the pipeline and that the relay deleted its audio. Only speech-to-text and the summary are faked. It needs Chrome (`CHROME=` to point at it), ffmpeg, Emacs 29+ and Node.
