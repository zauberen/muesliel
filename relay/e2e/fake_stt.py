#!/usr/bin/env python3
"""Fake OpenAI-compatible speech server for relay/e2e/run.sh.

POST /v1/audio/transcriptions  -> verbose_json: one segment naming the chunk
POST /v1/audio/diarization     -> one speaker for the whole file

It checks that the request is a well-formed multipart upload with a
`model` field and a non-empty WAV `file`, so the relay's HTTP client is
exercised for real.  Usage: fake_stt.py PORT
"""
import json
import sys
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_multipart(content_type, body):
    msg = BytesParser(policy=HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body)
    fields, files = {}, {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if part.get_filename():
            files[name] = (part.get_filename(), part.get_payload(decode=True))
        else:
            fields[name] = part.get_content().strip()
    return fields, files


class Handler(BaseHTTPRequestHandler):
    calls = {"transcriptions": 0, "diarization": 0}

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, self.calls)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            fields, files = parse_multipart(self.headers["Content-Type"], body)
        except Exception as e:  # noqa: BLE001
            return self.reply(400, {"error": f"bad multipart: {e}"})
        name, data = files.get("file", (None, b""))
        if not fields.get("model") or not data.startswith(b"RIFF"):
            return self.reply(400, {"error": "need model and a WAV file", "fields": fields})
        if self.path.endswith("/audio/transcriptions"):
            self.calls["transcriptions"] += 1
            return self.reply(200, {"text": f"heard {name}", "segments": [
                {"start": 0.2, "end": 1.2, "text": f"heard {name}",
                 "words": [{"word": "heard", "start": 0.2, "end": 0.6},
                           {"word": name, "start": 0.6, "end": 1.2}]}]})
        if self.path.endswith("/audio/diarization"):
            self.calls["diarization"] += 1
            return self.reply(200, {"segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 36000}]})
        self.reply(404, {"error": "no such endpoint"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
