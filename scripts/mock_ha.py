#!/usr/bin/env python3
"""Mock Home Assistant REST API for homedash development.

Replays responses captured from a real HA 2026.10 (spec/fixtures/ha, see
docs/ha-api.md and scripts/capture_ha.sh) byte-for-byte where possible:
same status lines, same headers (order included), same compact JSON bodies,
same error texts. Python standard library only.

    python3 scripts/mock_ha.py                    # http://127.0.0.1:8123, token "mock-token"
    python3 scripts/mock_ha.py --port 8124 --token abc --live

Extra, non-HA endpoints for tests (no auth):
    GET  /__mock/calls              service calls received so far (JSON list)
    POST /__mock/reset              reload fixtures, clear calls and scenario
    POST /__mock/state              {"entity_id": "...", "state": "...", "attributes": {...}?}
    POST /__mock/scenario           {"delay_s": 3, "force_401": false, "unavailable": false}

Simulated behaviour (fixtures/ha/mock_rules.json): calling a configured
script/switch schedules state changes, e.g. script.otworz_garaz turns
binary_sensor.brama_garazowa "on" after a few seconds. Nothing here talks
to a real Home Assistant.
"""
import argparse
import copy
import json
import os
import random
import string
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FIXTURES = os.path.join(ROOT, "spec", "fixtures", "ha")

# Real HA (aiohttp) header order, as captured.
COMMON_HEADERS = [
    ("Referrer-Policy", "no-referrer"),
    ("X-Content-Type-Options", "nosniff"),
    ("Server", ""),
    ("X-Frame-Options", "SAMEORIGIN"),
]
CT_JSON = "application/json"
CT_TEXT = "text/plain; charset=utf-8"
REASONS = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
           405: "Method Not Allowed", 500: "Internal Server Error"}

# Services the mock knows. Value: True = response-only (needs ?return_response).
SERVICES = {
    "weather.get_forecasts": True,
    "homeassistant.update_entity": False,
    "homeassistant.turn_on": False, "homeassistant.turn_off": False, "homeassistant.toggle": False,
    "switch.turn_on": False, "switch.turn_off": False, "switch.toggle": False,
    "input_boolean.turn_on": False, "input_boolean.turn_off": False, "input_boolean.toggle": False,
    "light.turn_on": False, "light.turn_off": False, "light.toggle": False,
    "script.turn_on": False, "script.turn_off": False, "script.toggle": False,
    "cover.open_cover": False, "cover.close_cover": False, "cover.toggle": False,
    "climate.set_temperature": False,
}


def dumps(obj):
    """HA serializes with orjson: compact, UTF-8, no ASCII escaping."""
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def iso_now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def ulid_like():
    return "".join(random.choice("0123456789ABCDEFGHJKMNPQRSTVWXYZ") for _ in range(26))


def parse_dt(s):
    return datetime.fromisoformat(s)


def fmt_dt(d):
    return d.astimezone(timezone.utc).isoformat()  # "2026-11-19T16:00:00+00:00"


class Store:
    def __init__(self, fixtures, shift=True):
        self.fixtures = fixtures
        self.shift = shift
        self.lock = threading.Lock()
        self.load()

    def load(self):
        with self.lock:
            self.states = {}
            sdir = os.path.join(self.fixtures, "states")
            for name in sorted(os.listdir(sdir)):
                if name.endswith(".json"):
                    with open(os.path.join(sdir, name), encoding="utf-8") as f:
                        st = json.load(f)
                    self.states[st["entity_id"]] = st
            self.forecasts = {}
            for kind in ("hourly", "daily"):
                p = os.path.join(self.fixtures, "forecast_%s.json" % kind)
                if os.path.exists(p):
                    with open(p, encoding="utf-8") as f:
                        self.forecasts[kind] = json.load(f)
            p = os.path.join(self.fixtures, "mock_rules.json")
            self.rules = {}
            if os.path.exists(p):
                with open(p, encoding="utf-8") as f:
                    self.rules = json.load(f)
            self.calls = []
            self.scenario = {"delay_s": 0, "force_401": False, "unavailable": False}

    def get(self, entity_id):
        with self.lock:
            st = self.states.get(entity_id)
            if st is None:
                return None
            st = copy.deepcopy(st)
        if self.scenario["unavailable"] and not entity_id.startswith(("weather.", "script.")):
            st["state"] = "unavailable"
        return st

    def all(self):
        with self.lock:
            ids = list(self.states)
        return [self.get(i) for i in ids]

    def set_state(self, entity_id, state, attributes=None, user_id=None):
        """Mimics HA: last_changed only moves when state changes."""
        with self.lock:
            st = self.states.get(entity_id)
            if st is None:
                return None
            now = iso_now()
            changed = st["state"] != state or (attributes is not None and attributes != st["attributes"])
            if not changed:
                st["last_reported"] = now
                return None
            if st["state"] != state:
                st["last_changed"] = now
            st["state"] = state
            if attributes is not None:
                st["attributes"] = attributes
            st["last_updated"] = now
            st["last_reported"] = now
            st["context"] = {"id": ulid_like(), "parent_id": None, "user_id": user_id}
            return copy.deepcopy(st)

    def forecast(self, kind, entity_id):
        """Forecast fixture with datetimes moved so it starts 'now', like a fresh met.no reply."""
        with self.lock:
            data = copy.deepcopy(self.forecasts.get(kind))
        if data is None:
            return None
        resp = data["service_response"]
        src_entity = next(iter(resp))
        items = resp.pop(src_entity)["forecast"]
        if self.shift and items:
            now = datetime.now(timezone.utc)
            first = parse_dt(items[0]["datetime"])
            if kind == "hourly":
                target = now.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
            else:
                target = now.replace(hour=first.hour, minute=first.minute, second=0, microsecond=0)
            delta = target - first
            for it in items:
                it["datetime"] = fmt_dt(parse_dt(it["datetime"]) + delta)
        resp[entity_id] = {"forecast": items}
        return data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    store = None
    token = None
    verbose = True

    # ---- low level -------------------------------------------------------
    def log_message(self, fmt, *args):
        if self.verbose:
            sys.stderr.write("[mock_ha] %s %s\n" % (self.address_string(), fmt % args))

    def send_raw(self, status, body, ctype=CT_JSON, extra=(), pre=()):
        if isinstance(body, str):
            body = body.encode("utf-8")
        lines = ["HTTP/1.1 %d %s" % (status, REASONS.get(status, ""))]
        for k, v in pre:  # real HA puts WWW-Authenticate before Content-Type
            lines.append("%s: %s" % (k, v))
        lines.append("Content-Type: %s" % ctype)
        for k, v in extra:
            lines.append("%s: %s" % (k, v))
        for k, v in COMMON_HEADERS:
            lines.append("%s: %s" % (k, v))
        lines.append("Content-Length: %d" % len(body))
        lines.append("Date: %s" % formatdate(usegmt=True))
        head = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")
        self.wfile.write(head + body)
        self.wfile.flush()
        self.log_request(status, len(body))

    def json(self, status, obj):
        self.send_raw(status, dumps(obj))

    def text_error(self, status, extra=(), pre=()):
        # aiohttp default error body, e.g. "400: Bad Request"
        self.send_raw(status, "%d: %s" % (status, REASONS[status]), CT_TEXT, extra, pre)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def base_url(self):
        host = self.headers.get("Host") or "%s:%d" % self.server.server_address[:2]
        return "http://%s" % host

    def authorized(self):
        if self.store.scenario["force_401"]:
            return False
        return self.headers.get("Authorization", "") == "Bearer %s" % self.token

    def unauthorized(self):
        self.text_error(401, pre=[("WWW-Authenticate",
            'Bearer resource_metadata="%s/.well-known/oauth-protected-resource"' % self.base_url())])

    def delay(self):
        d = self.store.scenario.get("delay_s") or 0
        if d:
            time.sleep(d)

    # ---- dispatch --------------------------------------------------------
    def do_GET(self):
        self.close_connection = True
        url = urlsplit(self.path)
        if url.path == "/__mock/calls":
            return self.json(200, self.store.calls)
        if not url.path.startswith("/api/"):
            return self.send_raw(404, "404: Not Found", CT_TEXT)
        if not self.authorized():
            return self.unauthorized()
        self.delay()
        if url.path == "/api/":
            return self.json(200, {"message": "API running."})
        if url.path == "/api/states":
            return self.json(200, self.store.all())
        if url.path.startswith("/api/states/"):
            st = self.store.get(url.path[len("/api/states/"):])
            if st is None:
                return self.json(404, {"message": "Entity not found."})
            return self.json(200, st)
        if url.path.startswith("/api/services/"):
            return self.text_error(405, [("Allow", "OPTIONS,POST")])
        return self.send_raw(404, "404: Not Found", CT_TEXT)

    def do_POST(self):
        self.close_connection = True
        url = urlsplit(self.path)
        raw = self.read_body()
        if url.path.startswith("/__mock/"):
            return self.mock_control(url.path, raw)
        if not self.authorized():
            return self.unauthorized()
        self.delay()
        if not url.path.startswith("/api/services/"):
            return self.text_error(405, [("Allow", "GET,HEAD,OPTIONS")])
        parts = url.path[len("/api/services/"):].split("/")
        if len(parts) != 2:
            return self.send_raw(404, "404: Not Found", CT_TEXT)
        domain, service = parts
        try:
            data = json.loads(raw.decode("utf-8")) if raw.strip() else {}
        except (ValueError, UnicodeDecodeError):
            return self.json(400, {"message": "Data should be valid JSON."})
        return_response = "return_response" in parse_qs(url.query, keep_blank_values=True)
        return self.call_service(domain, service, data, return_response)

    # ---- services --------------------------------------------------------
    def call_service(self, domain, service, data, return_response):
        key = "%s.%s" % (domain, service)
        script_direct = domain == "script" and self.store.get("script." + service) is not None
        if key not in SERVICES and not script_direct:
            return self.text_error(400)  # real HA: unknown service -> text "400: Bad Request"
        self.store.calls.append({"t": iso_now(), "service": key, "data": data,
                                 "return_response": return_response})
        response_only = SERVICES.get(key, False)
        if response_only and not return_response:
            return self.json(400, {"message": "Service call requires responses but caller did not ask "
                                              "for responses. Add ?return_response to query parameters."})
        if return_response and not response_only:
            return self.json(400, {"message": "Service does not support responses. "
                                              "Remove return_response from request."})
        if key == "weather.get_forecasts":
            return self.get_forecasts(data)

        ids = data.get("entity_id", [])
        if isinstance(ids, str):
            ids = [i.strip() for i in ids.split(",")]
        if script_direct:
            ids = ["script." + service]
            service = "turn_on"
        if key == "homeassistant.update_entity" and not ids:
            return self.send_raw(500, "Server got itself in trouble", CT_TEXT)

        changed = []
        for eid in ids:
            st = self.store.get(eid)
            if st is None:
                continue  # real HA ignores unknown entities: 200 []
            rule = self.store.rules.get(eid)
            if rule and service in ("turn_on", "toggle", "open_cover", "close_cover"):
                changed += self.run_rule(rule)
                continue
            new = None
            if service in ("turn_on", "open_cover"):
                new = "open" if domain == "cover" else "on"
            elif service in ("turn_off", "close_cover"):
                new = "closed" if domain == "cover" else "off"
            elif service == "toggle":
                new = {"on": "off", "off": "on", "open": "closed", "closed": "open"}.get(st["state"], "on")
            elif service == "set_temperature" and "temperature" in data:
                attrs = dict(st["attributes"], temperature=data["temperature"])
                s = self.store.set_state(eid, st["state"], attrs)
                if s:
                    changed.append(s)
                continue
            if new is not None:
                s = self.store.set_state(eid, new)
                if s:
                    changed.append(s)
        # Plain service call: HA returns the list of states changed during the call.
        return self.json(200, changed)

    def run_rule(self, steps):
        """steps: [{"after": seconds, "entity_id": ..., "state": ...}, ...]; after==0 is synchronous."""
        changed = []
        for step in steps:
            if step.get("after", 0) <= 0:
                s = self.store.set_state(step["entity_id"], step["state"])
                if s:
                    changed.append(s)
            else:
                t = threading.Timer(step["after"], self.store.set_state, (step["entity_id"], step["state"]))
                t.daemon = True
                t.start()
        return changed

    def get_forecasts(self, data):
        kind = data.get("type")
        eid = data.get("entity_id")
        if kind not in ("hourly", "daily", "twice_daily") or not eid:
            return self.text_error(400)
        st = self.store.get(eid) if isinstance(eid, str) else None
        if st is None or not eid.startswith("weather."):
            return self.json(500, {"message": "Service call requested response data but did not match any entities"})
        fc = self.store.forecast(kind, eid)
        if fc is None:
            return self.json(500, {"message": "Weather entity '%s' does not support '%s' forecast" % (eid, kind)})
        return self.json(200, fc)

    # ---- mock control ----------------------------------------------------
    def mock_control(self, path, raw):
        try:
            data = json.loads(raw.decode("utf-8")) if raw.strip() else {}
        except ValueError:
            return self.json(400, {"message": "bad json"})
        if path == "/__mock/reset":
            self.store.load()
            return self.json(200, {"ok": True})
        if path == "/__mock/state":
            s = self.store.set_state(data["entity_id"], data["state"], data.get("attributes"))
            return self.json(200, s or self.store.get(data["entity_id"]))
        if path == "/__mock/scenario":
            self.store.scenario.update(data)
            return self.json(200, self.store.scenario)
        return self.send_raw(404, "404: Not Found", CT_TEXT)


def live_drift(store, entity_id, every):
    """Nudge a temperature sensor every `every` seconds so refresh is visible."""
    while True:
        time.sleep(every)
        st = store.get(entity_id)
        if not st:
            return
        try:
            v = float(st["state"]) + random.choice((-0.1, 0.1, 0.2, -0.2))
        except ValueError:
            continue
        store.set_state(entity_id, "%.1f" % v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("HOMEDASH_MOCK_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("HOMEDASH_MOCK_PORT", "8123")))
    ap.add_argument("--token", default=os.environ.get("HOMEDASH_MOCK_TOKEN", "mock-token"))
    ap.add_argument("--fixtures", default=DEFAULT_FIXTURES)
    ap.add_argument("--no-shift", action="store_true", help="serve forecast datetimes exactly as captured")
    ap.add_argument("--live", action="store_true", help="drift the outdoor temperature every 60 s")
    ap.add_argument("--live-entity", default="sensor.prologue_th_5_1_142_temperature")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    Handler.store = Store(a.fixtures, shift=not a.no_shift)
    Handler.token = a.token
    Handler.verbose = not a.quiet
    if a.live:
        threading.Thread(target=live_drift, args=(Handler.store, a.live_entity, 60), daemon=True).start()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    srv.daemon_threads = True
    sys.stderr.write("[mock_ha] http://%s:%d  token=%s  entities=%d\n"
                     % (a.host, a.port, a.token, len(Handler.store.states)))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
