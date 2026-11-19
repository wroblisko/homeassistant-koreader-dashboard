--[[--
String tables for the dashboard. Pure Lua, no KOReader modules.

Built-in languages: `en` (the default) and `pl`. A config picks one with
`locale.lang` and can override single strings with `locale.strings`:

    locale = { lang = "pl", decimal = ",", days = { ... }, strings = { refresh = "Reload" } }

Lookup order for a key: `locale.strings` -> the language table -> `en` -> the
key itself. Strings may contain `%s` / `%d` placeholders; `t(key, ...)` runs
`string.format` when it gets extra arguments.

User labels from the config (button labels, titles, confirm texts) are user
data and are never translated here.
]]

local I18n = {}

I18n.DEFAULT_LANG = "en"

I18n.STRINGS = {
    en = {
        refresh = "Refresh",
        close = "Close",
        sent = "Sent",
        actions_off = "Actions disabled (test mode)",
        no_action = "No action",
        no_data = "no data",
        no_forecast = "no forecast",
        wifi_off = "off",
        humidity = "humidity",
        pressure = "pressure",
        now = "now %s",
        sunrise = "sunrise %s",
        sunset = "sunset %s",
        today = "Today",
        updated = "updated %s",
        updated_short = "upd. %s",
        every_min = "every %d min",
        offline = "offline",
        error = "error",
        error_code = "error %s",
        config_not_found = "Configuration not found.\n\nCopy homedash.koplugin/config.example.lua to:\n%s",
        config_cannot_open = "Cannot open the configuration:\n%s",
        config_error = "Configuration error:\n%s",
        ["cond.clear-night"] = "clear night",
        ["cond.cloudy"] = "cloudy",
        ["cond.exceptional"] = "exceptional",
        ["cond.fog"] = "fog",
        ["cond.hail"] = "hail",
        ["cond.lightning"] = "thunderstorm",
        ["cond.lightning-rainy"] = "thunderstorm, rain",
        ["cond.partlycloudy"] = "partly cloudy",
        ["cond.pouring"] = "pouring rain",
        ["cond.rainy"] = "rain",
        ["cond.snowy"] = "snow",
        ["cond.snowy-rainy"] = "sleet",
        ["cond.sunny"] = "sunny",
        ["cond.windy"] = "windy",
        ["cond.windy-variant"] = "gusty wind",
        ["compass.1"] = "N",
        ["compass.2"] = "NE",
        ["compass.3"] = "E",
        ["compass.4"] = "SE",
        ["compass.5"] = "S",
        ["compass.6"] = "SW",
        ["compass.7"] = "W",
        ["compass.8"] = "NW",
    },
    pl = {
        refresh = "Odśwież",
        close = "Zamknij",
        sent = "Wysłano",
        actions_off = "Akcje wyłączone (tryb testowy)",
        no_action = "Brak akcji",
        no_data = "brak danych",
        no_forecast = "brak prognozy",
        wifi_off = "brak",
        humidity = "wilgotność",
        pressure = "ciśnienie",
        now = "teraz %s",
        sunrise = "wschód %s",
        sunset = "zachód %s",
        today = "Dziś",
        updated = "aktualizacja %s",
        updated_short = "akt. %s",
        every_min = "co %d min",
        offline = "offline",
        error = "błąd",
        error_code = "błąd %s",
        config_not_found = "Nie znaleziono konfiguracji.\n\nSkopiuj homedash.koplugin/config.example.lua do:\n%s",
        config_cannot_open = "Nie mogę otworzyć konfiguracji:\n%s",
        config_error = "Błąd konfiguracji:\n%s",
        ["cond.clear-night"] = "bezchmurnie (noc)",
        ["cond.cloudy"] = "pochmurno",
        ["cond.exceptional"] = "wyjątkowo",
        ["cond.fog"] = "mgła",
        ["cond.hail"] = "grad",
        ["cond.lightning"] = "burza",
        ["cond.lightning-rainy"] = "burza z deszczem",
        ["cond.partlycloudy"] = "przejaśnienia",
        ["cond.pouring"] = "ulewa",
        ["cond.rainy"] = "deszcz",
        ["cond.snowy"] = "śnieg",
        ["cond.snowy-rainy"] = "śnieg z deszczem",
        ["cond.sunny"] = "słonecznie",
        ["cond.windy"] = "wietrznie",
        ["cond.windy-variant"] = "porywisty wiatr",
        ["compass.1"] = "pn.",
        ["compass.2"] = "pn.-wsch.",
        ["compass.3"] = "wsch.",
        ["compass.4"] = "pd.-wsch.",
        ["compass.5"] = "pd.",
        ["compass.6"] = "pd.-zach.",
        ["compass.7"] = "zach.",
        ["compass.8"] = "pn.-zach.",
    },
}

--- Decimal mark per language.
I18n.DECIMAL = { en = ".", pl = "," }

--- Weekday abbreviations per language, Sunday first (`os.date("*t").wday`).
I18n.DAYS = {
    en = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    pl = { "niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob." },
}

--- Every Home Assistant weather condition code that has a `cond.<code>` string.
I18n.CONDITION_CODES = {
    "clear-night", "cloudy", "exceptional", "fog", "hail", "lightning",
    "lightning-rainy", "partlycloudy", "pouring", "rainy", "snowy",
    "snowy-rainy", "sunny", "windy", "windy-variant",
}

--- True when `lang` is a built-in language.
function I18n.has_lang(lang)
    return type(lang) == "string" and I18n.STRINGS[lang] ~= nil
end

--- Resolve a key without a translator: language table -> `en` -> the key.
-- `overrides` (optional) wins over both. Unknown languages behave like `en`.
function I18n.lookup(lang, key, overrides)
    if type(overrides) == "table" and type(overrides[key]) == "string" then
        return overrides[key]
    end
    local own = I18n.STRINGS[lang]
    if own and own[key] ~= nil then
        return own[key]
    end
    local fallback = I18n.STRINGS[I18n.DEFAULT_LANG]
    if fallback[key] ~= nil then
        return fallback[key]
    end
    return key
end

--- Translator for a `locale` config table (may be nil).
-- Returns `{ lang, decimal, days, t = function(key, ...), condition = function(code),
-- compass = function(bearing) }`. `decimal` and `days` follow the language unless the
-- locale overrides them.
function I18n.new(locale)
    locale = type(locale) == "table" and locale or {}
    local lang = I18n.has_lang(locale.lang) and locale.lang or I18n.DEFAULT_LANG
    local overrides = type(locale.strings) == "table" and locale.strings or nil
    local tr = {
        lang = lang,
        decimal = (type(locale.decimal) == "string" and locale.decimal ~= "") and locale.decimal
            or I18n.DECIMAL[lang],
        days = type(locale.days) == "table" and locale.days or I18n.DAYS[lang],
    }
    function tr.t(key, ...)
        local text = I18n.lookup(lang, key, overrides)
        if select("#", ...) > 0 then
            local ok, formatted = pcall(string.format, text, ...)
            if ok then
                return formatted
            end
        end
        return text
    end
    --- Display text for a weather condition code; unknown codes are returned as they are.
    function tr.condition(code)
        local key = "cond." .. tostring(code)
        local text = I18n.lookup(lang, key, overrides)
        if text == key then
            return code
        end
        return text
    end
    --- 8-point compass abbreviation, meteorological: 0 degrees is wind from the north.
    function tr.compass(bearing)
        if type(bearing) ~= "number" then
            return nil
        end
        local b = bearing % 360
        local idx = math.floor((b + 22.5) / 45) % 8
        return I18n.lookup(lang, "compass." .. (idx + 1), overrides)
    end
    return tr
end

return I18n
