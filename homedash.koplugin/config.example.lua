--[[--
homedash configuration reference (copy me).

Copy this file to KOReader's settings directory as `homedash_config.lua`
(on a Kindle: /mnt/us/koreader/settings/homedash_config.lua). The dashboard
prints the exact path on screen when it cannot find the file.

The file is plain Lua and must `return` one table. Everything marked
"required" has to be there, the rest has defaults. Full reference:
docs/configuration.md.

Security: the token gives API access to your Home Assistant. Use a long-lived
token of a dedicated NON-ADMIN user that may only log in from the local
network, and keep the token out of this file (see read_token below).
]]

-- Read the long-lived token from a file next to the config, so the config
-- itself can be shared or pasted into an issue. One line, no quotes.
local function read_token()
    local path = "/mnt/us/koreader/settings/homedash.token"
    local f = io.open(path, "rb")
    if not f then
        error("Token file not found:\n" .. path, 0) -- shown on the dashboard
    end
    local raw = f:read("*a") or ""
    f:close()
    local token = raw:gsub("%s+", "")
    if token == "" then
        error("Token file is empty:\n" .. path, 0)
    end
    return token
end

return {
    ---------------------------------------------------------------------
    -- Home Assistant connection
    ---------------------------------------------------------------------
    ha = {
        -- required. Use the LAN IP: ".local" (mDNS) names usually do not
        -- resolve on a Kindle. Give the HA host a DHCP reservation.
        url = "http://192.168.1.10:8123",
        -- required. A plain string works too: token = "eyJ...".
        token = read_token(),
        -- seconds per HTTP request (default 5). After the first network
        -- error the whole refresh stops, so a dead HA costs one timeout.
        timeout = 5,
    },

    ---------------------------------------------------------------------
    -- Refresh behaviour (all optional, defaults shown)
    ---------------------------------------------------------------------
    refresh = {
        states_min = 5,     -- fetch entity states every N minutes
        forecast_min = 30,  -- fetch weather forecasts every N minutes
        full_every = 6,     -- full e-ink flash every N refreshes (clears ghosting)
        after_action_s = 5, -- seconds after a button press to re-read states
    },

    ---------------------------------------------------------------------
    -- Language and formatting (all optional)
    ---------------------------------------------------------------------
    locale = {
        lang = "en",        -- built-in: "en" (default) or "pl"
        -- decimal = ",",   -- decimal mark; default follows lang ("." en, "," pl)
        -- utc_offset_min = 60, -- minutes from UTC. Default: the device clock's own
        --                      -- offset. Set it when the Kindle clock runs on UTC
        --                      -- (60 in winter, 120 in summer for Central Europe).
        -- days = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }, -- Sunday first
        -- strings = { refresh = "Reload", today = "Now" },  -- override single UI strings
    },

    ---------------------------------------------------------------------
    -- The card: sections are stacked top to bottom, heights are shared out
    -- by weight. Types: header, weather_now, chart, daily, values, buttons,
    -- footer. Labels and texts below are yours; they are never translated.
    ---------------------------------------------------------------------
    sections = {
        -- Title, date and time, battery and Wi-Fi, Refresh and Close buttons.
        { type = "header", title = "Home" },

        -- Big current condition and temperature, humidity, wind, pressure.
        -- `weather` (required) is a weather.* entity. `temperature` (optional)
        -- is a sensor that replaces the weather entity's own temperature.
        { type = "weather_now", weather = "weather.home",
          temperature = "sensor.outdoor_temperature" },

        -- Hourly temperature line + precipitation bars. `sun` (optional)
        -- shades the night and prints sunrise/sunset. `hours`: window, default 18.
        { type = "chart", weather = "weather.home", sun = "sun.sun", hours = 18 },

        -- Daily forecast rows (today first). `days`: number of rows, default 4.
        { type = "daily", weather = "weather.home", days = 4 },

        -- A grid of read-only values. `columns` default 2.
        -- Item: label, entity (required), attribute (optional: read this
        -- attribute instead of the state), unit (appended), map (state -> text).
        { type = "values", columns = 2, items = {
            { label = "Living room", entity = "climate.living_room",
              attribute = "current_temperature", unit = "°" },
            { label = "Thermostat", entity = "climate.living_room",
              attribute = "temperature", unit = "°" },
            { label = "Outside", entity = "sensor.outdoor_temperature", unit = "°" },
            -- `map` turns raw states into text; `_` is the fallback.
            { label = "Garage alarm", entity = "alarm_control_panel.garage",
              map = { disarmed = "off", armed_away = "ARMED", _ = "?" } },
        }},

        -- Buttons that call Home Assistant services. `columns` default 2.
        -- Item: id (required, unique), label, icon (a name in
        -- homedash.koplugin/icons/ without ".svg": garage-closed, garage-open,
        -- gate, gate-all), action (required), state (optional).
        { type = "buttons", columns = 3, items = {
            { id = "garage", label = "Garage", icon = "garage-closed",
              -- `state` shows the live state of an entity under the label and
              -- may swap text, icon and style ("inverted" = white on black).
              state = { entity = "binary_sensor.garage_door",
                        map = { on  = { text = "Open", icon = "garage-open", style = "inverted" },
                                off = { text = "Closed", icon = "garage-closed" },
                                _   = { text = "?" } } },
              -- `action` is either one table { service, data, confirm } or, as
              -- here, a table keyed by the current state of `state.entity`
              -- (`_` = fallback). `confirm` shows a confirmation dialog first.
              action = { on  = { service = "script.turn_on",
                                 data = { entity_id = "script.close_garage" },
                                 confirm = "Close the garage?" },
                         off = { service = "script.turn_on",
                                 data = { entity_id = "script.open_garage" },
                                 confirm = "Open the garage?" } } },
            -- Plain action, no live state.
            { id = "all", label = "Open all", icon = "gate-all",
              action = { service = "script.turn_on",
                         data = { entity_id = "script.open_all" },
                         confirm = "Open the garage and the gate?" } },
            { id = "gate", label = "Driveway gate", icon = "gate",
              action = { service = "switch.turn_on",
                         data = { entity_id = "switch.driveway_gate" },
                         confirm = "Open the gate?" } },
        }},

        -- Status line: last update / error, and the refresh interval.
        { type = "footer" },
    },
}
