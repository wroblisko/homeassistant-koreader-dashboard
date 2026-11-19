--[[--
Pure helpers for homedash.

Load this module with `require("homedash_util")`. KOReader's `util`
(`frontend/util.lua`, used for `makePath`) is a different module.
]]

local M = {}

--- Clamp `value` into the inclusive range `[lo, hi]`.
function M.clamp(value, lo, hi)
    if value < lo then
        return lo
    end
    if value > hi then
        return hi
    end
    return value
end

--- Format a temperature for the dashboard.
-- One decimal digit, Polish decimal comma, degree sign.
-- `nil`, `"unavailable"` and `"unknown"` (and anything that is not a number)
-- become an em dash.
function M.format_temp(v)
    if v == nil or v == "unavailable" or v == "unknown" then
        return "—"
    end
    local n = v
    if type(n) ~= "number" then
        n = tonumber(n)
    end
    if type(n) ~= "number" then
        return "—"
    end
    -- Avoid string.format("%.1f"): sprintf follows LC_NUMERIC and may emit
    -- a comma or a dot. Build the text ourselves instead.
    local sign = ""
    if n < 0 then
        sign = "-"
        n = -n
    end
    local tenths = math.floor(n * 10 + 0.5)
    local whole = math.floor(tenths / 10)
    local frac = tenths % 10
    return string.format("%s%d,%d°", sign, whole, frac)
end

--- Safety switch for button actions. `value` is the HOMEDASH_ACTIONS env.
-- Only the exact string "off" disables actions.
function M.actions_enabled(value)
    return value ~= "off"
end

return M
