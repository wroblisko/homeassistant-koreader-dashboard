# Configuration reference

The config is a Lua file named `homedash_config.lua` in KOReader's settings directory
(on a Kindle `/mnt/us/koreader/settings/homedash_config.lua`). It is loaded each time the dashboard
opens and must `return` one table. The commented template is
[`homedash.koplugin/config.example.lua`](../homedash.koplugin/config.example.lua); copy that file.

For development, the environment variable `HOMEDASH_CONFIG=/abs/path.lua` points to another file
(see [development.md](development.md)).

If the file is missing, cannot be parsed, raises an error or fails validation, the dashboard shows the
message on screen (with the expected path) instead of the card. Validation errors name the place, for
example `sections[6].items[1]: action needs service`.

```lua
return {
    ha       = { url = "...", token = "...", timeout = 5 },
    refresh  = { states_min = 5, forecast_min = 30, full_every = 6, after_action_s = 5 },
    locale   = { lang = "en" },
    sections = { ... },
}
```

## `ha`

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `url` | yes | | Base URL, `http://<ip>:8123`. Use the LAN IP, not a `.local` name. |
| `token` | yes | | Long-lived access token (a string). Read it from a file so the config holds no secret: see the example's `read_token()`. |
| `timeout` | no | `5` | Seconds per HTTP request. |

After the first network error (refused, timeout) the rest of that refresh is skipped.

## `refresh`

| Key | Default | Meaning |
| --- | --- | --- |
| `states_min` | `5` | Minutes between automatic refreshes of entity states (the whole screen is redrawn). |
| `forecast_min` | `30` | Minutes between forecast fetches. A forecast is only re-fetched when due. |
| `full_every` | `6` | Every N-th automatic redraw is a full e-ink flash that clears ghosting. `0` disables it. |
| `after_action_s` | `5` | Seconds after a button press before states are re-read, so the new state shows. |

The **Refresh** button and waking the device from suspend (after a 3 second delay for Wi-Fi) fetch
everything immediately, ignoring the intervals, and do a full flash.

## `locale`

All keys are optional.

| Key | Default | Meaning |
| --- | --- | --- |
| `lang` | `"en"` | Built-in language of the UI strings: `"en"` or `"pl"`. An unknown value behaves like `"en"`. |
| `decimal` | `"."` for `en`, `","` for `pl` | Decimal mark in numbers. |
| `days` | follows `lang` | Seven weekday abbreviations, **Sunday first**, for the header date and the daily forecast. |
| `strings` | none | `{ key = "text" }` overrides for single UI strings (keys below). |
| `utc_offset_min` | device clock | Minutes from UTC used for all clock times. Set it when the device clock runs on UTC (for example `60` in winter, `120` in summer for Central Europe). |

Lookup order for a UI string: `locale.strings` -> the language table -> `en` -> the key itself. Labels,
titles, `map` texts and `confirm` texts in the config are **your data** and are shown as written; they
are never translated.

Example, English with a comma and custom words:

```lua
locale = { lang = "en", decimal = ",", strings = { today = "Now", refresh = "Reload" } }
```

### UI string keys

Strings with `%s` or `%d` receive a value (a clock time, a number).

| Key | `en` | Used for |
| --- | --- | --- |
| `refresh`, `close` | Refresh, Close | Header buttons and the config-error screen |
| `sent` | Sent | Notice after a service call succeeded |
| `actions_off` | Actions disabled (test mode) | Notice when `HOMEDASH_ACTIONS=off` |
| `no_action` | No action | Button with no action for the current state |
| `no_data`, `no_forecast` | no data, no forecast | Empty weather block, chart or daily rows |
| `wifi_off` | off | Next to the Wi-Fi icon when Wi-Fi is off |
| `humidity`, `pressure` | humidity, pressure | Labels in the weather block |
| `now` | now %s | Chart caption, with the clock time |
| `sunrise`, `sunset` | sunrise %s, sunset %s | Chart captions |
| `today` | Today | First row of the daily forecast |
| `updated`, `updated_short` | updated %s, upd. %s | Footer after a successful refresh |
| `every_min` | every %d min | Footer, right side (`refresh.states_min`) |
| `offline`, `error`, `error_code` | offline, error, error %s | Footer after a failed refresh |
| `config_not_found`, `config_cannot_open`, `config_error` | | Config load errors |
| `cond.<code>` | | Weather condition text, used when a condition has no icon: `clear-night`, `cloudy`, `exceptional`, `fog`, `hail`, `lightning`, `lightning-rainy`, `partlycloudy`, `pouring`, `rainy`, `snowy`, `snowy-rainy`, `sunny`, `windy`, `windy-variant` |
| `compass.1` ... `compass.8` | N, NE, E, SE, S, SW, W, NW | Wind direction next to the speed |

The full tables are in [`homedash_i18n.lua`](../homedash.koplugin/homedash_i18n.lua). To add a language,
add a table there (and `DECIMAL` and `DAYS` entries); see [AGENTS.md](../AGENTS.md).

## `sections`

A list of tables, drawn from top to bottom. Each has a `type`. The screen height is divided between the
sections by weight (the chart gets the most, the footer the least), with a minimum height per type, so
the same config adapts to every screen size. Any order and repetition is allowed, though a card
normally has one header and one footer.

### `header`

Title (left), date and time, battery and Wi-Fi, and the Refresh and Close buttons.

| Key | Meaning |
| --- | --- |
| `title` | Text in bold. Default empty. |

### `weather_now`

Large weather icon and temperature, plus humidity, wind (km/h and compass direction) and pressure.

| Key | Required | Meaning |
| --- | --- | --- |
| `weather` | yes | A `weather.*` entity. Condition, humidity, wind and pressure come from its attributes. |
| `temperature` | no | A sensor entity whose state replaces the weather entity's own temperature (an outdoor sensor is usually more accurate). |

Wind in `m/s` or `mph` is converted to km/h; an unknown unit hides the wind row.

### `chart`

Hourly forecast: temperature line with value labels, precipitation bars (right axis), hourly condition
data, a grid, and captions for "now" and for sunrise and sunset.

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `weather` | yes | | A `weather.*` entity that supports hourly forecasts. |
| `sun` | no | | The `sun.sun` entity. Shades the night and prints sunrise and sunset. |
| `hours` | no | `18` | Length of the window starting now. |

### `daily`

One row per day, today first: weekday (or "Today"), condition icon, high, "feels like" (hand icon),
low (moon icon) and precipitation.

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `weather` | yes | | A `weather.*` entity that supports daily forecasts. |
| `days` | no | `4` | Number of rows. |

"Feels like" is computed per day from the high, wind and humidity: wind chill at or below 10 degrees C
with wind over 4.8 km/h, heat index at or above 27 degrees C with a known humidity, otherwise the
temperature itself.

### `values`

A grid of `label ... value` cells, filled row by row.

| Key | Default | Meaning |
| --- | --- | --- |
| `columns` | `2` | Cells per row. |
| `items` | required | List of items (below). |

| Item key | Required | Meaning |
| --- | --- | --- |
| `entity` | yes | Entity id. |
| `label` | no | Text on the left. |
| `attribute` | no | Show this attribute instead of the entity's state. |
| `unit` | no | Text appended to a numeric value, for example `"°"` or `" %"`. |
| `map` | no | `{ state = "text" }`. `_` is the fallback; without a match the value is `—`. |

Numbers are shown with at most one decimal and the locale's decimal mark (`20.8`, `20,8`). An entity
whose state is `unavailable` or `unknown` shows `—` for every derived value (a `map` key for that exact
state is the one exception).

```lua
{ type = "values", columns = 2, items = {
    { label = "Living room", entity = "climate.living_room", attribute = "current_temperature", unit = "°" },
    { label = "Humidity", entity = "sensor.humidity", unit = " %" },
    { label = "Alarm", entity = "alarm_control_panel.house",
      map = { disarmed = "off", armed_away = "ARMED", _ = "?" } },
}}
```

### `buttons`

A row (or rows) of big buttons.

| Key | Default | Meaning |
| --- | --- | --- |
| `columns` | `2` | Buttons per row. |
| `items` | required | List of buttons (below). |

| Item key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique id. Also used by the `HOMEDASH_AUTOACTION` dev hook. |
| `label` | no | Bold text under the icon. |
| `icon` | no | Icon name from `homedash.koplugin/icons/` without `.svg`: `garage-closed`, `garage-open`, `gate`, `gate-all`. |
| `action` | yes | What a tap does (below). |
| `state` | no | A live caption and icon (below). |

#### `action`

Either one table:

```lua
action = { service = "switch.turn_on", data = { entity_id = "switch.driveway_gate" },
           confirm = "Open the gate?" }
```

- `service`: `domain.service`, called as `POST /api/services/<domain>/<service>`.
- `data`: the JSON body, usually `{ entity_id = "..." }` plus any service fields.
- `confirm`: optional. A confirmation dialog with this text appears first; without it the call happens
  at once. Use it for anything that opens a door.

Or a table **keyed by the state** of `state.entity`, so the same button can do different things:

```lua
action = {
    on  = { service = "script.turn_on", data = { entity_id = "script.close_garage" }, confirm = "Close the garage?" },
    off = { service = "script.turn_on", data = { entity_id = "script.open_garage" },  confirm = "Open the garage?" },
    -- _ = { ... }   -- fallback for any other state, for example "unavailable"
}
```

If no branch matches the current state (and there is no `_`), the tap shows the `no_action` notice.
A state-keyed action needs `state.entity`.

After a successful call the dashboard shows "Sent" and, `refresh.after_action_s` seconds later, re-reads
the states so the button shows the result. A failed call shows a short error and also sets the footer.

#### `state`

```lua
state = { entity = "binary_sensor.garage_door",
          map = { on  = { text = "Open",   icon = "garage-open",   style = "inverted" },
                  off = { text = "Closed", icon = "garage-closed" },
                  _   = { text = "?" } } }
```

- `entity`: the entity whose state is read.
- `map`: state to `{ text, icon, style }` (or just a string for the text). `text` is the small caption
  under the label. `icon` replaces the button's `icon` for that state. `style = "inverted"` draws the
  button white on black, which is how the eye finds "open" on e-ink. `_` is the fallback; an
  unavailable or unknown entity uses it. If the entity could not be read at all, the caption is `—`.

### `footer`

Status line: `updated 12:05`, or `error 401 · 12:05` / `offline · 12:05` after a failed refresh (the last
good data stays on screen), and `every N min` on the right. No keys.

## Complete example

See [`config.example.lua`](../homedash.koplugin/config.example.lua) (English, generic entity ids) and
[`dev/config.mock.en.lua`](../dev/config.mock.en.lua) / [`dev/config.mock.lua`](../dev/config.mock.lua)
(the card used for the screenshots, English and Polish).
