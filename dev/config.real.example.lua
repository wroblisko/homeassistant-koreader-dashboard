--[[--
Dev config for YOUR Home Assistant (scripts/dev.sh run|shots real).

Copy this file to dev/config.real.lua (git-ignored) and edit the entity ids.

  HOMEDASH_HA_URL      required, e.g. http://192.168.1.10:8123
  HOMEDASH_TOKEN_FILE  file with a long-lived access token (default ~/.homedash-token)

Use a dedicated non-admin, local-network-only Home Assistant user for the token.
See docs/development.md.
]]

local function read_token()
    local path = os.getenv("HOMEDASH_TOKEN_FILE")
    if not path or path == "" then
        path = (os.getenv("HOME") or "") .. "/.homedash-token"
    end
    local f = io.open(path, "rb")
    if not f then
        error("Token file not found:\n" .. path, 0)
    end
    local raw = f:read("*a") or ""
    f:close()
    local token = raw:gsub("%s+", "")
    if token == "" then
        error("Token file is empty:\n" .. path, 0)
    end
    return token
end

local function ha_url()
    local url = os.getenv("HOMEDASH_HA_URL")
    if not url or url == "" then
        error("Set HOMEDASH_HA_URL, e.g. http://192.168.1.10:8123", 0)
    end
    return url
end

return {
    ha = { url = ha_url(), token = read_token(), timeout = 5 },
    refresh = { states_min = 5, forecast_min = 30, full_every = 6, after_action_s = 5 },
    locale = { lang = "en" },
    sections = {
        { type = "header", title = "Home" },
        { type = "weather_now", weather = "weather.home", temperature = "sensor.outdoor_temperature" },
        { type = "chart", weather = "weather.home", sun = "sun.sun", hours = 18 },
        { type = "daily", weather = "weather.home", days = 4 },
        { type = "values", columns = 2, items = {
            { label = "Living room", entity = "climate.living_room", attribute = "current_temperature", unit = "°" },
            { label = "Thermostat", entity = "climate.living_room", attribute = "temperature", unit = "°" },
        }},
        { type = "buttons", columns = 2, items = {
            { id = "garage", label = "Garage", icon = "garage-closed",
              state = { entity = "binary_sensor.garage_door",
                        map = { on  = { text = "Open", icon = "garage-open", style = "inverted" },
                                off = { text = "Closed", icon = "garage-closed" },
                                _   = { text = "?" } } },
              action = { on  = { service = "script.turn_on", data = { entity_id = "script.close_garage" },
                                 confirm = "Close the garage?" },
                         off = { service = "script.turn_on", data = { entity_id = "script.open_garage" },
                                 confirm = "Open the garage?" } } },
            { id = "gate", label = "Driveway gate", icon = "gate",
              action = { service = "switch.turn_on", data = { entity_id = "switch.driveway_gate" },
                         confirm = "Open the gate?" } },
        }},
        { type = "footer" },
    },
}
