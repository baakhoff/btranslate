"""A local stand-in for the services BTranslate talks to, for tests/run.sh.

  /anthropic/...        Anthropic Messages API (streaming, with a thinking block first)
  /anthropic-old/...    the same, but rejects output_config like an older model does
  /anthropic-refusal/.. a reply that stops with stop_reason "refusal"
  /openai/...           chat completions (streaming)
  /openrouter-strict/.. chat completions that reject the "reasoning" field
  /google/...           Google's first endpoint
  /google429/...        the first endpoint says 429; the second one answers
  /googleflaky2-x/...   the first 2 requests (any number) are cut off without an answer, as
                        when there is no connection; after that it is /google. "x" is any
                        name: each name counts its own requests
  /speech/...           Google Translate's voice (the page's own batchexecute call)
  /pack/...             a miniature language pack: its list of files and two small files,
                        with checksums; a request for part of a file ("Range") gets that part
  /pack-damaged/...     the same, but one file is not what the list says
Every request is logged as one JSON line on stdout.
"""
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hashlib
from urllib.parse import parse_qs, urlparse

PIECES = ["[", "lv", "]\n", "Hello! ", "How are ", "you?\nSecond line."]


def pieces(asked):
    """What the AI stand-in answers. Asked for many short texts at once (numbered lines:
    "3| Open file"), it answers each as "3| AI:Open file", and leaves number 2 out."""
    lines = [line for line in asked.split("\n") if re.match(r"\d+\| ", line)]
    if not lines:
        return PIECES
    return [re.sub(r"^(\d+)\| ", r"\1| AI:", line) + "\n" for line in lines if not line.startswith("2| ")]
CUT_OFF = {}  # "googleflaky2-x" → how many requests it has cut off so far
HELD = {"now": 0, "most": 0}  # requests to a "slow" address that are being answered now, and the most there were
HELD_LOCK = threading.Lock()
# The miniature language pack: no models, so installing it is downloading and checking only.
PACK = {"nllb200-v1-tokens.tsv": "<s>\t\n<pad>\t\n</s>\t\n<unk>\t\n▁a\t-0.0\nb\t-1.0\n".encode(),
        "nllb200-v1-note.txt": b"A stand-in for a model's weights. " * 400}
PACK_LIST = {"version": 1, "length": 64, "pad": 1, "end": 2, "unknown": 3, "languages": ["eng_Latn", "rus_Cyrl"],
             "files": [{"name": name, "path": name.replace("nllb200-v1-", ""), "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                       for name, data in PACK.items()]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for name, data in events:
            if name:
                self.wfile.write(f"event: {name}\n".encode())
            payload = data if isinstance(data, str) else json.dumps(data)
            self.wfile.write(f"data: {payload}\n\n".encode())
            self.wfile.flush()

    def record(self, body):
        print(json.dumps({
            "method": self.command, "path": self.path, "body": body,
            "x-api-key": self.headers.get("x-api-key"), "authorization": self.headers.get("Authorization"),
            "anthropic-version": self.headers.get("anthropic-version"),
        }, sort_keys=True, ensure_ascii=False), flush=True)

    def do_GET(self):
        self.record({"range": self.headers.get("Range")} if self.path.startswith("/pack") else None)
        name = self.path.rsplit("/", 1)[-1]
        if self.path.startswith("/pack") and name == "nllb200-v1-pack.json":
            self.reply(200, PACK_LIST)
        elif self.path.startswith("/pack") and name in PACK:
            data = PACK[name]
            if self.path.startswith("/pack-damaged") and name.endswith("note.txt"):
                data = data[:-1] + b"!"  # the right length, the wrong content
            start = int((self.headers.get("Range") or "bytes=0-")[6:].split("-")[0])
            if start >= len(data):
                self.send_response(416)
                self.end_headers()
                return
            self.send_response(206 if start else 200)
            self.send_header("Content-Length", str(len(data) - start))
            self.end_headers()
            self.wfile.write(data[start:])
        elif self.path.startswith("/anthropic/models"):
            self.reply(200, {"data": [{"id": "claude-haiku-5-5"}, {"id": "claude-sonnet-5-5"}]})
        elif self.path.startswith("/openai/models"):
            self.reply(200, {"data": [{"id": "models/zeta"}, {"id": "alpha"}]})
        else:
            self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        # An address whose first part has "slow" in it (/googleslow/…, /anthropicslow/…) takes a
        # third of a second to answer, as a real server takes its time, and the log says how
        # many such requests were being answered at once: `"together": 3`. A request stops
        # counting before its answer goes out: the next one, which the app sends only once it
        # has that answer, is never counted together with it.
        slow = "slow" in self.path.split("/")[1]
        if slow:
            with HELD_LOCK:
                HELD["now"] += 1
                HELD["most"] = max(HELD["most"], HELD["now"])
            time.sleep(0.35)
            with HELD_LOCK:
                HELD["now"] -= 1
                most = HELD["most"]
                if HELD["now"] == 0:
                    HELD["most"] = 0
                    print(json.dumps({"path": self.path.split("/")[1], "together": most}), flush=True)
        self.answer_post()

    def answer_post(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if "/translate_a/" in self.path:
            texts = parse_qs(raw.decode()).get("q", [""])
            text = texts[0]
            self.record({"q": text} if len(texts) == 1 else {"q": texts})
            first = self.path.split("/")[1]
            flaky = re.match(r"googleflaky(\d+)", first)
            if flaky and CUT_OFF.get(first, 0) < int(flaky.group(1)):
                CUT_OFF[first] = CUT_OFF.get(first, 0) + 1
                self.close_connection = True  # no answer at all: the connection just ends
                return
            query = parse_qs(urlparse(self.path).query)
            given = query.get("sl", ["auto"])[0]
            into = query.get("tl", ["en"])[0].upper()  # the "translation" is the text with this in front
            if self.path.startswith("/google429/translate_a/single"):
                self.reply(429, b"<html><title>Sorry...</title></html>", "text/html")
            elif "/translate_a/single" in self.path:
                self.reply(200, [[[into + ":" + text, text]], None, "lv" if given == "auto" else given])
            elif len(texts) > 1:
                # Several texts in one request (a window's picture): each gets its own answer and its
                # own language: Russian for Cyrillic letters, Latvian for the rest. A text in the
                # language asked for comes back as it is.
                def one(t):
                    code = "ru" if re.search("[\u0400-\u04ff]", t) else "lv"
                    return [t if code.upper() == into else into + "2:" + t, code]
                self.reply(200, [one(t) for t in texts])
            elif given == "auto":
                self.reply(200, [[into + "2:" + text, "lv"]])
            else:  # with the source language given, the second endpoint answers with the text alone
                self.reply(200, [into + "2:" + text])
            return
        if self.path.endswith("/batchexecute"):
            call = json.loads(parse_qs(raw.decode()).get("f.req", ["[]"])[0])
            text, code = json.loads(call[0][0][1])[:2]
            self.record({"rpc": call[0][0][0], "text": text, "code": code})
            audio = base64.b64encode(b"not really an mp3: " + text.encode()).decode()
            answer = json.dumps([["wrb.fr", "jQ1olc", json.dumps([audio]), None, None, None, "generic"]])
            self.reply(200, (")]}'\n\n" + answer + "\n").encode(), "application/json")
            return

        body = json.loads(raw)
        self.record(body)
        if self.path.endswith("/messages"):
            if self.headers.get("x-api-key") != "test-key":
                self.reply(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            elif self.path.startswith("/anthropic-old") and "output_config" in body:
                self.reply(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "output_config: Extra inputs are not permitted"}})
            elif self.path.startswith("/anthropic-refusal"):
                self.sse([("message_start", {"type": "message_start", "message": {}}),
                          ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "refusal"}}),
                          ("message_stop", {"type": "message_stop"})])
            else:
                events = [("message_start", {"type": "message_start", "message": {"id": "msg_1"}}),
                          ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
                          ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "IGNORED"}}),
                          ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "x"}}),
                          ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                          ("ping", {"type": "ping"}),
                          ("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}})]
                events += [("content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": p}})
                           for p in pieces(body["messages"][-1]["content"])]
                events += [("content_block_stop", {"type": "content_block_stop", "index": 1}),
                           ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 9}}),
                           ("message_stop", {"type": "message_stop"})]
                self.sse(events)
        elif self.path.endswith("/chat/completions"):
            if self.path.startswith("/openrouter-strict") and "reasoning" in body:
                self.reply(400, {"error": {"message": "reasoning is not supported"}})
            else:
                events = [(None, {"choices": [{"delta": {"role": "assistant", "content": ""}}]})]
                events += [(None, {"choices": [{"delta": {"content": p}}]}) for p in pieces(body["messages"][-1]["content"])]
                events += [(None, {"choices": [{"delta": {}, "finish_reason": "stop"}]}), (None, "[DONE]")]
                self.sse(events)
        else:
            self.reply(404, {"error": {"message": "not found"}})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
