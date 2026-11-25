#!/usr/bin/env python3
"""Forward requests to a Tang server and inject faults for the
tang-pub-binding test.

The mode file is re-read on every request and may contain several
comma-separated modes:

  passthrough      forward unchanged
  block-version    404 for GET /version; clevis then cannot detect tang_pub
                   support and stores the advertisement in the binding
                   (pre-tang_pub, "legacy-format" behavior)
  block-adv        404 for GET /adv
  tamper-tang-pub  replace tang_pub in /rec POST responses with the key
                   loaded from the fake-key file (simulates a MITM
                   returning a mismatched server key)
"""

import http.client
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class TangPubProxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _modes(self):
        try:
            with open(self.server.mode_file, encoding="ascii") as mode_file:
                return {m.strip() for m in mode_file.read().split(",") if m.strip()}
        except OSError:
            return set()

    def _failure(self, reason):
        body = json.dumps({"error": reason}).encode()
        self.send_response(404, "Not Found")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _forward(self):
        body_length = int(self.headers.get("Content-Length", "0"))
        request_body = self.rfile.read(body_length) if body_length else None
        path = urlsplit(self.path).path
        modes = self._modes()

        if "block-version" in modes and self.command == "GET" and path == "/version":
            self._failure("simulated /version failure")
            return
        if "block-adv" in modes and self.command == "GET" and path.startswith("/adv"):
            self._failure("simulated /adv failure")
            return

        request_headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"connection", "content-length", "host"}
        }
        connection = http.client.HTTPConnection(
            self.server.upstream_host,
            self.server.upstream_port,
            timeout=20,
        )
        try:
            connection.request(self.command, self.path, body=request_body,
                               headers=request_headers)
            upstream = connection.getresponse()
            response_body = upstream.read()
            response_status, response_reason = upstream.status, upstream.reason
            response_headers = upstream.getheaders()
        except OSError as error:
            self.send_error(502, str(error))
            return
        finally:
            connection.close()

        if "tamper-tang-pub" in modes and self.command == "POST" \
                and path.startswith("/rec/"):
            try:
                with open(self.server.fake_key_file, encoding="utf-8") as key_file:
                    fake_key = json.load(key_file)
                document = json.loads(response_body)
                document["tang_pub"] = fake_key
                response_body = json.dumps(document).encode()
            except (OSError, ValueError):
                self.send_error(502, "could not tamper /rec response")
                return

        self.send_response(response_status, response_reason)
        for key, value in response_headers:
            if key.lower() not in {
                "connection",
                "content-length",
                "keep-alive",
                "transfer-encoding",
            }:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)

    do_GET = _forward
    do_POST = _forward

    def log_message(self, _format, *_args):
        return


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: tang-pub-proxy.py TANG_URL MODE_FILE "
                         "PORT_FILE FAKE_KEY_FILE")

    upstream = urlsplit(sys.argv[1])
    if upstream.scheme != "http" or not upstream.hostname:
        raise SystemExit("TANG_URL must be an http:// URL")

    server = ThreadingHTTPServer(("127.0.0.1", 0), TangPubProxy)
    server.upstream_host = upstream.hostname
    server.upstream_port = upstream.port or 80
    server.mode_file = sys.argv[2]
    server.fake_key_file = sys.argv[4]

    with open(sys.argv[3], "w", encoding="ascii") as port_file:
        port_file.write(f"{server.server_port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
