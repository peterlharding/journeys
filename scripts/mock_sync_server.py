#!/usr/bin/env python3
"""
A stand-in for fastapi-api's sync and sign-in endpoints, for UI tests: same
requests and answers, records kept in memory.

    POST /api/v1/journeys/sync         the sync endpoint; needs a bearer token
    POST /api/v1/auth/authenticate     any username, password "secret"
    POST /api/v1/auth/refresh-token    each refresh token works once
    POST /api/v1/auth/logout
    GET  /state    {"journeys": [...ids], "waypoints": [...ids], "requests": n, "unauthorized": n}
                   (requests counts sync posts, unauthorized those refused for want of a token)
    POST /reset    forget everything

Usage: scripts/mock_sync_server.py [port]   (default 8765, on 127.0.0.1 only)
"""

import json
import sys
import uuid

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = "secret"
SYNC = "/api/v1/journeys/sync"

journeys = {}
waypoints = {}
requests = 0
unauthorized = 0
access_tokens = set()
refresh_tokens = set()
issued = 0


def normalise(value):
    return str(uuid.UUID(value)).upper()


class Handler(BaseHTTPRequestHandler):
    def issue(self, username):
        global issued
        issued += 1
        access, refresh = f"mock-access-{issued}", f"mock-refresh-{issued}"
        access_tokens.add(access)
        refresh_tokens.add(refresh)
        self.reply(200, {"token": access, "refresh_interval": 900, "refresh_token": refresh,
                         "user": {"username": username}})

    def auth(self, path, fields):
        if path == "/api/v1/auth/authenticate":
            if fields.get("password") != PASSWORD:
                self.reply(401, {"detail": "Invalid credentials"})
            else:
                self.issue(fields.get("username", ""))
        elif path == "/api/v1/auth/refresh-token":
            token = fields.get("refresh_token")
            if token not in refresh_tokens:
                self.reply(401, {"detail": "Invalid refresh token"})
            else:
                refresh_tokens.discard(token)
                self.issue("tester")
        else:  # logout
            access_tokens.discard(self.headers.get("Authorization", "").removeprefix("Bearer "))
            refresh_tokens.discard(fields.get("refresh_token"))
            self.reply(204, None)

    def reply(self, status, body):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/state":
            self.reply(200, {"journeys": sorted(journeys), "waypoints": sorted(waypoints), "requests": requests,
                             "unauthorized": unauthorized})
        else:
            self.reply(404, {"detail": "Not Found"})

    def do_POST(self):
        global requests, unauthorized, issued
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path == "/reset":
            for collection in (journeys, waypoints, access_tokens, refresh_tokens):
                collection.clear()
            requests = unauthorized = issued = 0
            self.reply(200, {})
            return
        if self.path.startswith("/api/v1/auth/"):
            self.auth(self.path, json.loads(body or b"{}"))
            return
        if self.path != SYNC:
            self.reply(404, {"detail": "Not Found"})
            return
        requests += 1
        if self.headers.get("Authorization", "").removeprefix("Bearer ") not in access_tokens:
            unauthorized += 1
            self.reply(401, {"detail": "Not authenticated"})
            return
        try:
            batch = json.loads(body or b"{}")
            journey_answers, waypoint_answers = {}, {}
            for journey in batch.get("journeys", []):
                ref = normalise(journey["id"])
                journey_answers[ref] = "duplicate" if ref in journeys else "stored"
                journeys.setdefault(ref, journey)
            for waypoint in sorted(batch.get("waypoints", []), key=lambda w: w["recordedAt"]):
                ref, journey_ref = normalise(waypoint["id"]), normalise(waypoint["journeyId"])
                if ref in waypoints:
                    waypoint_answers[ref] = "duplicate"
                elif journey_ref not in journeys:
                    waypoint_answers[ref] = f"rejected: no journey with id {journey_ref}"
                else:
                    waypoints[ref] = waypoint
                    waypoint_answers[ref] = "stored"
        except (KeyError, ValueError, TypeError) as error:
            self.reply(422, {"detail": str(error)})
            return
        self.reply(200, {"journeys": journey_answers, "waypoints": waypoint_answers})

    def log_message(self, format, *args):
        sys.stderr.write("mock-sync: " + format % args + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
