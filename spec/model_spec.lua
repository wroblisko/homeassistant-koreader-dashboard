local model = require("homedash_model")
local Data = require("homedash_data")
local i18n = require("homedash_i18n")

local function read_file(path)
    local handle = assert(io.open(path, "rb"), path)
    local text = handle:read("*a")
    handle:close()
    return text
end

local function json_decode(text)
    local names = { "rapidjson", "json", "dkjson" }
    for i = 1, #names do
        local ok, lib = pcall(require, names[i])
        if ok and type(lib) == "table" and type(lib.decode) == "function" then
            local decoded_ok, value, _, err = pcall(lib.decode, text)
            if not decoded_ok then
                error(tostring(value))
            end
            if type(value) ~= "table" then
                error(err or "JSON decode did not return a table")
            end
            return value
        end
    end
    error("no JSON library; scripts/test.sh should add the emulator common/ directory to --lpath")
end

local function load_json(path)
    return json_decode(read_file(path))
end

local function forecast_rows(path)
    local body = load_json(path)
    return body.service_response["weather.forecast_dom"].forecast
end

local function near(expected, actual)
    assert.are.equal("number", type(actual))
    local delta = math.abs(expected - actual)
    assert.is_true(delta < 1e-4, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local function load_config(path)
    local chunk, err = loadfile(path)
    assert.is_true(chunk ~= nil, tostring(err))
    local ok, cfg = pcall(chunk)
    assert.is_true(ok, tostring(cfg))
    return cfg
end

local NOW = "2026-11-19T15:34:00Z"
local OFFSET = 60

describe("homedash_model", function()
    local hourly
    local daily
    local cfg
    local PL

    setup(function()
        hourly = forecast_rows("spec/fixtures/ha/forecast_hourly.json")
        daily = forecast_rows("spec/fixtures/ha/forecast_daily.json")
        cfg = load_config("dev/config.mock.lua")
        PL = i18n.new(cfg.locale)
    end)

    describe("parse_iso", function()
        it("reads a Z timestamp as UTC", function()
            local epoch = model.parse_iso(NOW)
            local t = os.date("!*t", epoch)
            assert.are.equal(2026, t.year)
            assert.are.equal(11, t.month)
            assert.are.equal(19, t.day)
            assert.are.equal(15, t.hour)
            assert.are.equal(34, t.min)
            assert.are.equal(0, t.sec)
        end)

        it("treats Z and +00:00 as the same instant", function()
            assert.are.equal(
                model.parse_iso("2026-11-19T16:00:00Z"),
                model.parse_iso("2026-11-19T16:00:00+00:00"))
        end)

        it("ignores fractional seconds", function()
            local epoch = model.parse_iso("2026-11-19T15:33:15.055808+00:00")
            local t = os.date("!*t", epoch)
            assert.are.equal(15, t.hour)
            assert.are.equal(33, t.min)
            assert.are.equal(15, t.sec)
        end)
    end)

    describe("chart_series", function()
        it("keeps the 18 hours from the pinned capture", function()
            local now = model.parse_iso(NOW)
            local series = model.chart_series(hourly, {
                now = now,
                hours = 18,
                utc_offset_min = OFFSET,
            })
            assert.are.equal(18, #series.points)
            assert.are.equal(17, series.points[1].hour)
            assert.are.equal(false, series.points[1].show_hour)
            near(10.9, series.points[1].temp)
            assert.are.equal(18, series.points[2].hour)
            assert.are.equal(true, series.points[2].show_hour)
            assert.are.equal("cloudy", series.points[1].condition)
            near(1.2, series.points[4].precip)
            assert.are.equal(9, series.points[17].hour)
            assert.are.equal(true, series.points[17].show_hour)
            assert.are.equal(10, series.points[18].hour)
            near(11.6, series.points[18].temp)
            near(8.0, series.temp_lo)
            near(11.6, series.temp_hi)
            assert.is_true(series.temp_min < series.temp_lo)
            assert.is_true(series.temp_max > series.temp_hi)
            assert.are.equal(2, series.precip_scale)
        end)
    end)

    describe("daily_rows", function()
        it("labels today first and then the next weekdays", function()
            local rows = model.daily_rows(daily, {
                now = model.parse_iso(NOW),
                utc_offset_min = OFFSET,
                days = cfg.locale.days,
                tr = PL,
            })
            assert.are.equal(6, #rows)
            assert.are.equal("Dziś", rows[1].label)
            assert.are.equal("pt.", rows[2].label)
            assert.are.equal("sob.", rows[3].label)
            assert.are.equal("niedz.", rows[4].label)
            assert.are.equal("pon.", rows[5].label)
            assert.are.equal("wt.", rows[6].label)
            assert.are.equal("pochmurno", rows[1].condition)
            assert.are.equal("cloudy", rows[1].condition_code)
            assert.are.equal("deszcz", rows[2].condition)
            assert.are.equal("partlycloudy", rows[3].condition_code)
            assert.are.equal("przejaśnienia", rows[3].condition)
            near(11.0, rows[1].high)
            near(9.1, rows[1].low)
            near(3.0, rows[1].precip)
            near(-0.2, rows[6].low)
        end)
    end)

    describe("night_intervals", function()
        local function sun(state, rise, set)
            return { state = state, attributes = { next_rising = rise, next_setting = set } }
        end
        local fixture = sun("below_horizon", "2026-11-20T06:01:41.198460+00:00", "2026-11-20T14:50:10.729500+00:00")
        local t = model.parse_iso

        it("starts in the night when below the horizon and ends at sunrise", function()
            local now = t("2026-11-19T17:30:00Z")
            local iv, ev = model.night_intervals(fixture, { now = now, hours = 18 })
            assert.are.equal(1, #iv)
            assert.are.equal(now, iv[1].from)
            assert.are.equal(t("2026-11-20T06:01:41Z"), iv[1].to)
            assert.are.equal(1, #ev)
            assert.are.equal("rising", ev[1].kind)
        end)

        it("crosses sunrise and then sunset in a 24 h window", function()
            local now = t("2026-11-19T17:30:00Z")
            local iv, ev = model.night_intervals(fixture, { now = now, hours = 24 })
            assert.are.equal(2, #iv)
            assert.are.equal(t("2026-11-20T14:50:10Z"), iv[2].from)
            assert.are.equal(now + 24 * 3600, iv[2].to)
            assert.are.equal("setting", ev[2].kind)
        end)

        it("starts in the day when above the horizon and repeats events +24 h", function()
            local now = t("2026-11-20T09:00:00Z")
            local s = sun("above_horizon", "2026-11-21T06:03:00+00:00", "2026-11-20T14:50:00+00:00")
            local iv = model.night_intervals(s, { now = now, hours = 18 })
            assert.are.equal(1, #iv)
            assert.are.equal(t("2026-11-20T14:50:00Z"), iv[1].from)
            assert.are.equal(now + 18 * 3600, iv[1].to)
            iv = model.night_intervals(s, { now = now, hours = 36 })
            assert.are.equal(2, #iv)
            assert.are.equal(t("2026-11-21T06:03:00Z"), iv[1].to)
            assert.are.equal(t("2026-11-21T14:50:00Z"), iv[2].from)
        end)

        it("rolls stale or far-off events by whole days", function()
            local now = t("2026-11-19T17:30:00Z")
            local stale = sun("below_horizon", "2026-11-17T06:01:00+00:00", "2026-11-17T14:50:00+00:00")
            local iv = model.night_intervals(stale, { now = now, hours = 18 })
            assert.are.equal(1, #iv)
            assert.are.equal(t("2026-11-20T06:01:00Z"), iv[1].to)
            local far = sun("below_horizon", "2026-11-25T06:01:00+00:00", "2026-11-25T14:50:00+00:00")
            iv = model.night_intervals(far, { now = now, hours = 18 })
            assert.are.equal(t("2026-11-20T06:01:00Z"), iv[1].to)
        end)

        it("gives nothing without usable sun data", function()
            local now = t("2026-11-19T17:30:00Z")
            assert.are.same({}, (model.night_intervals(nil, { now = now })))
            assert.are.same({}, (model.night_intervals({ state = "unavailable", attributes = {} }, { now = now })))
            assert.are.same({}, (model.night_intervals({ state = "below_horizon", attributes = {} }, { now = now })))
        end)

        it("is part of chart_series", function()
            local now = t("2026-11-19T17:30:00Z")
            local series = model.chart_series(hourly, { now = now, hours = 18, sun = fixture })
            assert.are.equal(1, #series.night)
            assert.are.equal(1, #series.sun_events)
        end)
    end)

    describe("temp_axis", function()
        it("picks 1, 2 or 5 degree steps from the range", function()
            assert.are.equal(1, model.temp_axis(8.0, 11.6).step)
            assert.are.equal(2, model.temp_axis(2, 10).step)
            assert.are.equal(5, model.temp_axis(-3, 14).step)
            assert.are.equal(2, model.temp_axis(0, 15).step)
        end)

        it("pads min and max to whole steps and lists ticks", function()
            local a = model.temp_axis(8.0, 11.6)
            assert.are.equal(7, a.min)
            assert.are.equal(12, a.max)
            assert.are.same({ 7, 8, 9, 10, 11, 12 }, a.ticks)
            local b = model.temp_axis(3.1, 9.9)
            assert.are.equal(2, b.min)
            assert.are.equal(12, b.max)
        end)

        it("scales the precipitation axis to whole mm, at least 2", function()
            local now = model.parse_iso(NOW)
            local series = model.chart_series(hourly, { now = now, hours = 18, utc_offset_min = OFFSET })
            assert.are.equal(2, series.precip_scale)
            assert.are.equal(4, model.chart_series({
                { datetime = "2026-11-19T16:00:00Z", temperature = 1, precipitation = 3.2 },
            }, { now = now, hours = 18 }).precip_scale)
        end)
    end)

    describe("daily feels like", function()
        it("uses each day's temperature, wind and humidity", function()
            local rows = model.daily_rows({
                { datetime = "2026-11-19T11:00:00+00:00", temperature = 5, templow = 1, wind_speed = 20, humidity = 80 },
                { datetime = "2026-11-20T11:00:00+00:00", temperature = 5, templow = 1, wind_speed = 2, humidity = 80 },
                { datetime = "2026-11-21T11:00:00+00:00", temperature = 14, templow = 1, wind_speed = 40 },
            }, { now = model.parse_iso(NOW), utc_offset_min = OFFSET, wind_unit = "km/h" })
            near(model.wind_chill_c(5, 20), rows[1].feels)
            assert.is_true(rows[1].feels < 5)
            near(5, rows[2].feels)
            near(14, rows[3].feels)
            local ms = model.daily_rows({
                { datetime = "2026-11-19T11:00:00+00:00", temperature = 5, wind_speed = 20 / 3.6 },
            }, { now = model.parse_iso(NOW), utc_offset_min = OFFSET, wind_unit = "m/s" })
            near(model.wind_chill_c(5, 20), ms[1].feels)
        end)
    end)

    describe("formats and glyphs", function()
        it("formats the header date and H:MM", function()
            local e = model.parse_iso("2026-11-19T17:38:00Z")
            assert.are.equal("czw. 19.11 · 18:38", model.format_date(e, 60, cfg.locale.days))
            assert.are.equal("6:02", model.format_hm(model.parse_iso("2026-11-20T05:02:00Z"), 60))
        end)

        it("picks battery glyphs by level", function()
            local icons = require("homedash_icons")
            assert.are.equal(0xF244, icons.battery_glyph(3))
            assert.are.equal(0xF242, icons.battery_glyph(50))
            assert.are.equal(0xF240, icons.battery_glyph(100))
            assert.are.equal(nil, icons.battery_glyph(nil))
        end)

        it("refresh and resume use a full refresh after a short delay", function()
            assert.are.equal("all", model.REFRESH_NOW)
            assert.is_true(model.RESUME_DELAY_S >= 2 and model.RESUME_DELAY_S <= 5)
        end)
    end)

    describe("condition_text", function()
        it("translates every condition from the HA contract", function()
            local expected = {
                ["clear-night"] = "bezchmurnie (noc)",
                cloudy = "pochmurno",
                exceptional = "wyjątkowo",
                fog = "mgła",
                hail = "grad",
                lightning = "burza",
                ["lightning-rainy"] = "burza z deszczem",
                partlycloudy = "przejaśnienia",
                pouring = "ulewa",
                rainy = "deszcz",
                snowy = "śnieg",
                ["snowy-rainy"] = "śnieg z deszczem",
                sunny = "słonecznie",
                windy = "wietrznie",
                ["windy-variant"] = "porywisty wiatr",
            }
            for code, polish in pairs(expected) do
                local text = model.condition_text(code, PL)
                assert.are.equal(polish, text)
                assert.is_true(text ~= code)
                assert.is_true(#text > 0)
            end
        end)

        it("speaks English without a translator", function()
            assert.are.equal("cloudy", model.condition_text("cloudy"))
            assert.are.equal("partly cloudy", model.condition_text("partlycloudy"))
            assert.are.equal("cloudy", model.CONDITIONS.cloudy)
        end)

        it("keeps an unknown code and dashes out a missing one", function()
            assert.are.equal("not-a-condition", model.condition_text("not-a-condition"))
            assert.are.equal("—", model.condition_text("unavailable"))
            assert.are.equal("—", model.condition_text(nil))
        end)
    end)

    describe("format_value", function()
        it("formats fixture states with a decimal comma", function()
            local outdoor = load_json("spec/fixtures/ha/states/sensor.prologue_th_5_1_142_temperature.json")
            local climate = load_json("spec/fixtures/ha/states/climate.termostat.json")
            local bathroom = load_json("spec/fixtures/ha/states/sensor.temperature_humidity_sensor_39c2_temperature.json")
            local alarm = load_json("spec/fixtures/ha/states/alarm_control_panel.garaz.json")
            local weather = load_json("spec/fixtures/ha/states/weather.forecast_dom.json")
            assert.are.equal("9,2°", model.format_value(outdoor, { unit = "°" }, ","))
            assert.are.equal("20,8°", model.format_value(climate, {
                attribute = "current_temperature",
                unit = "°",
            }, ","))
            assert.are.equal("20,5°", model.format_value(climate, {
                attribute = "temperature",
                unit = "°",
            }, ","))
            assert.are.equal("—", model.format_value(bathroom, { unit = "°" }, ","))
            assert.are.equal("wył.", model.format_value(alarm, {
                map = { disarmed = "wył.", armed_away = "UZBROJONY", _ = "?" },
            }, ","))
            assert.are.equal("74% · 6,8 km/h · 993,1 hPa", model.weather_meta(weather, ","))
        end)

        it("renders a signed fraction", function()
            assert.are.equal("-0,2", model.format_number(-0.2, ","))
            assert.are.equal("0", model.format_number(0, ","))
        end)

        it("dashes attributes when the entity itself is unavailable", function()
            local climate = load_json("spec/fixtures/ha/states/climate.termostat.json")
            climate.state = "unavailable"
            assert.are.equal("—", model.format_value(climate, {
                attribute = "current_temperature",
                unit = "°",
            }, ","))
            assert.are.equal("—", model.format_value(climate, {
                attribute = "temperature",
                unit = "°",
            }, ","))
            -- A fallback `_` is not an explicit unavailable entry.
            assert.are.equal("—", model.format_value(climate, {
                attribute = "current_temperature",
                map = { _ = "?" },
            }, ","))
            assert.are.equal("brak", model.format_value(climate, {
                map = { unavailable = "brak", _ = "?" },
            }, ","))
            climate.state = "unknown"
            assert.are.equal("—", model.format_value(climate, {
                attribute = "temperature",
                unit = "°",
            }, ","))
            assert.are.equal("nieznany", model.format_value(climate, {
                map = { unknown = "nieznany" },
            }, ","))
        end)
    end)

    describe("buttons", function()
        it("resolves off, on, unavailable and a plain action", function()
            local garage = cfg.sections[6].items[1]
            local fence = cfg.sections[6].items[3]
            local gate = load_json("spec/fixtures/ha/states/binary_sensor.brama_garazowa.json")
            local closed = model.button_view(gate.state, garage.state.map, garage.icon)
            assert.are.equal("off", gate.state)
            assert.are.equal("Zamknięta", closed.text)
            assert.are.equal(nil, closed.style)
            assert.are.equal("garage-closed", closed.icon)
            local open_action = model.resolve_action(gate.state, garage.action)
            assert.are.equal("script.turn_on", open_action.service)
            assert.are.equal("script.otworz_garaz", open_action.data.entity_id)
            assert.are.equal("Otworzyć garaż?", open_action.confirm)

            local opened = model.button_view("on", garage.state.map, garage.icon)
            assert.are.equal("Otwarta", opened.text)
            assert.are.equal("inverted", opened.style)
            assert.are.equal("garage-open", opened.icon)
            local close_action = model.resolve_action("on", garage.action)
            assert.are.equal("script.zamknij_garaz", close_action.data.entity_id)
            assert.are.equal("Zamknąć garaż?", close_action.confirm)

            local unknown = model.button_view("unavailable", garage.state.map, garage.icon)
            assert.are.equal("?", unknown.text)
            assert.are.equal("garage-closed", unknown.icon)
            assert.are.equal(nil, model.resolve_action("unavailable", garage.action))
            assert.are.equal("?", model.button_view(nil, garage.state.map, garage.icon).text)
            assert.are.equal("gate-all", model.button_view(nil, nil, "gate-all").icon)

            local fence_action = model.resolve_action(nil, fence.action)
            assert.are.equal("switch.turn_on", fence_action.service)
            assert.are.equal("switch.brama_ogrodzeniowa_switch", fence_action.data.entity_id)
        end)
    end)

    describe("feels like and wind", function()
        it("converts wind units to km/h", function()
            near(6.8, model.wind_kmh(6.8, "km/h"))
            near(6.8, model.wind_kmh(6.8, nil))
            near(36, model.wind_kmh(10, "m/s"))
            near(16.09344, model.wind_kmh(10, "mph"))
            assert.are.equal(nil, model.wind_kmh(10, "kn"))
            assert.are.equal(nil, model.wind_kmh(nil, "km/h"))
            assert.are.equal(7, model.wind_kmh_rounded(6.8, "km/h"))
        end)

        it("uses the Environment Canada wind chill only when it applies", function()
            near(-3.314650193381196, model.wind_chill_c(0, 10))
            near(8.343765892165754, model.apparent_temperature({
                temp_c = 9.2, wind_speed = 6.8, wind_unit = "km/h", humidity = 74,
            }))
            -- Wind at the 4.8 km/h threshold does not count, nor does mild air.
            near(5, model.apparent_temperature({
                temp_c = 5, wind_speed = 4.8, wind_unit = "km/h",
            }))
            near(15, model.apparent_temperature({
                temp_c = 15, wind_speed = 30, wind_unit = "km/h", humidity = 40,
            }))
        end)

        it("uses the heat index from 27 °C and an explicit apparent temperature", function()
            near(35.03801755555546, model.apparent_temperature({
                temp_c = 30, wind_speed = 5, wind_unit = "km/h", humidity = 70,
            }))
            near(26.863173119555604, model.heat_index_c(27, 40))
            near(12.5, model.apparent_temperature({
                apparent = 12.5, temp_c = 9.2, wind_speed = 20, wind_unit = "km/h",
            }))
            assert.are.equal(nil, model.apparent_temperature({ wind_speed = 10 }))
        end)

        it("maps bearings onto the Polish 8-point compass", function()
            assert.are.equal("pn.", model.compass_abbr(0, PL))
            assert.are.equal("pn.", model.compass_abbr(360, PL))
            assert.are.equal("pn.", model.compass_abbr(359, PL))
            assert.are.equal("pn.", model.compass_abbr(337.5, PL))
            assert.are.equal("pn.-wsch.", model.compass_abbr(22.5, PL))
            assert.are.equal("wsch.", model.compass_abbr(93.8, PL))
            assert.are.equal("pd.-wsch.", model.compass_abbr(135, PL))
            assert.are.equal("pd.", model.compass_abbr(180, PL))
            assert.are.equal("pd.-zach.", model.compass_abbr(225, PL))
            assert.are.equal("zach.", model.compass_abbr(270, PL))
            assert.are.equal("pn.-zach.", model.compass_abbr(315, PL))
            assert.are.equal(nil, model.compass_abbr(nil, PL))
            assert.are.equal("N", model.compass_abbr(0))
            assert.are.equal("SW", model.compass_abbr(225))
        end)
    end)

    describe("condition icons", function()
        local icons = require("homedash_icons")

        it("gives every Home Assistant condition a glyph", function()
            local seen = {}
            for _, code in ipairs(icons.known_conditions()) do
                seen[code] = true
                local glyph = icons.condition(code, { hour = 12 })
                assert.is_true(type(glyph) == "string" and #glyph > 0, code)
            end
            for code in pairs(model.CONDITIONS) do
                assert.is_true(seen[code] == true, code)
            end
            assert.are.equal(nil, icons.condition("not-a-condition"))
        end)

        it("uses the night partly-cloudy glyph only for hourly night hours", function()
            local day = icons.condition("partlycloudy", { hour = 12 })
            local night = icons.condition("partlycloudy", { hour = 21 })
            local early = icons.condition("partlycloudy", { hour = 5 })
            local daily = icons.condition("partlycloudy", { hour = 21, daily = true })
            assert.is_true(day ~= night)
            assert.are.equal(night, early)
            assert.are.equal(day, daily)
            assert.is_true(icons.is_night_hour(18))
            assert.is_true(not icons.is_night_hour(6))
        end)
    end)

    describe("footer_line", function()
        it("prefers the error clock, shifted into the configured offset", function()
            local at = model.parse_iso("2026-11-19T11:05:00Z")
            assert.are.equal("błąd 401 · 12:05", model.footer_line(
                { kind = "auth", code = 401, at = at }, nil, OFFSET, PL))
            assert.are.equal("offline · 11:05", model.footer_line(
                { kind = "network", at = at }, nil, 0, PL))
            assert.are.equal("aktualizacja 11:05", model.footer_line(nil, at, 0, PL))
            assert.are.equal("error 401 · 12:05", model.footer_line(
                { kind = "auth", code = 401, at = at }, nil, OFFSET))
            assert.are.equal("offline · 11:05", model.footer_line(
                { kind = "network", at = at }, nil, 0))
            assert.are.equal("updated 11:05", model.footer_line(nil, at, 0))
        end)
    end)

    describe("defaults", function()
        it("follows locale.lang for decimal mark and weekday names", function()
            local en = model.defaults({ ha = {}, locale = {} })
            assert.are.equal("en", en.locale.lang)
            assert.are.equal(".", en.locale.decimal)
            assert.are.equal("Sun", en.locale.days[1])
            local pl = model.defaults({ ha = {}, locale = { lang = "pl" } })
            assert.are.equal(",", pl.locale.decimal)
            assert.are.equal("niedz.", pl.locale.days[1])
            local custom = model.defaults({ ha = {}, locale = { lang = "pl", decimal = "." } })
            assert.are.equal(".", custom.locale.decimal)
        end)
    end)

    describe("validate", function()
        it("accepts the example and the dev configs", function()
            -- The example reads its token from a file on the device; fake that file.
            local real_open = io.open
            io.open = function(path, mode)
                if path == "/mnt/us/koreader/settings/homedash.token" then
                    return {
                        read = function() return "example-token\n" end,
                        close = function() end,
                    }
                end
                return real_open(path, mode)
            end
            local ok, example = pcall(load_config, "homedash.koplugin/config.example.lua")
            io.open = real_open
            assert.is_true(ok, tostring(example))
            assert.are.equal(nil, model.validate(example))
            assert.are.equal(nil, model.validate(cfg))
            assert.are.equal(nil, model.validate(load_config("dev/config.mock.en.lua")))
        end)

        it("names the button whose action has no service", function()
            local broken = load_config("dev/config.mock.lua")
            broken.sections[6].items[1].action = { on = { confirm = "x" } }
            assert.are.equal(
                "sections[6].items[1]: action needs service",
                model.validate(broken))
        end)
    end)
end)

describe("homedash_data", function()
    local cfg

    setup(function()
        cfg = load_config("dev/config.mock.lua")
    end)

    it("collects displayed entities once, and not action targets", function()
        local ids = Data.entity_ids(cfg)
        assert.are.same({
            "weather.forecast_dom",
            "sensor.prologue_th_5_1_142_temperature",
            "sun.sun",
            "climate.termostat",
            "sensor.temperature_humidity_sensor_39c2_temperature",
            "alarm_control_panel.garaz",
            "binary_sensor.brama_garazowa",
        }, ids)
        local queries = Data.forecast_queries(cfg)
        assert.are.equal(2, #queries)
        assert.are.equal("weather.forecast_dom", queries[1].entity_id)
        assert.are.equal("hourly", queries[1].kind)
        assert.are.equal("daily", queries[2].kind)
    end)

    it("records an auth error without dropping the refresh", function()
        local calls = 0
        local client = {
            get_state = function()
                calls = calls + 1
                return nil, { kind = "auth", code = 401, message = "401: Unauthorized" }
            end,
            get_forecast = function()
                calls = calls + 1
                return nil, { kind = "auth", code = 401, message = "401: Unauthorized" }
            end,
        }
        local data = Data:new{ config = cfg, client = client }
        data:refresh(1000, "all")
        assert.are.equal(9, calls)
        assert.are.equal(401, data.last_error.code)
        assert.are.equal("auth", data.last_error.kind)
        assert.are.equal(nil, data.last_ok)
    end)

    it("keeps the previous state when a later fetch fails", function()
        local mode = "ok"
        local client = {
            get_state = function(_, id)
                if mode == "ok" then
                    return { entity_id = id, state = "9.2" }
                end
                return nil, { kind = "network", message = "connection refused" }
            end,
            get_forecast = function()
                if mode == "ok" then
                    return {
                        { datetime = "2026-11-19T16:00:00Z", temperature = 1, precipitation = 0 },
                    }
                end
                return nil, { kind = "network", message = "connection refused" }
            end,
        }
        local data = Data:new{ config = cfg, client = client }
        data:refresh(1000, "all")
        assert.are.equal("9.2", data:state("weather.forecast_dom").state)
        assert.are.equal(1, #data:forecast("weather.forecast_dom", "hourly"))
        mode = "bad"
        data:refresh(2000, "all")
        assert.are.equal("9.2", data:state("weather.forecast_dom").state)
        assert.are.equal("network", data.last_error.kind)
        assert.are.equal(1000, data.last_ok)
    end)

    it("forced refresh fetches all states and forecasts even when none is due", function()
        local states, forecasts = 0, 0
        local client = {
            get_state = function(_, id) states = states + 1; return { entity_id = id, state = "1" } end,
            get_forecast = function() forecasts = forecasts + 1; return {} end,
        }
        local data = Data:new{ config = cfg, client = client }
        data:refresh(1000, "all")
        local s0, f0 = states, forecasts
        data:refresh(1001, "due")
        assert.are.equal(s0, states)
        assert.are.equal(f0, forecasts)
        data:refresh(1002, model.REFRESH_NOW)
        assert.are.equal(s0 * 2, states)
        assert.are.equal(f0 * 2, forecasts)
    end)
end)
