--[[--
Pure dashboard logic: time, forecast windows, condition texts, value text, buttons.

No KOReader modules. `require("homedash_model")`. Functions that produce
user-visible words take an optional translator from `homedash_i18n`
(`i18n.new(locale)`); without one they use the built-in English strings.
]]

local i18n = require("homedash_i18n")

local M = {}

--- Data refresh mode of the Refresh button and of resume: everything, now.
M.REFRESH_NOW = "all"
--- Seconds to wait after wake-up before refreshing, so Wi-Fi can reconnect.
M.RESUME_DELAY_S = 3

local DEFAULT_DAYS = i18n.DAYS[i18n.DEFAULT_LANG]
local DEFAULT_TR = i18n.new(nil)

-- Howard Hinnant's civil_from_days inverse. Days since 1970-01-01 (Unix epoch).
local function days_from_civil(year, month, day)
    local y = year
    if month <= 2 then
        y = y - 1
    end
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local moy = month + (month > 2 and -3 or 9)
    local doy = math.floor((153 * moy + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Parse an ISO-8601 timestamp to a UTC epoch (seconds).
-- Accepts `Z` and numeric offsets (`+00:00`). Fractional seconds are ignored.
-- Returns nil when the string is not a zoned timestamp.
function M.parse_iso(value)
    if type(value) ~= "string" then
        return nil
    end
    local year, month, day, hour, min, sec = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
    if not year then
        return nil
    end
    local offset = 0
    if value:sub(-1) ~= "Z" then
        local sign, oh, om = value:match("([%+%-])(%d%d):?(%d%d)%s*$")
        if not sign then
            return nil
        end
        offset = (tonumber(oh) * 60 + tonumber(om)) * 60
        if sign == "-" then
            offset = -offset
        end
    end
    local days = days_from_civil(tonumber(year), tonumber(month), tonumber(day))
    return days * 86400
        + tonumber(hour) * 3600
        + tonumber(min) * 60
        + tonumber(sec)
        - offset
end

--- Local civil time of `epoch` at a fixed UTC offset (minutes).
-- Uses `os.date("!*t")` on the shifted instant, so the device timezone is not involved.
function M.local_parts(epoch, offset_min)
    offset_min = offset_min or 0
    return os.date("!*t", epoch + offset_min * 60)
end

--- Device UTC offset in minutes, from `os.date`. Nil epoch means now.
function M.system_offset_min(epoch)
    epoch = epoch or os.time()
    local utc = os.date("!*t", epoch)
    local loc = os.date("*t", epoch)
    local function stamp(t)
        return days_from_civil(t.year, t.month, t.day) * 86400
            + t.hour * 3600 + t.min * 60 + t.sec
    end
    return math.floor((stamp(loc) - stamp(utc)) / 60 + (stamp(loc) >= stamp(utc) and 0.5 or -0.5))
end

function M.format_clock(epoch, offset_min)
    if type(epoch) ~= "number" then
        return "—"
    end
    local t = M.local_parts(epoch, offset_min)
    return string.format("%02d:%02d", t.hour, t.min)
end

function M.format_date(epoch, offset_min, days)
    if type(epoch) ~= "number" then
        return "—"
    end
    local t = M.local_parts(epoch, offset_min)
    days = days or DEFAULT_DAYS
    local name = days[t.wday] or ""
    if name ~= "" then
        name = name .. " "
    end
    return string.format("%s%d.%02d · %02d:%02d", name, t.day, t.month, t.hour, t.min)
end

--- `H:MM` (no leading zero on the hour), for sunrise and sunset captions.
function M.format_hm(epoch, offset_min)
    if type(epoch) ~= "number" then
        return "—"
    end
    local t = M.local_parts(epoch, offset_min)
    return string.format("%d:%02d", t.hour, t.min)
end

function M.updated_label(epoch, offset_min, tr)
    return (tr or DEFAULT_TR).t("updated_short", M.format_clock(epoch, offset_min))
end

--- Footer status. An error wins over the last success.
-- English: `error 401 · 12:05`, `offline · 12:05`, or `updated 12:05`.
function M.footer_line(last_error, last_ok, offset_min, tr)
    tr = tr or DEFAULT_TR
    if type(last_error) == "table" then
        local clock = M.format_clock(last_error.at, offset_min)
        if last_error.code then
            return tr.t("error_code", tostring(last_error.code)) .. " · " .. clock
        end
        if last_error.kind == "network" then
            return tr.t("offline") .. " · " .. clock
        end
        return tr.t("error") .. " · " .. clock
    end
    if type(last_ok) == "number" then
        return tr.t("updated", M.format_clock(last_ok, offset_min))
    end
    return "—"
end

--- One decimal when needed, otherwise an integer. `sep` is the decimal mark.
function M.format_number(value, sep)
    sep = sep or "."
    local n = value
    if type(n) ~= "number" then
        n = tonumber(n)
    end
    if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
        return "—"
    end
    local sign = ""
    if n < 0 then
        sign = "-"
        n = -n
    end
    local tenths = math.floor(n * 10 + 0.5)
    if tenths == 0 then
        return "0"
    end
    local whole = math.floor(tenths / 10)
    local frac = tenths % 10
    if frac == 0 then
        return string.format("%s%d", sign, whole)
    end
    return string.format("%s%d%s%d", sign, whole, sep, frac)
end

-- Every condition Home Assistant may return (code -> English text). See docs/ha-api.md.
M.CONDITIONS = {}
for _, code in ipairs(i18n.CONDITION_CODES) do
    M.CONDITIONS[code] = i18n.lookup("en", "cond." .. code)
end

--- Display text for a condition code in the translator's language.
-- Unknown codes are returned unchanged; missing ones become an em dash.
function M.condition_text(code, tr)
    if type(code) ~= "string" or code == "" or code == "unavailable" or code == "unknown" then
        return "—"
    end
    return (tr or DEFAULT_TR).condition(code)
end

local function missing(value)
    return value == nil or value == "unavailable" or value == "unknown"
end

local function map_text(mapped)
    if type(mapped) == "table" then
        return mapped.text or "—"
    end
    return tostring(mapped)
end

--- Format one config value item from an HA state object.
-- An entity whose `state` is `unavailable` or `unknown` yields "—" for every
-- derived value, including attributes. A `map` key for that exact state is
-- the only exception. A missing value is also "—".
function M.format_value(state, item, sep)
    item = item or {}
    sep = sep or "."
    if type(state) ~= "table" then
        return "—"
    end
    if state.state == "unavailable" or state.state == "unknown" then
        if type(item.map) == "table" and item.map[state.state] ~= nil then
            return map_text(item.map[state.state])
        end
        return "—"
    end
    local raw
    if item.attribute then
        local attrs = state.attributes
        raw = type(attrs) == "table" and attrs[item.attribute] or nil
    else
        raw = state.state
    end
    if missing(raw) then
        return "—"
    end
    if type(item.map) == "table" then
        local mapped = item.map[tostring(raw)]
        if mapped == nil then
            mapped = item.map._
        end
        if mapped == nil then
            return "—"
        end
        return map_text(mapped)
    end
    local text
    local n = raw
    if type(n) ~= "number" then
        n = tonumber(n)
    end
    if type(n) == "number" then
        text = M.format_number(n, sep)
    else
        text = tostring(raw)
    end
    if text == "—" then
        return text
    end
    if item.unit then
        text = text .. item.unit
    end
    return text
end

--- Humidity, wind and pressure from a weather state, or "—".
function M.weather_meta(state, sep)
    if type(state) ~= "table" or missing(state.state) then
        return "—"
    end
    local attrs = state.attributes or {}
    local parts = {}
    if type(attrs.humidity) == "number" then
        parts[#parts + 1] = M.format_number(attrs.humidity, sep) .. "%"
    end
    if type(attrs.wind_speed) == "number" then
        local text = M.format_number(attrs.wind_speed, sep)
        if type(attrs.wind_speed_unit) == "string" and attrs.wind_speed_unit ~= "" then
            text = text .. " " .. attrs.wind_speed_unit
        end
        parts[#parts + 1] = text
    end
    if type(attrs.pressure) == "number" then
        local text = M.format_number(attrs.pressure, sep)
        if type(attrs.pressure_unit) == "string" and attrs.pressure_unit ~= "" then
            text = text .. " " .. attrs.pressure_unit
        end
        parts[#parts + 1] = text
    end
    if #parts == 0 then
        return "—"
    end
    return table.concat(parts, " · ")
end

local function as_number(value)
    if type(value) == "number" then
        return value
    end
    return tonumber(value)
end

--- Temperature axis for the chart: grid step, padded min/max and tick values.
-- Step is 1 degree when the data range is under 4, 5 when it is over 15, else 2.
function M.temp_axis(lo, hi)
    if type(lo) ~= "number" or type(hi) ~= "number" then
        return { step = 1, min = 0, max = 1, ticks = { 0, 1 } }
    end
    local range = hi - lo
    local step = 2
    if range < 4 then
        step = 1
    elseif range > 15 then
        step = 5
    end
    local pad = step * 0.25
    local first = math.floor((lo - pad) / step)
    local last = math.ceil((hi + pad) / step)
    local ticks = {}
    for k = first, last do
        ticks[#ticks + 1] = k * step
    end
    return { step = step, min = first * step, max = last * step, ticks = ticks }
end

local DAY_S = 86400

-- Bring an event time into [now, now + 48 h) by whole days when it is stale or far off.
local function roll_event(t, now)
    if t < now then
        t = t + math.ceil((now - t) / DAY_S) * DAY_S
    elseif t - now > 2 * DAY_S then
        t = t - math.floor((t - now) / DAY_S) * DAY_S
    end
    return t
end

--- Night stretches inside `[now, now + hours]` from the `sun.sun` state.
-- Uses `next_rising` and `next_setting`. Events past the first one repeat every
-- 24 h. Returns `intervals` (`{ from, to }` epochs, clipped to the window) and
-- `events` (`{ epoch, kind = "rising" | "setting" }` inside the window).
-- State `below_horizon` starts the window in the night, `above_horizon` in
-- the day; without either, the earlier of the two events decides.
-- No sun data (nil, unavailable, unparsable) gives empty lists.
function M.night_intervals(sun, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local hours = opts.hours or 18
    local window_end = now + hours * 3600
    local none = {}
    if type(sun) ~= "table" or missing(sun.state) or type(sun.attributes) ~= "table" then
        return none, {}
    end
    local rise = M.parse_iso(sun.attributes.next_rising)
    local set = M.parse_iso(sun.attributes.next_setting)
    if not rise or not set then
        return none, {}
    end
    rise = roll_event(rise, now)
    set = roll_event(set, now)
    local night
    if sun.state == "below_horizon" then
        night = true
    elseif sun.state == "above_horizon" then
        night = false
    else
        night = rise < set
    end
    local candidates = {}
    for k = 0, math.ceil(hours / 24) + 1 do
        local r, s = rise + k * DAY_S, set + k * DAY_S
        if r >= now and r <= window_end then
            candidates[#candidates + 1] = { epoch = r, kind = "rising" }
        end
        if s >= now and s <= window_end then
            candidates[#candidates + 1] = { epoch = s, kind = "setting" }
        end
    end
    table.sort(candidates, function(a, b)
        return a.epoch < b.epoch
    end)
    local intervals, events = {}, {}
    local seg = now
    for _, ev in ipairs(candidates) do
        if ev.kind == "rising" and night then
            intervals[#intervals + 1] = { from = seg, to = ev.epoch }
            night = false
            events[#events + 1] = ev
        elseif ev.kind == "setting" and not night then
            seg = ev.epoch
            night = true
            events[#events + 1] = ev
        end
    end
    if night and seg < window_end then
        intervals[#intervals + 1] = { from = seg, to = window_end }
    end
    return intervals, events
end

--- Hourly points inside `[now, now + hours]`.
-- Temperature min/max are padded. Precipitation scale is at least 2 mm.
function M.chart_series(items, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local hours = opts.hours or 18
    if hours <= 0 then
        hours = 18
    end
    local offset = opts.utc_offset_min or 0
    local window = hours * 3600
    local points = {}
    local temp_lo, temp_hi
    local precip_max = 0
    if type(items) == "table" then
        for _, item in ipairs(items) do
            if type(item) == "table" then
                local epoch = M.parse_iso(item.datetime)
                if epoch and epoch >= now and epoch <= now + window then
                    local temp = as_number(item.temperature)
                    local precip = as_number(item.precipitation) or 0
                    local local_t = M.local_parts(epoch, offset)
                    points[#points + 1] = {
                        epoch = epoch,
                        hour = local_t.hour,
                        temp = temp,
                        precip = precip,
                        condition = item.condition,
                        show_hour = local_t.hour % 3 == 0,
                    }
                    if temp then
                        if not temp_lo or temp < temp_lo then
                            temp_lo = temp
                        end
                        if not temp_hi or temp > temp_hi then
                            temp_hi = temp
                        end
                    end
                    if precip > precip_max then
                        precip_max = precip
                    end
                end
            end
        end
    end
    table.sort(points, function(a, b)
        return a.epoch < b.epoch
    end)
    local axis = M.temp_axis(temp_lo, temp_hi)
    local temp_min, temp_max = axis.min, axis.max
    local night, sun_events = M.night_intervals(opts.sun, { now = now, hours = hours })
    local current
    for i = 1, #points do
        if points[i].temp then
            current = points[i].temp
            break
        end
    end
    return {
        now = now,
        hours = hours,
        points = points,
        temp_min = temp_min,
        temp_max = temp_max,
        temp_lo = temp_lo,
        temp_hi = temp_hi,
        current = current,
        precip_scale = math.max(2, math.ceil(precip_max - 1e-9)),
        temp_step = axis.step,
        temp_ticks = axis.ticks,
        night = night,
        sun_events = sun_events,
    }
end

--- Daily rows, today first. The first row whose local date is `now` is labelled "Today"
-- (`today` string). `opts.tr` is the translator, `opts.days` overrides its weekday names.
function M.daily_rows(items, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local offset = opts.utc_offset_min or 0
    local tr = opts.tr or DEFAULT_TR
    local days = opts.days or tr.days or DEFAULT_DAYS
    local today = M.local_parts(now, offset)
    local rows = {}
    if type(items) ~= "table" then
        return rows
    end
    for _, item in ipairs(items) do
        if type(item) == "table" then
            local epoch = M.parse_iso(item.datetime)
            local label = "—"
            if epoch then
                local local_t = M.local_parts(epoch, offset)
                if local_t.year == today.year and local_t.yday == today.yday then
                    label = tr.t("today")
                else
                    label = days[local_t.wday] or "—"
                end
            end
            local high = as_number(item.temperature)
            rows[#rows + 1] = {
                label = label,
                feels = M.apparent_temperature({
                    temp_c = high,
                    wind_speed = as_number(item.wind_speed),
                    wind_unit = opts.wind_unit,
                    humidity = as_number(item.humidity),
                }),
                high = high,
                low = as_number(item.templow),
                precip = as_number(item.precipitation),
                condition = M.condition_text(item.condition, tr),
                condition_code = item.condition,
                epoch = epoch,
            }
        end
    end
    return rows
end

--- `{text, style, icon}` for a button state map. Unknown states use `_`.
-- A state entry's `icon` wins. Otherwise `fallback_icon` (the button's own icon).
function M.button_view(state_value, map, fallback_icon)
    if type(map) ~= "table" then
        if type(fallback_icon) == "string" and fallback_icon ~= "" then
            return { text = "?", icon = fallback_icon }
        end
        return nil
    end
    local key = state_value
    if missing(key) or map[key] == nil then
        key = "_"
    end
    local entry = map[key] or map._ or { text = "?" }
    if type(entry) == "string" then
        entry = { text = entry }
    end
    local icon = entry.icon
    if type(icon) ~= "string" or icon == "" then
        icon = fallback_icon
    end
    if type(icon) ~= "string" or icon == "" then
        icon = nil
    end
    return {
        text = entry.text or "?",
        style = entry.style,
        icon = icon,
    }
end

--- Wind speed in km/h. `km/h` (or a missing unit) is unchanged.
-- `m/s` and `mph` are converted. Anything else is nil.
function M.wind_kmh(speed, unit)
    if type(speed) ~= "number" then
        return nil
    end
    if unit == nil or unit == "" or unit == "km/h" or unit == "kmh" then
        return speed
    end
    if unit == "m/s" then
        return speed * 3.6
    end
    if unit == "mph" then
        return speed * 1.609344
    end
    return nil
end

--- Environment Canada wind chill, °C. `wind_kmh` is the 10 m wind.
function M.wind_chill_c(temp_c, wind_kmh)
    local v = wind_kmh ^ 0.16
    return 13.12 + 0.6215 * temp_c - 11.37 * v + 0.3965 * temp_c * v
end

--- NWS Rothfusz heat index, result in °C. `rh` is relative humidity in percent.
function M.heat_index_c(temp_c, rh)
    local tf = temp_c * 9 / 5 + 32
    local hi = -42.379
        + 2.04901523 * tf
        + 10.14333127 * rh
        - 0.22475541 * tf * rh
        - 0.00683783 * tf * tf
        - 0.05481717 * rh * rh
        + 0.00122874 * tf * tf * rh
        + 0.00085282 * tf * rh * rh
        - 0.00000199 * tf * tf * rh * rh
    if rh < 13 and tf >= 80 and tf <= 112 then
        hi = hi - ((13 - rh) / 4) * math.sqrt((17 - math.abs(tf - 95)) / 17)
    elseif rh > 85 and tf >= 80 and tf <= 87 then
        hi = hi + ((rh - 85) / 10) * ((87 - tf) / 5)
    end
    return (hi - 32) * 5 / 9
end

--- Feels-like temperature in °C.
-- `apparent`, when it is a number, is used as-is (the weather entity's
-- `apparent_temperature`). Otherwise: wind chill when T ≤ 10 °C and the wind
-- is faster than 4.8 km/h, heat index when T ≥ 27 °C and humidity is known,
-- and T itself in every other case. Nil when T is missing and there is no
-- explicit apparent temperature.
function M.apparent_temperature(opts)
    opts = opts or {}
    if type(opts.apparent) == "number" then
        return opts.apparent
    end
    local t = opts.temp_c
    if type(t) ~= "number" then
        return nil
    end
    local wind = M.wind_kmh(opts.wind_speed, opts.wind_unit)
    if t <= 10 and wind and wind > 4.8 then
        return M.wind_chill_c(t, wind)
    end
    if t >= 27 and type(opts.humidity) == "number" then
        return M.heat_index_c(t, opts.humidity)
    end
    return t
end

--- 8-point compass abbreviation in the translator's language (`N`, `NE`, ...).
-- Meteorological: 0 degrees is wind from the north. Nil for a non-number.
function M.compass_abbr(bearing, tr)
    return (tr or DEFAULT_TR).compass(bearing)
end

--- Whole km/h, or nil when the speed or the unit cannot be used.
function M.wind_kmh_rounded(speed, unit)
    local kmh = M.wind_kmh(speed, unit)
    if not kmh then
        return nil
    end
    if kmh >= 0 then
        return math.floor(kmh + 0.5)
    end
    return -math.floor(-kmh + 0.5)
end

--- The action table to run for this state.
-- A table with `service` is used as-is. Otherwise the state key, then `_`.
function M.resolve_action(state_value, action)
    if type(action) ~= "table" then
        return nil
    end
    if type(action.service) == "string" and action.service ~= "" then
        return action
    end
    local chosen = nil
    if state_value ~= nil then
        chosen = action[state_value]
    end
    if chosen == nil then
        chosen = action._
    end
    if type(chosen) == "table" and type(chosen.service) == "string" and chosen.service ~= "" then
        return chosen
    end
    return nil
end

local SECTION_TYPES = {
    header = true,
    weather_now = true,
    chart = true,
    daily = true,
    values = true,
    buttons = true,
    footer = true,
}

local function action_problem(action)
    if type(action) ~= "table" then
        return "action needs service"
    end
    if type(action.service) == "string" and action.service ~= "" then
        return nil
    end
    local branches = 0
    for key, branch in pairs(action) do
        if key ~= "data" and key ~= "confirm" and key ~= "service" then
            branches = branches + 1
            if type(branch) ~= "table" or type(branch.service) ~= "string" or branch.service == "" then
                return "action needs service"
            end
        end
    end
    if branches == 0 then
        return "action needs service"
    end
    return nil
end

--- Nil when the config can be shown, otherwise one readable error string.
function M.validate(cfg)
    if type(cfg) ~= "table" then
        return "config must be a table"
    end
    if type(cfg.ha) ~= "table" or type(cfg.ha.url) ~= "string" or cfg.ha.url == "" then
        return "ha.url is required"
    end
    if type(cfg.ha.token) ~= "string" or cfg.ha.token == "" then
        return "ha.token is required"
    end
    if cfg.ha.timeout ~= nil and type(cfg.ha.timeout) ~= "number" then
        return "ha.timeout must be a number"
    end
    if type(cfg.sections) ~= "table" then
        return "sections must be a list"
    end
    for i, section in ipairs(cfg.sections) do
        local where = "sections[" .. i .. "]"
        if type(section) ~= "table" or type(section.type) ~= "string" then
            return where .. ": type is required"
        end
        if not SECTION_TYPES[section.type] then
            return where .. ": unknown type \"" .. section.type .. "\""
        end
        if section.type == "weather_now" or section.type == "chart" or section.type == "daily" then
            if type(section.weather) ~= "string" or section.weather == "" then
                return where .. ": weather is required"
            end
        end
        if section.type == "values" or section.type == "buttons" then
            if type(section.items) ~= "table" then
                return where .. ": items must be a list"
            end
            for j, item in ipairs(section.items) do
                local item_where = where .. ".items[" .. j .. "]"
                if type(item) ~= "table" then
                    return item_where .. ": item must be a table"
                end
                if section.type == "values" then
                    if type(item.entity) ~= "string" or item.entity == "" then
                        return item_where .. ": entity is required"
                    end
                end
                if section.type == "buttons" then
                    if type(item.id) ~= "string" or item.id == "" then
                        return item_where .. ": id is required"
                    end
                    local problem = action_problem(item.action)
                    if problem then
                        return item_where .. ": " .. problem
                    end
                end
            end
        end
    end
    return nil
end

--- Fill timeouts, refresh, locale and the UTC offset when the config omits them.
function M.defaults(cfg)
    cfg.ha.timeout = cfg.ha.timeout or 5
    cfg.refresh = cfg.refresh or {}
    local refresh = cfg.refresh
    if refresh.states_min == nil then refresh.states_min = 5 end
    if refresh.forecast_min == nil then refresh.forecast_min = 30 end
    if refresh.full_every == nil then refresh.full_every = 6 end
    if refresh.after_action_s == nil then refresh.after_action_s = 5 end
    cfg.locale = cfg.locale or {}
    -- Language, decimal mark and weekday names follow `locale.lang` unless set explicitly.
    local tr = i18n.new(cfg.locale)
    cfg.locale.lang = tr.lang
    cfg.locale.decimal = tr.decimal
    cfg.locale.days = tr.days
    if cfg.locale.utc_offset_min == nil then
        cfg.locale.utc_offset_min = M.system_offset_min()
    end
    return cfg
end

return M
