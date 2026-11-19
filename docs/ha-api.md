# Home Assistant REST API: what homedash uses, exactly as HA returns it

Captured on 2026-11-19 from a real Home Assistant **2026.10.4** (time zone Europe/Warsaw,
met.no weather integration) over plain HTTP on the LAN, which is how the Kindle will talk to it.
The raw responses (status line, headers, body) are in `spec/fixtures/ha/raw/*.http`.
`Date` was dropped and the HA address was replaced with `{HA_URL}`.
Entity states are in `spec/fixtures/ha/states/<entity_id>.json` and forecasts in
`spec/fixtures/ha/forecast_{hourly,daily}.json`.
To re-capture from your own HA, run `scripts/capture_ha.sh`, which is read-only.
The fixtures come from a real Home Assistant, so entity names are realistic (Polish friendly names). The user
ids in `context.user_id` were replaced with dummy values; nothing else was altered.

`scripts/mock_ha.py` replays these 1:1. `scripts/check_mock.sh` diffs the mock against the captures.

## Transport

- Base URL: `http://<ha-host>:8123`. HTTP/1.1, no chunking, and every response carries `Content-Length`.
- Every request needs `Authorization: Bearer <long-lived access token>`. Create the token on a
  dedicated non-admin HA user (Profile → Security → Long-lived access tokens).
- For POST, send `Content-Type: application/json` and a JSON body.
- Bodies are compact UTF-8 JSON with no spaces and no `\u` escaping, so `"°C"` and `"garażowa"` are raw UTF-8.
- Headers on every response, in this order:
  ```
  Content-Type: application/json            (or text/plain; charset=utf-8 for plain errors)
  Referrer-Policy: no-referrer
  X-Content-Type-Options: nosniff
  Server:
  X-Frame-Options: SAMEORIGIN
  Content-Length: N
  Date: ...
  ```
- Behind a reverse proxy (here Cloudflare) the same bodies arrive over HTTP/2 with extra headers.
  Do not depend on headers other than the status code and Content-Type.
- KOReader's `socket.http` + `ltn12` + `rapidjson` parse these fine. This was verified against the mock with the
  emulator's luajit. In the plugin, use `socketutil` timeouts (as other KOReader plugins do).

## 1. `GET /api/` — health check
`200`, JSON: `{"message":"API running."}`

## 2. `GET /api/states/<entity_id>` — one entity

`200` returns a state object:
```json
{"entity_id":"sensor.prologue_th_5_1_142_temperature","state":"9.2",
 "attributes":{"state_class":"measurement","unit_of_measurement":"°C","device_class":"temperature",
               "friendly_name":"Prologue-TH-5-1-142 Temperature"},
 "last_changed":"2026-11-19T15:33:15.055808+00:00","last_reported":"2026-11-19T15:33:15.055808+00:00",
 "last_updated":"2026-11-19T15:33:15.055808+00:00",
 "context":{"id":"01M7T71JNFXN7N84DESRG4Q64G","parent_id":null,"user_id":null}}
```

Rules that matter for the plugin:
- **`state` is always a string**, numeric sensors included (`"9.2"`, `"11"`). Parse it with `tonumber`.
- A device that is offline still returns `200`, with `"state":"unavailable"` (or `"unknown"`).
  Attributes stay present.
  See `sensor.temperature_humidity_sensor_39c2_temperature.json` and `sensor.miaomiaoc_…json`.
- **Attributes are typed JSON**: numbers are numbers (`"current_temperature":20.8`) and lists are arrays.
- Timestamps are ISO 8601 in UTC with microseconds and `+00:00`.
  `last_changed` moves only when `state` changes. `last_updated` also moves on attribute changes.
- `404` returns JSON `{"message":"Entity not found."}`.

States by domain (all in the fixtures):

| entity | state | useful attributes |
|---|---|---|
| `sensor.prologue_th_5_1_142_temperature` | `"9.2"` | `unit_of_measurement` `°C`, `device_class` temperature |
| `weather.forecast_dom` | condition, e.g. `"cloudy"` | `temperature` 11.0, `humidity` 74, `pressure` 993.1, `wind_speed` 6.8 (`wind_speed_unit` km/h), `wind_bearing`, `cloud_coverage`, `uv_index`, `dew_point`, `precipitation_unit` mm, `supported_features` 3 (=daily+hourly) |
| `binary_sensor.brama_garazowa` | `"off"` / `"on"` (off = closed) | `device_class` opening, `icon` `mdi:garage-variant` |
| `script.otworz_garaz`, `script.zamknij_garaz` | `"off"`, `"on"` while running | `last_triggered`, `mode` single, `icon` |
| `switch.brama_ogrodzeniowa_switch` | `"off"`/`"on"` | — (there is no gate position sensor) |
| `climate.termostat` | hvac mode `"auto"`/`"heat"`/`"off"` | `current_temperature` 20.8, `temperature` (setpoint) 20.5, `hvac_action` `"idle"`/`"heating"` |
| `sun.sun` | `"below_horizon"` / `"above_horizon"` | `next_rising`, `next_setting` (UTC ISO; used for chart night shading), `next_dawn`, `next_dusk`, `elevation` |
| `alarm_control_panel.garaz` | `"disarmed"`/`"armed_away"`/… | |

## 3. `GET /api/states` — all entities
`200`: a JSON array of the state objects above. On a real install it is large (hundreds of KB).
**Do not use it on the Kindle**; fetch the configured entities one by one instead.

## 4. Forecast: `POST /api/services/weather/get_forecasts?return_response`

Request body: `{"entity_id":"weather.forecast_dom","type":"hourly"}` (or `"daily"`).
The `?return_response` query flag is mandatory.

`200`:
```json
{"changed_states":[],
 "service_response":{"weather.forecast_dom":{"forecast":[
   {"condition":"cloudy","datetime":"2026-11-19T16:00:00+00:00","wind_bearing":110.9,
    "cloud_coverage":100.0,"uv_index":0.0,"temperature":10.9,"wind_speed":6.8,
    "precipitation":0.0,"humidity":74},
   ...]}}}
```

- **Hourly**: 48 items. The first is the next full hour (captured at 15:34 UTC, first slot 16:00 UTC).
  Keys are `condition, datetime, temperature, precipitation (mm in that hour), wind_speed,
  wind_bearing, cloud_coverage, humidity, uv_index`.
  met.no gives **no `precipitation_probability`**, so the chart uses `precipitation` in mm.
- **Daily**: 6 items. The first is **today**. `datetime` is `11:00 UTC` (local midday) for every day.
  Keys are the hourly ones plus `templow` (min), where `temperature` is the max. Daily items have no `cloud_coverage`.
- `datetime` is always UTC. Convert to local time for labels (HA is in Europe/Warsaw, UTC+1 in winter).
  On the Kindle, do not assume the device TZ is set; make the UTC offset configurable or derive it.
- Treat every numeric field as optional (other integrations omit some).
- `condition` values HA may return: `clear-night, cloudy, exceptional, fog, hail, lightning,
  lightning-rainy, partlycloudy, pouring, rainy, snowy, snowy-rainy, sunny, windy, windy-variant`.
  This capture had `cloudy, partlycloudy, rainy, clear-night`.

Errors (captured):

| request | status | Content-Type | body |
|---|---|---|---|
| without `?return_response` | 400 | json | `{"message":"Service call requires responses but caller did not ask for responses. Add ?return_response to query parameters."}` |
| `"type":"twice_daily"` (unsupported by met.no) | 500 | json | `{"message":"Weather entity 'weather.forecast_dom' does not support 'twice_daily' forecast"}` |
| unknown weather entity | 500 | json | `{"message":"Service call requested response data but did not match any entities"}` |
| missing `type` | 400 | text | `400: Bad Request` |

## 5. Actions: `POST /api/services/<domain>/<service>`

Body: `{"entity_id":"script.otworz_garaz"}` plus any service data, for example
`{"entity_id":"climate.termostat","temperature":21}`.
`POST /api/services/script/otworz_garaz` with `{}` also runs the script.

- `200` returns a **JSON array of states that changed while the call ran**. It is often `[]`, for example
  `homeassistant/update_entity` gave `[]`, as does a call naming a non-existent entity.
  The array is **not** a success flag. The change you care about (gate actually opening) usually
  comes seconds later; poll the state entity after `after_action_s`.
- The call returns once the service finishes; a script with delays can hold the request.
  Use a timeout and treat a timeout as "maybe done, refresh later", not as failure.
- Do not send `?return_response` to normal services: you get `400` JSON
  `{"message":"Service does not support responses. Remove return_response from request."}`.

Errors (captured):

| case | status | Content-Type | body |
|---|---|---|---|
| unknown domain/service | 400 | text | `400: Bad Request` |
| body is not JSON | 400 | json | `{"message":"Data should be valid JSON."}` |
| `GET` instead of `POST` | 405 | text (+ `Allow: OPTIONS,POST`) | `405: Method Not Allowed` |
| service raised (e.g. `update_entity` without entity_id) | 500 | text | `Server got itself in trouble` |

## 6. Auth errors
Missing or wrong token gives `401`, `text/plain; charset=utf-8`, body `401: Unauthorized`, plus
`WWW-Authenticate: Bearer resource_metadata="{HA_URL}/.well-known/oauth-protected-resource"`.
(`POST /api/template` works only for admin users; homedash does not use it.)

## 7. Network-level failures (not HTTP)
These are not captured, but the client must handle them:
- HA down or wrong host: connection refused, or a timeout on the Kindle when Wi‑Fi is still waking up.
- Wi‑Fi off: DNS failure. Prefer an IP address in the config.

The client should map all of these, plus 401, 404, 5xx and invalid JSON, to a visible but
non-blocking error (for example, the footer shows "offline 12:05") and keep showing the last good data.

## Mock server

```
python3 scripts/mock_ha.py                 # http://127.0.0.1:8123, token "mock-token"
python3 scripts/mock_ha.py --live          # outdoor temp drifts every 60 s
python3 scripts/mock_ha.py --no-shift      # forecast datetimes exactly as captured
bash scripts/check_mock.sh                 # mock == captured real responses
```

The mock behaves like HA in these ways:
- It serves the state fixtures and the 404/401/400/405/500 errors above, byte-identical.
- It shifts forecast datetimes so the hourly forecast starts at the next full hour and the daily one starts today.
- Service calls change state:
  - `switch|light|input_boolean` → on/off/toggle; `cover` → open/closed; `climate.set_temperature` → setpoint.
  - Rules in `spec/fixtures/ha/mock_rules.json` add timed effects. `script.otworz_garaz` runs for 4 s, then
    `binary_sensor.brama_garazowa` becomes `on`. `script.zamknij_garaz` sets it back to `off`.
- The response lists only the states changed synchronously, like HA does.

Test-only endpoints, which need no auth:
- `GET /__mock/calls` lists the service calls received.
- `POST /__mock/reset` reloads the fixtures.
- `POST /__mock/state {"entity_id","state","attributes"?}` sets a state.
- `POST /__mock/scenario {"delay_s":N,"force_401":bool,"unavailable":bool}` changes behaviour:
  - `delay_s` makes responses slow.
  - `force_401` makes every request fail with 401.
  - `unavailable` turns every sensor `unavailable`.
- To simulate "HA down", stop the mock.
