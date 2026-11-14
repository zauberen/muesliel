#!/usr/bin/env bash
# End-to-end test: real relay (Clojure, ffmpeg), real PWA in headless Chrome
# with a fake microphone, real Emacs (curl, SQLite, org; no ffmpeg).  Only
# the speech server (e2e/fake_stt.py, over real HTTP) and the summary LLM
# are faked.
#
#   relay/e2e/run.sh            needs: clojure, node, emacs, ffmpeg, python3, Chrome
#   CHROME=/path/to/chrome relay/e2e/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
relay="$(dirname "$here")"
repo="$(dirname "$relay")"
port="${E2E_PORT:-18787}"
work="$(mktemp -d "${TMPDIR:-/tmp}/muesli-e2e.XXXXXX")"
export E2E_DIR="$work"
export RELAY_URL="http://localhost:$port"
export E2E_USER=alice E2E_PASS="correct horse battery staple"
export CHROME="${CHROME:-$(command -v google-chrome-stable || command -v google-chrome || command -v chromium)}"

server_pid="" stt_pid="" emacs_pid=""
cleanup() { for p in $server_pid $stt_pid $emacs_pid; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

cd "$relay"
[ -f resources/public/js/main.js ] || { step "building PWA"; npx shadow-cljs release app sw; }
[ -d e2e/node_modules/playwright-core ] || (cd e2e && npm install --no-audit --no-fund --silent)

stt_port=$((port + 1))
python3 "$here/fake_stt.py" "$stt_port" &
stt_pid=$!

export RELAY_DB="$work/relay.sqlite" RELAY_STORAGE="$work/audio" RELAY_PORT="$port" \
       RELAY_SESSION_SECRET="e2e-secret" RELAY_BASE_URL="$RELAY_URL" \
       RELAY_STT_URL="http://127.0.0.1:$stt_port/v1" RELAY_DIARIZATION=localai \
       RELAY_CHUNK_SECONDS=5

step "creating user"
printf '%s\n' "$E2E_PASS" | clojure -M:run user add "$E2E_USER" --admin 2>/dev/null | grep -v WARNING

step "starting relay on $port"
clojure -M:run serve >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 120); do curl -fsS -o /dev/null "$RELAY_URL/login" 2>/dev/null && break; sleep 0.5; done
curl -fsS -o /dev/null "$RELAY_URL/login"

step "logging in and creating an API key through the web forms"
jar="$work/cookies"
csrf() { grep -o 'content="[^"]*" name="csrf-token"' | sed 's/content="\([^"]*\)".*/\1/'; }
token="$(curl -fsS -c "$jar" -b "$jar" "$RELAY_URL/login" | csrf)"
curl -fsS -o /dev/null -c "$jar" -b "$jar" --data-urlencode "username=$E2E_USER" \
     --data-urlencode "password=$E2E_PASS" --data-urlencode "__anti-forgery-token=$token" "$RELAY_URL/login"
token="$(curl -fsS -c "$jar" -b "$jar" "$RELAY_URL/keys" | csrf)"
key="$(curl -fsS -c "$jar" -b "$jar" --data-urlencode "name=e2e" --data-urlencode "__anti-forgery-token=$token" \
       "$RELAY_URL/keys" | grep -o 'msl_[a-z2-7]\{52\}' | head -1)"
[ -n "$key" ] || { echo "no key created"; exit 1; }
export RELAY_KEY="$key"
echo "key ${key:0:12}…"

step "M-x muesli-relay-link"
emacs -Q --batch -L "$repo" -l "$here/e2e.el" --eval '(muesli-e2e "link")'

step "recording ${SECONDS_TO_RECORD:-12}s in the PWA (headless Chrome, fake mic)"
SECONDS="${SECONDS_TO_RECORD:-12}" node "$here/record.mjs"

step "M-x muesli-relay-fetch (three phone-started recordings, transcribed by the relay)"
E2E_EXPECT=3 emacs -Q --batch -L "$repo" -l "$here/e2e.el" --eval '(muesli-e2e "fetch")'

step "meeting started in Emacs, recorded on the phone, stopped from Emacs"
rm -f "$work/emacs/meetings.org"
emacs -Q --batch -L "$repo" -l "$here/e2e.el" --eval '(muesli-e2e "meeting")' >"$work/meeting.log" 2>&1 &
emacs_pid=$!
node "$here/record-session.mjs"
wait "$emacs_pid" || { cat "$work/meeting.log"; exit 1; }
emacs_pid=""
cat "$work/meeting.log"
echo "fake STT calls: $(curl -fsS "http://127.0.0.1:$stt_port/")"

step "relay state after hand-off"
curl -fsS -H "Authorization: Bearer $key" "$RELAY_URL/api/v1/client/ping"; echo
left="$(find "$work/audio" -type f | wc -l)"
echo "audio files left on relay: $left"
[ "$left" -eq 0 ] || { echo "audio was not deleted after ack"; exit 1; }

printf '\nE2E OK (artifacts in %s)\n' "$work"
