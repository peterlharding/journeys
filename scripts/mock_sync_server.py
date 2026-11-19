#!/usr/bin/env python3
"""
A stand-in for the API's POST /sync, for UI tests: same request and answers as
mongo-api (doc/SYNC.md there), records kept in memory.

    POST /sync    the endpoint
    GET  /state   {"journeys": [...ids], "waypoints": [...ids], "requests": n}
    POST /reset   forget everything

Usage: scripts/mock_sync_server.py [port]   (default 8765, on 127.0.0.1 only)
"""

import json
import sys
import uuid

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

journeys = {}
waypoints = {}
requests = 0


def normalise(value):
    return str(uuid.UUID(value)).upper()


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/state":
            self.reply(200, {"journeys": sorted(journeys), "waypoints": sorted(waypoints), "requests": requests})
        else:
            self.reply(404, {"detail": "Not Found"})

    def do_POST(self):
        global requests
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path == "/reset":
            journeys.clear()
            waypoints.clear()
            requests = 0
            self.reply(200, {})
            return
        if self.path != "/sync":
            self.reply(404, {"detail": "Not Found"})
            return
        requests += 1
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
