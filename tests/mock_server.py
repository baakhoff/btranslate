"""A local stand-in for the services BTranslate talks to, for tests/run.sh.

  /anthropic/...        Anthropic Messages API (streaming, with a thinking block first)
  /anthropic-old/...    the same, but rejects output_config like an older model does
  /anthropic-refusal/.. a reply that stops with stop_reason "refusal"
  /openai/...           chat completions (streaming)
  /openrouter-strict/.. chat completions that reject the "reasoning" field
  /google/...           Google's first endpoint
  /google429/...        the first endpoint says 429; the second one answers
  /speech/...           Google Translate's voice (the page's own batchexecute call)
Every request is logged as one JSON line on stdout.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
from urllib.parse import parse_qs, urlparse

PIECES = ["[", "lv", "]\n", "Hello! ", "How are ", "you?\nSecond line."]


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
        self.record(None)
        if self.path.startswith("/anthropic/models"):
            self.reply(200, {"data": [{"id": "claude-haiku-5-5"}, {"id": "claude-sonnet-5-5"}]})
        elif self.path.startswith("/openai/models"):
            self.reply(200, {"data": [{"id": "models/zeta"}, {"id": "alpha"}]})
        else:
            self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if "/translate_a/" in self.path:
            text = parse_qs(raw.decode()).get("q", [""])[0]
            self.record({"q": text})
            given = parse_qs(urlparse(self.path).query).get("sl", ["auto"])[0]
            if self.path.startswith("/google429/translate_a/single"):
                self.reply(429, b"<html><title>Sorry...</title></html>", "text/html")
            elif "/translate_a/single" in self.path:
                self.reply(200, [[["EN:" + text, text]], None, "lv" if given == "auto" else given])
            elif given == "auto":
                self.reply(200, [["EN2:" + text, "lv"]])
            else:  # with the source language given, the second endpoint answers with the text alone
                self.reply(200, ["EN2:" + text])
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
                events += [("content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": p}}) for p in PIECES]
                events += [("content_block_stop", {"type": "content_block_stop", "index": 1}),
                           ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 9}}),
                           ("message_stop", {"type": "message_stop"})]
                self.sse(events)
        elif self.path.endswith("/chat/completions"):
            if self.path.startswith("/openrouter-strict") and "reasoning" in body:
                self.reply(400, {"error": {"message": "reasoning is not supported"}})
            else:
                events = [(None, {"choices": [{"delta": {"role": "assistant", "content": ""}}]})]
                events += [(None, {"choices": [{"delta": {"content": p}}]}) for p in PIECES]
                events += [(None, {"choices": [{"delta": {}, "finish_reason": "stop"}]}), (None, "[DONE]")]
                self.sse(events)
        else:
            self.reply(404, {"error": {"message": "not found"}})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
