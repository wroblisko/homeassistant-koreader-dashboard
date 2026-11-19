--[[--
English twin of dev/config.mock.lua: same card, same mock entities, lang = "en".
Used by `scripts/dev.sh shots en` for the README screenshots.

HOMEDASH_HA_URL overrides the URL (dev.sh sets it to the mock port).
The token is the mock's token. Times follow the device clock.
]]

return {
    ha = {
        url = os.getenv("HOMEDASH_HA_URL") or "http://127.0.0.1:18123",
        token = "mock-token",
        timeout = 5,
    },
    refresh = { states_min = 5, forecast_min = 30, full_every = 6, after_action_s = 5 },
    locale = {
        lang = "en",
    },
    sections = {
        { type = "header", title = "Home" },
        { type = "weather_now", weather = "weather.forecast_dom",
          temperature = "sensor.prologue_th_5_1_142_temperature" },
        { type = "chart", weather = "weather.forecast_dom", sun = "sun.sun", hours = 18 },
        { type = "daily", weather = "weather.forecast_dom", days = 4 },
        { type = "values", columns = 2, items = {
            { label = "Living room", entity = "climate.termostat", attribute = "current_temperature", unit = "°" },
            { label = "Thermostat", entity = "climate.termostat", attribute = "temperature", unit = "°" },
            { label = "Bathroom", entity = "sensor.temperature_humidity_sensor_39c2_temperature", unit = "°" },
            { label = "Garage alarm", entity = "alarm_control_panel.garaz",
              map = { disarmed = "off", armed_away = "ARMED", _ = "?" } },
        }},
        { type = "buttons", columns = 3, items = {
            { id = "garage", label = "Garage", icon = "garage-closed",
              state = { entity = "binary_sensor.brama_garazowa",
                        map = { on  = { text = "Open", icon = "garage-open", style = "inverted" },
                                off = { text = "Closed", icon = "garage-closed" },
                                _   = { text = "?" } } },
              action = { on  = { service = "script.turn_on", data = { entity_id = "script.zamknij_garaz" },
                                 confirm = "Close the garage?" },
                         off = { service = "script.turn_on", data = { entity_id = "script.otworz_garaz" },
                                 confirm = "Open the garage?" } } },
            { id = "all", label = "Open all", icon = "gate-all",
              action = { service = "script.turn_on", data = { entity_id = "script.otworz_wszystko" },
                         confirm = "Open the garage and the gate?" } },
            { id = "fence", label = "Driveway gate", icon = "gate",
              action = { service = "switch.turn_on", data = { entity_id = "switch.brama_ogrodzeniowa_switch" },
                         confirm = "Open the gate?" } },
        }},
        { type = "footer" },
    },
}
