--[[--
Dev config used by scripts/dev.sh (Polish UI). Talks to scripts/mock_ha.py.
English twin: dev/config.mock.en.lua.

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
        lang = "pl",
        decimal = ",",
        days = { "niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob." },
    },
    sections = {
        { type = "header", title = "Dom" },
        { type = "weather_now", weather = "weather.forecast_dom",
          temperature = "sensor.prologue_th_5_1_142_temperature" },
        { type = "chart", weather = "weather.forecast_dom", sun = "sun.sun", hours = 18 },
        { type = "daily", weather = "weather.forecast_dom", days = 4 },
        { type = "values", columns = 2, items = {
            { label = "Salon", entity = "climate.termostat", attribute = "current_temperature", unit = "°" },
            { label = "Termostat", entity = "climate.termostat", attribute = "temperature", unit = "°" },
            { label = "Łazienka", entity = "sensor.temperature_humidity_sensor_39c2_temperature", unit = "°" },
            { label = "Alarm garaż", entity = "alarm_control_panel.garaz",
              map = { disarmed = "wył.", armed_away = "UZBROJONY", _ = "?" } },
        }},
        { type = "buttons", columns = 3, items = {
            { id = "garage", label = "Garaż", icon = "garage-closed",
              state = { entity = "binary_sensor.brama_garazowa",
                        map = { on  = { text = "Otwarta", icon = "garage-open", style = "inverted" },
                                off = { text = "Zamknięta", icon = "garage-closed" },
                                _   = { text = "?" } } },
              action = { on  = { service = "script.turn_on", data = { entity_id = "script.zamknij_garaz" },
                                 confirm = "Zamknąć garaż?" },
                         off = { service = "script.turn_on", data = { entity_id = "script.otworz_garaz" },
                                 confirm = "Otworzyć garaż?" } } },
            { id = "all", label = "Otwórz wszystko", icon = "gate-all",
              action = { service = "script.turn_on", data = { entity_id = "script.otworz_wszystko" },
                         confirm = "Otworzyć garaż i bramę?" } },
            { id = "fence", label = "Brama wjazdowa", icon = "gate",
              action = { service = "switch.turn_on", data = { entity_id = "switch.brama_ogrodzeniowa_switch" },
                         confirm = "Otworzyć bramę?" } },
        }},
        { type = "footer" },
    },
}
