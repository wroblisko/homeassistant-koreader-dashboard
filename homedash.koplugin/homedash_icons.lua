--[[--
Weather Icons from KOReader's bundled nerdfonts/symbols.ttf.

The glyphs live at U+E300–U+E3EB (Erik Flowers' Weather Icons, shifted into
this block). Codepoints below were picked by rendering that range to
out/glyphs.png and reading the shapes. Each comment names the picture.

No KOReader modules. `require("homedash_icons")`.
]]

local M = {}

-- Daytime is 06:00–17:59. Hourly partly-cloudy uses the night glyph outside that.
function M.is_night_hour(hour)
    if type(hour) ~= "number" then
        return false
    end
    return hour < 6 or hour >= 18
end

function M.utf8(cp)
    cp = math.floor(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40))
    end
    return string.char(
        0xE0 + math.floor(cp / 0x1000),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end

-- Single codepoint, or { day, night } for partly cloudy.
-- Names describe the glyph that was on the sheet.
local CONDITIONS = {
    ["clear-night"] = 0xE3A3,       -- crescent moon
    cloudy = 0xE312,                -- cloud
    exceptional = 0xE351,           -- tornado
    fog = 0xE313,                   -- cloud over horizontal fog lines
    hail = 0xE31A,                  -- cloud with round pellets
    lightning = 0xE315,             -- two lightning bolts
    ["lightning-rainy"] = 0xE31D,   -- cloud, bolt and rain streaks
    partlycloudy = { day = 0xE302, night = 0xE379 }, -- sun behind a cloud / cloud and crescent
    pouring = 0xE318,               -- cloud with heavy diagonal rain
    rainy = 0xE319,                 -- cloud with raindrops
    snowy = 0xE36F,                 -- snowflake
    ["snowy-rainy"] = 0xE317,       -- cloud, rain streaks and drops
    sunny = 0xE30D,                 -- sun with rays
    windy = 0xE31E,                 -- three wind lines
    ["windy-variant"] = 0xE311,     -- cloud with wind lines
}

M.GLYPH = {
    sun = 0xE30D,          -- sun with rays (day / today's max)
    moon = 0xE3A3,         -- crescent moon (night / today's min)
    thermometer = 0xE34E,  -- outline thermometer (feels-like)
    wind = 0xE31E,         -- three wind lines
    raindrop = 0xE371,     -- single drop (precipitation)
    humidity = 0xE373,     -- drop with a percent sign
    pressure = 0xE372,     -- round barometer gauge
    -- Font Awesome 4 (same symbols.ttf)
    refresh = 0xF021,      -- circular arrows
    close = 0xF00D,        -- times
    hand = 0xF256,         -- hand-paper-o (feels like)
    bolt = 0xF0E7,         -- charging
    wifi = 0xF1EB,         -- wifi
    battery = { 0xF244, 0xF243, 0xF242, 0xF241, 0xF240 }, -- empty .. full
}

--- Battery glyph codepoint for a capacity in percent.
function M.battery_glyph(capacity)
    if type(capacity) ~= "number" then
        return nil
    end
    local idx = math.floor(capacity / 25 + 0.5) + 1
    if idx < 1 then idx = 1 end
    if idx > 5 then idx = 5 end
    return M.GLYPH.battery[idx]
end

function M.char(cp)
    if type(cp) ~= "number" then
        return nil
    end
    return M.utf8(cp)
end

--- UTF-8 glyph for a Home Assistant condition, or nil when there is no mapping.
-- `opts.daily` forces the day partly-cloudy glyph. Otherwise `opts.hour`
-- (0–23, local) picks day or night. A missing hour uses the day glyph.
function M.condition(code, opts)
    local entry = CONDITIONS[code]
    if not entry then
        return nil
    end
    opts = opts or {}
    local cp = entry
    if type(entry) == "table" then
        if opts.daily or not M.is_night_hour(opts.hour) then
            cp = entry.day
        else
            cp = entry.night
        end
    end
    return M.char(cp)
end

function M.known_conditions()
    local list = {}
    for code in pairs(CONDITIONS) do
        list[#list + 1] = code
    end
    table.sort(list)
    return list
end

return M
