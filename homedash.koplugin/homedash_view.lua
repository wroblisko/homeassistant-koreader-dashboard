--[[--
Full-screen Home Assistant dashboard.

Section heights are a share of the screen, fonts go through Font:getFace
(which calls Screen:scaleBySize). Nothing is positioned for a single Kindle.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local Data = require("homedash_data")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local HA = require("homedash_ha")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local RenderText = require("ui/rendertext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local icons = require("homedash_icons")
local model = require("homedash_model")
local i18n = require("homedash_i18n")
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY
local INK = Blitbuffer.COLOR_GRAY_2
local GRID = Blitbuffer.Color8(0xC8)
local RULE = Blitbuffer.Color8(0xAA)
local NIGHT = Blitbuffer.Color8(0xE4)
local BAR = Blitbuffer.Color8(0x77)

local VIEW_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")

local function sbs(px)
    return Screen:scaleBySize(px)
end

local function face(name, px)
    return Font:getFace(name, px)
end

local function paint_mid_y(widget, y, h)
    return y + math.floor((h - widget:getSize().h) / 2)
end

local function paint_right(widget, bb, right, y)
    widget:paintTo(bb, right - widget:getSize().w, y)
end

local function free_widgets(list)
    for i = 1, #list do
        if list[i].free then
            list[i]:free()
        end
    end
end

local function draw_line(bb, x0, y0, x1, y1, color, thick)
    thick = thick or 2
    local half = math.floor(thick / 2)
    x0 = math.floor(x0 + 0.5)
    y0 = math.floor(y0 + 0.5)
    x1 = math.floor(x1 + 0.5)
    y1 = math.floor(y1 + 0.5)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy
    local guard = 0
    while guard < 4000 do
        bb:paintRect(x0 - half, y0 - half, thick, thick, color)
        if x0 == x1 and y0 == y1 then
            break
        end
        local e2 = err * 2
        if e2 > -dy then
            err = err - dy
            x0 = x0 + sx
        end
        if e2 < dx then
            err = err + dx
            y0 = y0 + sy
        end
        guard = guard + 1
    end
end

local function text_size(text_face, text, bold)
    return RenderText:sizeUtf8Text(0, 4096, text_face, text, true, bold and true or false)
end

local function draw_text(bb, text_face, text, x, baseline, color, anchor, bold)
    local size = text_size(text_face, text, bold)
    local dx = x
    if anchor == "right" then
        dx = x - size.x
    elseif anchor == "center" then
        dx = x - math.floor(size.x / 2)
    end
    RenderText:renderUtf8Text(bb, dx, baseline, text_face, text, true, bold and true or false, color)
    return size
end

local function baseline_in(size, top, height)
    return top + math.floor((height + size.y_top - size.y_bottom) / 2)
end

-- Arrow points where the wind is going. `bearing` is the direction it comes from.
local function draw_arrow(bb, cx, cy, bearing, length, color)
    local rad = math.rad((bearing + 180) % 360)
    local dx = math.sin(rad)
    local dy = -math.cos(rad)
    local x1 = cx - dx * length * 0.4
    local y1 = cy - dy * length * 0.4
    local x2 = cx + dx * length * 0.55
    local y2 = cy + dy * length * 0.55
    draw_line(bb, x1, y1, x2, y2, color)
    local head = math.max(3, length * 0.45)
    local back = rad + math.pi
    draw_line(bb, x2, y2, x2 + math.sin(back - 0.5) * head, y2 - math.cos(back - 0.5) * head, color)
    draw_line(bb, x2, y2, x2 + math.sin(back + 0.5) * head, y2 - math.cos(back + 0.5) * head, color)
end

local function wrap_two(text_face, text, max_w, bold)
    local function width(s)
        return text_size(text_face, s, bold).x
    end
    if text == nil or text == "" or width(text) <= max_w then
        return { text or "" }
    end
    local words = {}
    for word in tostring(text):gmatch("%S+") do
        words[#words + 1] = word
    end
    if #words < 2 then
        return { text }
    end
    local best = 1
    for i = 1, #words - 1 do
        if width(table.concat(words, " ", 1, i)) <= max_w then
            best = i
        else
            break
        end
    end
    return {
        table.concat(words, " ", 1, best),
        table.concat(words, " ", best + 1, #words),
    }
end

local function icon_svg(name)
    if type(name) ~= "string" or not name:match("^[%w%-]+$") or not VIEW_DIR then
        return nil
    end
    local path = VIEW_DIR .. "/icons/" .. name .. ".svg"
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    handle:close()
    return path
end

local function paint_glyph(bb, text_face, glyph, x, top, height, color, anchor)
    if not text_face or type(glyph) ~= "string" or glyph == "" then
        return nil
    end
    local size = text_size(text_face, glyph, false)
    if size.x <= 0 then
        return nil
    end
    local baseline = baseline_in(size, top, height)
    return draw_text(bb, text_face, glyph, x, baseline, color or BLACK, anchor or "left", false)
end

-- One grey line, centred in the section. Used when that section was never loaded.
local function draw_muted_line(bb, text_face, text, x, y, w, h)
    local size = RenderText:sizeUtf8Text(0, 4096, text_face, text, true, false)
    local baseline = y + math.floor((h + size.y_top - size.y_bottom) / 2)
    if baseline < y + size.y_top then
        baseline = y + size.y_top
    end
    draw_text(bb, text_face, text, x + math.floor(w / 2), baseline, INK, "center")
end

local function distribute(budget, order, mins, weights)
    local min_sum, weight_sum = 0, 0
    for _, key in ipairs(order) do
        min_sum = min_sum + mins[key]
        weight_sum = weight_sum + weights[key]
    end
    if min_sum > budget and min_sum > 0 then
        local heights, used = {}, 0
        for i, key in ipairs(order) do
            if i == #order then
                heights[key] = math.max(1, budget - used)
            else
                heights[key] = math.max(1, math.floor(budget * mins[key] / min_sum))
                used = used + heights[key]
            end
        end
        return heights
    end
    local extra = budget - min_sum
    local heights, used = {}, 0
    for i, key in ipairs(order) do
        if i == #order then
            heights[key] = math.max(1, budget - used)
        else
            local h = mins[key]
            if extra > 0 and weight_sum > 0 then
                h = h + math.floor(extra * weights[key] / weight_sum)
            end
            heights[key] = h
            used = used + h
        end
    end
    return heights
end

-- Daily table: whole degrees. Half away from zero (9,1 → 9, 11,6 → 12).
local function fmt_temp(value, sep)
    if type(value) ~= "number" then
        return "—"
    end
    local n = value
    local sign = 1
    if n < 0 then
        sign = -1
        n = -n
    end
    return model.format_number(sign * math.floor(n + 0.5), sep) .. "°"
end

-- Daily precipitation: one decimal always ("3.0 mm" in English, "3,0 mm" in Polish) so rows line up. Under 0.05 is nothing.
local function fmt_mm(value, sep)
    if type(value) ~= "number" or value < 0.05 then
        return nil
    end
    return (string.format("%.1f", value):gsub("%.", sep)) .. " mm"
end

local function settings_config_path()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/homedash_config.lua"
end

local hd_util = require("homedash_util")

-- Returns `config, path` or `nil, message, translator`. The message is translated
-- once the config has been read far enough to know `locale`; before that it is English.
local function load_config()
    local env = os.getenv("HOMEDASH_CONFIG")
    local path
    local missing_is_settings = false
    local tr = i18n.new(nil)
    if env and env ~= "" then
        path = env
    else
        path = settings_config_path()
        missing_is_settings = true
    end
    local handle = io.open(path, "rb")
    if not handle then
        if missing_is_settings then
            return nil, tr.t("config_not_found", path), tr
        end
        return nil, tr.t("config_cannot_open", path), tr
    end
    handle:close()
    local chunk, load_err = loadfile(path)
    if not chunk then
        return nil, tr.t("config_error", tostring(load_err)), tr
    end
    local ok, result = pcall(chunk)
    if not ok then
        return nil, tr.t("config_error", tostring(result)), tr
    end
    if type(result) == "table" then
        tr = i18n.new(result.locale)
    end
    local problem = model.validate(result)
    if problem then
        return nil, tr.t("config_error", problem), tr
    end
    model.defaults(result)
    return result, path, tr
end

local function saveScreenshot(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        local util = require("util")
        local made, mk_err = util.makePath(dir)
        if not made then
            logger.err("[homedash]", "screenshot directory:", mk_err)
        end
    end
    UIManager:forceRePaint()
    local called_ok, shot_ok, shot_err = pcall(Screen.shot, Screen, path)
    if called_ok and shot_ok then
        logger.info("[homedash]", "screenshot saved", path)
        return
    end
    logger.err("[homedash]", "screenshot failed:", called_ok and shot_err or shot_ok)
end

-- Header: title, local date and time, and the Refresh / Close buttons.
local Header = InputContainer:extend{}

function Header:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.title_w = TextWidget:new{
        text = self.title or "",
        face = face("tfont", 22),
        bold = true,
        max_width = math.floor(self.width * 0.28),
    }
    self.date_w = TextWidget:new{
        text = "—",
        face = face("infofont", 14),
        fgcolor = INK,
        max_width = math.floor(self.width * 0.5),
    }
    self.btn_face = face("infofont", 15)
    self.btn_icon_face = face("nerdfonts/symbols.ttf", 15)
    self.status_face = face("infofont", 13)
    self.status_icon_face = face("nerdfonts/symbols.ttf", 14)
    self._owned = { self.title_w, self.date_w }
    self.status = { battery = nil, charging = false, wifi = nil }
    self.buttons = {
        refresh = { glyph = icons.GLYPH.refresh, text = self.tr.t("refresh"), dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 } },
        close = { glyph = icons.GLYPH.close, text = self.tr.t("close"), dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 } },
    }
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            },
        },
    }
end

function Header:free()
    free_widgets(self._owned)
end

-- Outlined rounded button with an icon and a label. Returns its width.
function Header:_button(bb, btn, right, y, h)
    local glyph = icons.char(btn.glyph)
    local gsize = glyph and text_size(self.btn_icon_face, glyph, false) or nil
    local tsize = text_size(self.btn_face, btn.text, true)
    local pad = sbs(10)
    local gap = sbs(6)
    local bw = pad * 2 + tsize.x + (gsize and (gsize.x + gap) or 0)
    local bx = right - bw
    local bh = math.min(h - 2, tsize.y_top + tsize.y_bottom + sbs(14))
    local by = y + math.floor((h - bh) / 2)
    btn.dimen.x, btn.dimen.y, btn.dimen.w, btn.dimen.h = bx, by, bw, bh
    bb:paintRoundedRect(bx, by, bw, bh, WHITE, sbs(8))
    bb:paintBorder(bx, by, bw, bh, math.max(2, sbs(1)), BLACK, sbs(8), false)
    local cx = bx + pad
    if gsize then
        paint_glyph(bb, self.btn_icon_face, glyph, cx, by, bh, BLACK, "left")
        cx = cx + gsize.x + gap
    end
    draw_text(bb, self.btn_face, btn.text, cx, baseline_in(tsize, by, bh), BLACK, "left", true)
    return bw
end

-- Small device status: battery (icon + percent, bolt when charging) and Wi-Fi.
-- Returns the width used. Draws right-aligned at `right`.
function Header:_status(bb, right, y, h)
    local face_t = self.status_face
    local icon_f = self.status_icon_face
    local st = self.status or {}
    local gap = sbs(10)
    local cx = right
    local function piece(glyph, text, color)
        local gsize = glyph and text_size(icon_f, glyph, false) or nil
        local tsize = text and text_size(face_t, text, false) or nil
        local wdt = (gsize and gsize.x or 0) + (gsize and tsize and sbs(6) or 0) + (tsize and tsize.x or 0)
        local sx = cx - wdt
        if gsize then
            paint_glyph(bb, icon_f, glyph, sx, y, h, color, "left")
            sx = sx + gsize.x + sbs(6)
        end
        if tsize then
            draw_text(bb, face_t, text, sx, baseline_in(tsize, y, h), color, "left", false)
        end
        cx = cx - wdt - gap
    end
    if st.wifi ~= nil then
        if st.wifi then
            piece(icons.char(icons.GLYPH.wifi), nil, BLACK)
        else
            piece(icons.char(icons.GLYPH.wifi), self.tr.t("wifi_off"), INK)
        end
    end
    if st.battery then
        local text = tostring(st.battery) .. "%"
        if st.charging then
            text = text .. icons.char(icons.GLYPH.bolt)
        end
        piece(icons.char(icons.battery_glyph(st.battery)), text, BLACK)
    end
    return right - cx - gap
end

function Header:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)
    local gap = sbs(8)
    local right = x + w
    right = right - self:_button(bb, self.buttons.close, right, y, h) - gap
    local rb_w = self:_button(bb, self.buttons.refresh, right, y, h)
    local left_of_buttons = right - rb_w
    self.title_w:paintTo(bb, x, paint_mid_y(self.title_w, y, h))
    local date_x = x + self.title_w:getSize().w + sbs(10)
    local status_w = self:_status(bb, left_of_buttons - gap, y, h)
    local date_max = left_of_buttons - gap - status_w - gap - date_x
    if date_max < sbs(24) then
        date_max = sbs(24)
    end
    self.date_w:setMaxWidth(date_max)
    self.date_w:paintTo(bb, date_x, paint_mid_y(self.date_w, y, h))
end

function Header:onTap(_, ges)
    if ges and ges.pos then
        if self.buttons.close.dimen:contains(ges.pos) then
            if self.on_close then
                self.on_close()
            end
            return true
        end
        if self.buttons.refresh.dimen:contains(ges.pos) then
            if self.on_refresh then
                self.on_refresh()
            end
            return true
        end
    end
    return false
end

local WeatherBlock = Widget:extend{}

function WeatherBlock:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.icon_face = face("nerdfonts/symbols.ttf", 64)
    self.row_icon = face("nerdfonts/symbols.ttf", 17)
    self.temp_face = face("tfont", 60)
    self.label_face = face("infofont", 16)
    self.note_face = face("infofont", 16)
    self.missing = false
end

function WeatherBlock:free()
end

-- One line of the right-hand list: icon (or the wind arrow), label, bold value, optional tail.
function WeatherBlock:_row(bb, x, top, h, row)
    local icon_col = sbs(26)
    local vsize = text_size(self.value_face, "0", true)
    local baseline = baseline_in(vsize, top, h)
    if row.arrow then
        local len = sbs(16)
        draw_arrow(bb, x + math.floor(icon_col / 2) - sbs(2), top + math.floor(h / 2), row.arrow, len, BLACK)
    else
        paint_glyph(bb, self.row_icon, icons.char(row.glyph), x, top, h, BLACK, "left")
    end
    local cx = x + icon_col
    if row.label then
        local size = draw_text(bb, self.label_face, row.label .. " ", cx, baseline, INK, "left", false)
        cx = cx + size.x
    end
    local size = draw_text(bb, self.value_face, row.value, cx, baseline, BLACK, "left", true)
    cx = cx + size.x
    if row.tail then
        draw_text(bb, self.label_face, " " .. row.tail, cx, baseline, INK, "left", false)
    end
end

function WeatherBlock:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)
    local body_h = h - sbs(4)
    bb:paintRect(x, y + h - 1, w, 1, RULE)
    if self.missing then
        draw_muted_line(bb, self.note_face, self.tr.t("no_data"), x, y, w, body_h)
        return
    end
    self.value_face = self.value_face or face("infofont", 17)
    local cursor = x + sbs(2)
    if self.glyph then
        local drawn = paint_glyph(bb, self.icon_face, self.glyph, cursor, y, body_h, BLACK, "left")
        if drawn then
            cursor = cursor + drawn.x + sbs(20)
        end
    elseif self.fallback then
        local size = text_size(self.label_face, self.fallback, false)
        draw_text(bb, self.label_face, self.fallback, cursor, baseline_in(size, y, body_h), INK, "left", false)
        cursor = cursor + size.x + sbs(20)
    end
    if self.temp then
        local size = text_size(self.temp_face, self.temp, true)
        draw_text(bb, self.temp_face, self.temp, cursor, baseline_in(size, y, body_h), BLACK, "left", true)
        cursor = cursor + size.x
    end
    local list_x = math.max(cursor + sbs(16), x + math.floor(w * 0.56))
    local rows = {}
    if self.humidity then
        rows[#rows + 1] = { glyph = icons.GLYPH.humidity, label = self.tr.t("humidity"), value = self.humidity }
    end
    if self.wind_speed then
        rows[#rows + 1] = {
            glyph = icons.GLYPH.wind,
            arrow = type(self.wind_bearing) == "number" and self.wind_bearing or nil,
            value = self.wind_speed,
            tail = self.wind_compass,
        }
    elseif self.wind_compass then
        rows[#rows + 1] = { glyph = icons.GLYPH.wind, arrow = self.wind_bearing, value = self.wind_compass }
    end
    if self.pressure then
        rows[#rows + 1] = { glyph = icons.GLYPH.pressure, label = self.tr.t("pressure"), value = self.pressure }
    end
    local row_h = math.floor(body_h / 3)
    local top = y + math.floor((body_h - row_h * #rows) / 2)
    for i, row in ipairs(rows) do
        self:_row(bb, list_x, top + (i - 1) * row_h, row_h, row)
    end
end

local Chart = Widget:extend{}

function Chart:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.series = { points = {}, hours = 18, precip_scale = 2, temp_min = 0, temp_max = 1 }
    self.sep = self.sep or "."
    self.offset = self.offset or 0
    self.label_face = face("infofont", 12)
    self.small_face = face("infofont", 11)
    self.note_face = face("infofont", 16)
    self.missing = false
end

function Chart:setSeries(series)
    self.series = series or self.series
end

local function rects_overlap(a, b, margin)
    margin = margin or 0
    return a.x0 < b.x1 + margin and b.x0 < a.x1 + margin and a.y0 < b.y1 + margin and b.y0 < a.y1 + margin
end

function Chart:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)
    local series = self.series or {}
    local points = series.points or {}
    if self.missing or #points == 0 then
        draw_muted_line(bb, self.note_face, self.tr.t("no_forecast"), x, y, w, h)
        return
    end
    local sep = self.sep
    local offset = self.offset
    local lf, sf = self.label_face, self.small_face
    local scale = series.precip_scale or 2
    if scale <= 0 then
        scale = 2
    end
    local ticks = series.temp_ticks or {}
    local left_w = 0
    for _, tick in ipairs(ticks) do
        left_w = math.max(left_w, text_size(lf, model.format_number(tick, sep) .. "°", false).x)
    end
    left_w = left_w + sbs(5)
    local scale_text = model.format_number(scale, sep) .. " mm"
    local half_text = model.format_number(scale / 2, sep) .. " mm"
    local right_w = math.max(text_size(lf, scale_text, false).x, text_size(lf, half_text, false).x) + sbs(5)
    local row_h = sbs(15)
    local top_pad = sbs(8)
    local plot_x = x + left_w
    local plot_y = y + top_pad
    local plot_w = w - left_w - right_w
    local plot_h = h - top_pad - row_h * 2 - sbs(3)
    if plot_w < 8 or plot_h < 8 then
        return
    end
    local plot_bottom = plot_y + plot_h
    local span = (series.temp_max or 1) - (series.temp_min or 0)
    if span <= 0 then
        span = 1
    end
    local window = (series.hours or 18) * 3600
    if window <= 0 then
        window = 18 * 3600
    end
    local function x_of(epoch)
        local frac = (epoch - (series.now or epoch)) / window
        if frac < 0 then frac = 0 end
        if frac > 1 then frac = 1 end
        return plot_x + frac * plot_w
    end
    local function y_of(temp)
        local frac = (temp - (series.temp_min or 0)) / span
        return plot_bottom - frac * plot_h
    end

    -- Night shading.
    for _, interval in ipairs(series.night or {}) do
        local x0 = math.floor(x_of(interval.from))
        local x1 = math.ceil(x_of(interval.to))
        if x1 > x0 then
            bb:paintRect(x0, plot_y, x1 - x0, plot_h + 1, NIGHT)
        end
    end

    -- Temperature grid and left axis.
    local lsize = text_size(lf, "0", false)
    for _, tick in ipairs(ticks) do
        local ty = math.floor(y_of(tick) + 0.5)
        if ty >= plot_y and ty <= plot_bottom then
            bb:paintRect(plot_x, ty, plot_w, 1, GRID)
            draw_text(bb, lf, model.format_number(tick, sep) .. "°", plot_x - sbs(3),
                ty + math.floor((lsize.y_top - lsize.y_bottom) / 2), INK, "right")
        end
    end
    bb:paintRect(plot_x, plot_bottom, plot_w, 1, INK)

    -- Right axis.
    local rx = x + w - sbs(1)
    draw_text(bb, lf, scale_text, rx, plot_y + math.floor((lsize.y_top - lsize.y_bottom) / 2) + sbs(1), INK, "right")
    draw_text(bb, lf, half_text, rx, math.floor(plot_y + plot_h / 2) + math.floor((lsize.y_top - lsize.y_bottom) / 2),
        INK, "right")
    draw_text(bb, lf, "0", rx, plot_bottom + math.floor((lsize.y_top - lsize.y_bottom) / 2) - sbs(1), INK, "right")

    -- Precipitation bars.
    local bar_w = math.max(2, math.floor(plot_w / math.max(#points, series.hours or #points) * 0.62))
    local bars = {}
    for i = 1, #points do
        local precip = points[i].precip or 0
        if precip > 0 then
            local bh = math.min(plot_h, math.max(1, precip / scale * plot_h))
            local px = x_of(points[i].epoch)
            local bx = math.floor(px - bar_w / 2)
            if bx < plot_x then
                bx = plot_x
            end
            local bw = bar_w
            if bx + bw > plot_x + plot_w then
                bw = math.floor(plot_x + plot_w - bx)
            end
            if bw >= 1 then
                bb:paintRect(bx, math.floor(plot_bottom - bh), bw, math.floor(bh), BAR)
                bars[#bars + 1] = { cx = bx + bw / 2, top = math.floor(plot_bottom - bh), value = precip, h = bh }
            end
        end
    end

    -- Temperature line.
    local thick = math.max(2, math.floor(sbs(2.5) + 0.5))
    local xy = {}
    local prev_x, prev_y
    for i = 1, #points do
        local temp = points[i].temp
        if temp then
            local px, py = x_of(points[i].epoch), y_of(temp)
            xy[i] = { px, py }
            if prev_x then
                draw_line(bb, prev_x, prev_y, px, py, BLACK, thick)
            end
            prev_x, prev_y = px, py
        else
            prev_x, prev_y = nil, nil
        end
    end

    local function line_hit(r, margin)
        for sx = math.floor(r.x0), math.ceil(r.x1), 2 do
            for i = 1, #points - 1 do
                local a, b = xy[i], xy[i + 1]
                if a and b and sx >= a[1] and sx <= b[1] and b[1] > a[1] then
                    local ly = a[2] + (b[2] - a[2]) * (sx - a[1]) / (b[1] - a[1])
                    if ly >= r.y0 - margin and ly <= r.y1 + margin then
                        return true
                    end
                    break
                end
            end
        end
        return false
    end

    -- Value labels.
    local placed = {}
    local function free_of_labels(r)
        for _, p in ipairs(placed) do
            if rects_overlap(r, p, sbs(2)) then
                return false
            end
        end
        return true
    end
    -- Dark text on a grey bar is hard to read: bars are obstacles for temperature labels.
    local function over_bar(r)
        for _, bar in ipairs(bars) do
            local br = { x0 = bar.cx - bar_w / 2, x1 = bar.cx + bar_w / 2, y0 = bar.top, y1 = plot_bottom }
            if rects_overlap(r, br, 0) then
                return true
            end
        end
        return false
    end
    local dot_r = sbs(3)
    local function label_point(i, forced)
        local p, pt = points[i], xy[i]
        if not pt then
            return
        end
        local text = model.format_number(p.temp, sep)
        local size = text_size(lf, text, false)
        local tw, th = size.x, size.y_top + size.y_bottom
        local px, py = pt[1], pt[2]
        local gap = dot_r + sbs(3)
        local cands = {
            { px - tw / 2, py - gap - th },
            { px - tw / 2, py + gap },
            { px - tw - sbs(2), py - gap - th },
            { px + sbs(2), py - gap - th },
            { px - tw - sbs(2), py + gap },
            { px + sbs(2), py + gap },
        }
        local fallback
        for _, c in ipairs(cands) do
            local cx = math.max(plot_x, math.min(c[1], plot_x + plot_w - tw))
            local r = { x0 = cx, y0 = c[2], x1 = cx + tw, y1 = c[2] + th }
            if r.y0 >= y and r.y1 <= plot_bottom + 1 and free_of_labels(r) then
                fallback = fallback or r
                if not line_hit(r, sbs(1)) and not over_bar(r) then
                    placed[#placed + 1] = r
                    bb:paintCircle(math.floor(px + 0.5), math.floor(py + 0.5), dot_r, BLACK)
                    draw_text(bb, lf, text, r.x0, r.y0 + size.y_top, BLACK, "left")
                    return
                end
            end
        end
        if forced and fallback then
            placed[#placed + 1] = fallback
            bb:paintCircle(math.floor(px + 0.5), math.floor(py + 0.5), dot_r, BLACK)
            draw_text(bb, lf, text, fallback.x0, fallback.y0 + size.y_top, BLACK, "left")
        end
    end
    local min_i, max_i
    for i = 1, #points do
        local temp = points[i].temp
        if temp then
            if not min_i or temp < points[min_i].temp then
                min_i = i
            end
            if not max_i or temp > points[max_i].temp then
                max_i = i
            end
        end
    end
    if max_i then
        label_point(max_i, true)
    end
    if min_i and min_i ~= max_i then
        label_point(min_i, true)
    end
    for i = 1, #points, 3 do
        if i ~= min_i and i ~= max_i then
            label_point(i, false)
        end
    end

    -- Precipitation labels, above the bar.
    local ssize = text_size(sf, "0", false)
    for _, bar in ipairs(bars) do
        local text = model.format_number(bar.value, sep)
        local size = text_size(sf, text, false)
        local th = size.y_top + size.y_bottom
        local r = {
            x0 = bar.cx - size.x / 2, y0 = bar.top - sbs(1) - th,
            x1 = bar.cx + size.x / 2, y1 = bar.top - sbs(1),
        }
        r.x0 = math.max(plot_x, math.min(r.x0, plot_x + plot_w - size.x))
        r.x1 = r.x0 + size.x
        if r.y0 >= plot_y - sbs(2) and free_of_labels(r) and not line_hit(r, sbs(1)) then
            placed[#placed + 1] = r
            draw_text(bb, sf, text, r.x0, r.y0 + size.y_top, INK, "left")
        elseif bar.h >= th + sbs(3) and bar.cx - size.x / 2 >= plot_x then
            -- No room above: print it inside the bar, white on grey.
            draw_text(bb, sf, text, math.floor(bar.cx - size.x / 2), bar.top + sbs(1) + size.y_top, WHITE, "left")
        end
    end
    local _ = ssize

    -- Time axis: tick every hour, label every second hour.
    local hour_base = plot_bottom + sbs(3) + row_h - sbs(3)
    local first = math.ceil(((series.now or 0) + offset * 60) / 3600) * 3600 - offset * 60
    local t = first
    local tick_h = sbs(4)
    while t <= (series.now or 0) + window do
        local tx = math.floor(x_of(t) + 0.5)
        bb:paintRect(tx, plot_bottom, 1, tick_h, BLACK)
        local hour = model.local_parts(t, offset).hour
        if hour % 2 == 1 then
            draw_text(bb, lf, tostring(hour), tx, hour_base + sbs(1), BLACK, "center")
        end
        t = t + 3600
    end

    -- Captions: "teraz HH:MM" at the left, sunrise / sunset at their boundary.
    local cap_base = y + h - sbs(2)
    local teraz = draw_text(bb, lf, self.tr.t("now", model.format_clock(series.now, offset)),
        x + sbs(2), cap_base, BLACK, "left", true)
    local min_x = x + sbs(2) + teraz.x + sbs(8)
    for _, ev in ipairs(series.sun_events or {}) do
        local text = self.tr.t(ev.kind == "rising" and "sunrise" or "sunset", model.format_hm(ev.epoch, offset))
        local size = text_size(lf, text, false)
        local cx = x_of(ev.epoch) - size.x / 2
        cx = math.max(min_x, math.min(cx, plot_x + plot_w - size.x))
        draw_text(bb, lf, text, math.floor(cx), cap_base, INK, "left")
        min_x = cx + size.x + sbs(6)
    end
end

local DailyBlock = Widget:extend{}

function DailyBlock:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.rows_data = {}
    self.note_face = face("infofont", 16)
    self.text_face = face("infofont", 17)
    self.day_face = face("infofont", 18)
    self.cond_icon_face = face("nerdfonts/symbols.ttf", 22)
    self.icon_face = face("nerdfonts/symbols.ttf", 17)
    self.missing = false
    local n = self.nrows or 1
    if n < 1 then
        n = 1
    end
    self.nrows = n
end

function DailyBlock:free()
end

-- Icon in a fixed column, then the text. Missing text keeps the column empty.
function DailyBlock:_cell(bb, glyph, icon_face, icon_col, text, bold, color, x, top, h)
    if glyph then
        paint_glyph(bb, icon_face, glyph, x, top, h, BLACK, "left")
    end
    if text then
        local size = text_size(self.text_face, text, bold)
        draw_text(bb, self.text_face, text, x + icon_col, baseline_in(size, top, h), color or BLACK, "left", bold)
    end
end

function DailyBlock:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, WHITE)
    if self.missing then
        draw_muted_line(bb, self.note_face, self.tr.t("no_forecast"), x, y, w, h)
        return
    end
    local n = self.nrows
    local row_h = math.floor(h / n)
    local c_day = x + sbs(2)
    local c_cond = x + math.floor(w * 0.17)
    local c_feels = x + math.floor(w * 0.40)
    local c_night = x + math.floor(w * 0.60)
    local c_rain = x + math.floor(w * 0.80)
    for i = 1, n do
        local ry = y + (i - 1) * row_h
        if i < n then
            bb:paintRect(x, ry + row_h - 1, w, 1, RULE)
        end
        local row = self.rows_data[i]
        if row then
            local dsize = text_size(self.day_face, row.label or "", true)
            draw_text(bb, self.day_face, row.label or "", c_day, baseline_in(dsize, ry, row_h), BLACK, "left", true)
            if row.glyph then
                self:_cell(bb, row.glyph, self.cond_icon_face, sbs(38), row.high, true, BLACK, c_cond, ry, row_h)
            else
                self:_cell(bb, nil, nil, 0, row.high, true, BLACK, c_cond, ry, row_h)
            end
            self:_cell(bb, icons.char(icons.GLYPH.hand), self.icon_face, sbs(24), row.feels, false, BLACK,
                c_feels, ry, row_h)
            self:_cell(bb, icons.char(icons.GLYPH.moon), self.icon_face, sbs(24), row.low, false, BLACK,
                c_night, ry, row_h)
            self:_cell(bb, icons.char(icons.GLYPH.raindrop), self.icon_face, sbs(24), row.precip or "—", false,
                row.precip and BLACK or INK, c_rain, ry, row_h)
        end
    end
end

local ValuesBlock = Widget:extend{}

function ValuesBlock:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.cells = {}
    self._owned = {}
    local cols = self.cols
    if cols < 1 then
        cols = 1
    end
    self.cols = cols
    local gap = sbs(8)
    self.gap = gap
    self.cell_w = math.floor((self.width - gap * (cols - 1)) / cols)
    local small = face("infofont", 15)
    for i = 1, #self.items do
        local item = self.items[i]
        local cell = {
            label = TextWidget:new{
                text = item.label or "",
                face = small,
                fgcolor = INK,
                max_width = math.floor(self.cell_w * 0.56),
            },
            value = TextWidget:new{
                text = "—",
                face = small,
                bold = true,
                max_width = math.floor(self.cell_w * 0.4),
            },
        }
        self.cells[i] = cell
        self._owned[#self._owned + 1] = cell.label
        self._owned[#self._owned + 1] = cell.value
    end
end

function ValuesBlock:free()
    free_widgets(self._owned)
end

function ValuesBlock:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)
    local n = #self.cells
    local rows = math.max(1, math.ceil(n / self.cols))
    local row_h = math.floor(self.dimen.h / rows)
    for i, cell in ipairs(self.cells) do
        local col = (i - 1) % self.cols
        local row = math.floor((i - 1) / self.cols)
        local cx = x + col * (self.cell_w + self.gap)
        local cy = y + row * row_h
        cell.label:paintTo(bb, cx, paint_mid_y(cell.label, cy, row_h))
        paint_right(cell.value, bb, cx + self.cell_w, paint_mid_y(cell.value, cy, row_h))
    end
end

local ButtonRow = InputContainer:extend{}

function ButtonRow:_iconWidget(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local cached = self._icons[name]
    if cached ~= nil then
        return cached or nil
    end
    local path = icon_svg(name)
    if not path then
        self._icons[name] = false
        return nil
    end
    local widget = ImageWidget:new{
        file = path,
        width = sbs(34),
        height = sbs(34),
        scale_factor = 0,
        is_icon = true,
        alpha = false,
    }
    self._icons[name] = widget
    self._owned[#self._owned + 1] = widget
    return widget
end

function ButtonRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.buttons = {}
    self._owned = {}
    self._icons = {}
    local cols = self.cols
    if not cols or cols < 1 then
        cols = 1
    end
    self.cols = cols
    local n = #self.items
    local rows = math.max(1, math.ceil(n / cols))
    local gap = sbs(8)
    self.gap = gap
    self.cell_w = math.floor((self.width - gap * (cols - 1)) / cols)
    self.cell_h = math.floor(self.height / rows)
    self.label_face = face("infofont", 16)
    self.state_face = face("infofont", 13)
    for i, item in ipairs(self.items) do
        self.buttons[i] = {
            id = item.id,
            item = item,
            label_text = item.label or "",
            state_text = nil,
            icon_name = item.icon,
            inverted = false,
            dimen = Geom:new{ x = 0, y = 0, w = self.cell_w, h = self.cell_h },
        }
    end
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            },
        },
    }
end

function ButtonRow:free()
    free_widgets(self._owned)
end

-- Icon, bold name and optional state text stacked in a VerticalGroup. Every
-- part is measured (TextWidget height), so nothing can overlap. The state line
-- is always reserved, which keeps the icons of all cards on one line.
function ButtonRow:_content(button, inner_w, fg)
    local temp = {}
    local group = { align = "center" }
    local icon_w = self:_iconWidget(button.icon_name)
    if icon_w then
        icon_w.invert = button.inverted and true or false
        group[#group + 1] = icon_w
    else
        group[#group + 1] = VerticalSpan:new{ width = sbs(34) }
    end
    group[#group + 1] = VerticalSpan:new{ width = sbs(6) }
    for _, line in ipairs(wrap_two(self.label_face, button.label_text or "", inner_w, true)) do
        if line ~= "" then
            local tw = TextWidget:new{
                text = line, face = self.label_face, bold = true, fgcolor = fg, max_width = inner_w,
            }
            temp[#temp + 1] = tw
            group[#group + 1] = tw
        end
    end
    group[#group + 1] = VerticalSpan:new{ width = sbs(3) }
    if button.state_text and button.state_text ~= "" then
        local tw = TextWidget:new{
            text = button.state_text, face = self.state_face, fgcolor = fg, max_width = inner_w,
        }
        temp[#temp + 1] = tw
        group[#group + 1] = tw
    else
        if not self._state_h then
            local probe = TextWidget:new{ text = "Ag", face = self.state_face }
            self._state_h = probe:getSize().h
            probe:free()
        end
        group[#group + 1] = VerticalSpan:new{ width = self._state_h }
    end
    return VerticalGroup:new(group), temp
end

function ButtonRow:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)
    local border = math.max(2, sbs(1))
    local radius = sbs(10)
    for i, button in ipairs(self.buttons) do
        local col = (i - 1) % self.cols
        local row = math.floor((i - 1) / self.cols)
        local bx = x + col * (self.cell_w + self.gap)
        local by = y + row * self.cell_h
        button.dimen.x = bx
        button.dimen.y = by
        button.dimen.w = self.cell_w
        button.dimen.h = self.cell_h
        local bg = button.inverted and BLACK or WHITE
        local fg = button.inverted and WHITE or BLACK
        bb:paintRoundedRect(bx, by, self.cell_w, self.cell_h, bg, radius)
        if not button.inverted then
            bb:paintBorder(bx, by, self.cell_w, self.cell_h, border, BLACK, radius, false)
        end
        local group, temp = self:_content(button, self.cell_w - sbs(12), fg)
        local size = group:getSize()
        group:paintTo(bb,
            bx + math.floor((self.cell_w - size.w) / 2),
            by + math.max(0, math.floor((self.cell_h - size.h) / 2)))
        free_widgets(temp)
    end
end

function ButtonRow:onTap(_, ges)
    if not ges or not ges.pos then
        return true
    end
    for i = 1, #self.buttons do
        local button = self.buttons[i]
        if button.dimen:contains(ges.pos) then
            if self.on_press then
                self.on_press(button)
            end
            return true
        end
    end
    return true
end

local Footer = Widget:extend{}

function Footer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local small = face("infofont", 12)
    self.status = TextWidget:new{
        text = "—",
        face = small,
        fgcolor = INK,
        max_width = math.floor(self.width * 0.68),
    }
    self.hint = TextWidget:new{
        text = self.hint_text or "",
        face = small,
        fgcolor = INK,
        max_width = math.floor(self.width * 0.3),
    }
end

function Footer:free()
    self.status:free()
    self.hint:free()
end

function Footer:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)
    self.status:paintTo(bb, x, paint_mid_y(self.status, y, self.dimen.h))
    paint_right(self.hint, bb, x + self.dimen.w, paint_mid_y(self.hint, y, self.dimen.h))
end

local Dashboard = InputContainer:extend{
    name = "homedash_dashboard",
    covers_fullscreen = true,
    modal = true,
    stop_events_propagation = true,
}

function Dashboard:_setupWindow()
    local screen = Screen:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = screen.h }
    local dpi = math.floor(Screen:getDPI() + 0.5)
    self.screen_line = string.format("%dx%d @ %d dpi", screen.w, screen.h, dpi)
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function() return self.dimen end,
            },
        }
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function Dashboard:_buildMessage(text)
    local screen = Screen:getSize()
    local pad = sbs(16)
    local info = TextBoxWidget:new{
        text = text,
        face = face("infofont", 16),
        width = screen.w - 2 * pad,
    }
    local close_button = Button:new{
        text = self.tr.t("close"),
        width = math.min(sbs(200), screen.w - 2 * pad),
        text_font_size = 18,
        show_parent = self,
        callback = function()
            self:onClose()
        end,
    }
    self[1] = FrameContainer:new{
        width = screen.w,
        height = screen.h,
        background = WHITE,
        bordersize = 0,
        padding = pad,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = screen.w - 2 * pad },
            VerticalSpan:new{ width = pad },
            info,
            VerticalSpan:new{ width = pad },
            close_button,
        },
    }
end

function Dashboard:_sectionWidget(section, width, height)
    local sep = self.config.locale.decimal
    local offset = self.config.locale.utc_offset_min
    local days = self.config.locale.days
    local kind = section.type
    if kind == "header" then
        local header = Header:new{
            tr = self.tr,
            width = width,
            height = height,
            title = section.title or "",
            on_close = function()
                self:onClose()
            end,
            on_refresh = function()
                self:refreshNow()
            end,
        }
        self._appliers[#self._appliers + 1] = function()
            header.date_w:setText(model.format_date(os.time(), offset, days))
            header.status = self:_deviceStatus()
        end
        return header
    end
    if kind == "weather_now" then
        local block = WeatherBlock:new{ tr = self.tr, width = width, height = height }
        self._appliers[#self._appliers + 1] = function()
            local weather = self.data:state(section.weather)
            local sensor = section.temperature and self.data:state(section.temperature) or nil
            local function alive(state)
                if type(state) ~= "table" then
                    return nil
                end
                if state.state == "unavailable" or state.state == "unknown" or state.state == nil then
                    return nil
                end
                return state
            end
            local live_weather = alive(weather)
            local hour = model.local_parts(os.time(), offset).hour
            local cond = live_weather and live_weather.state or nil
            block.glyph = type(cond) == "string" and icons.condition(cond, { hour = hour }) or nil
            block.fallback = nil
            if type(cond) == "string" and not block.glyph then
                local text = model.condition_text(cond, self.tr)
                if text ~= "—" and text ~= cond then
                    block.fallback = text
                elseif text ~= "—" then
                    block.fallback = text
                end
            end
            local temp_c
            if section.temperature then
                local live = alive(sensor)
                temp_c = live and tonumber(live.state) or nil
            elseif live_weather then
                local attrs = live_weather.attributes or {}
                temp_c = type(attrs.temperature) == "number" and attrs.temperature or tonumber(attrs.temperature)
            end
            block.temp = temp_c and (model.format_number(temp_c, sep) .. "°") or nil
            block.wind_speed, block.wind_bearing, block.wind_compass = nil, nil, nil
            block.humidity, block.pressure = nil, nil
            if live_weather then
                local attrs = live_weather.attributes or {}
                local rounded = model.wind_kmh_rounded(attrs.wind_speed, attrs.wind_speed_unit)
                if rounded then
                    block.wind_speed = model.format_number(rounded, sep) .. " km/h"
                end
                if type(attrs.wind_bearing) == "number" then
                    block.wind_bearing = attrs.wind_bearing
                    block.wind_compass = model.compass_abbr(attrs.wind_bearing, self.tr)
                end
                if type(attrs.humidity) == "number" then
                    block.humidity = model.format_number(math.floor(attrs.humidity + 0.5), sep) .. "%"
                end
                if type(attrs.pressure) == "number" then
                    local unit = attrs.pressure_unit
                    if type(unit) ~= "string" or unit == "" then
                        unit = "hPa"
                    end
                    block.pressure = model.format_number(math.floor(attrs.pressure + 0.5), sep) .. " " .. unit
                end
            end
            block.missing = not (block.glyph or block.fallback or block.temp or block.wind_speed or block.wind_compass or block.humidity or block.pressure)
        end
        return block
    end
    if kind == "chart" then
        local chart = Chart:new{ tr = self.tr, width = width, height = height, sep = sep, offset = offset }
        self._appliers[#self._appliers + 1] = function()
            local items = self.data:forecast(section.weather, "hourly")
            if not items then
                chart.missing = true
                return
            end
            chart.missing = false
            chart:setSeries(model.chart_series(items, {
                now = os.time(),
                hours = section.hours or 18,
                utc_offset_min = offset,
                sun = section.sun and self.data:state(section.sun) or nil,
            }))
        end
        return chart
    end
    if kind == "daily" then
        local nrows = section.days or 4
        if nrows < 1 then
            nrows = 1
        end
        local block = DailyBlock:new{ tr = self.tr, width = width, height = height, nrows = nrows }
        self._appliers[#self._appliers + 1] = function()
            local items = self.data:forecast(section.weather, "daily")
            if not items then
                block.missing = true
                return
            end
            block.missing = false
            local wstate = self.data:state(section.weather)
            local wattrs = type(wstate) == "table" and wstate.attributes or {}
            local rows = model.daily_rows(items, {
                now = os.time(),
                utc_offset_min = offset,
                days = days,
                tr = self.tr,
                wind_unit = wattrs.wind_speed_unit,
            })
            block.rows_data = {}
            for i = 1, block.nrows do
                local row = rows[i]
                if row then
                    local precip = fmt_mm(row.precip, sep)
                    local glyph = icons.condition(row.condition_code, { daily = true })
                    local fallback
                    if not glyph and row.condition and row.condition ~= "—" then
                        fallback = row.condition
                    end
                    block.rows_data[i] = {
                        label = row.label,
                        glyph = glyph,
                        condition = fallback,
                        high = type(row.high) == "number" and fmt_temp(row.high, sep) or nil,
                        low = type(row.low) == "number" and fmt_temp(row.low, sep) or nil,
                        feels = type(row.feels) == "number" and fmt_temp(row.feels, sep) or nil,
                        precip = precip,
                    }
                end
            end
        end
        return block
    end
    if kind == "values" then
        local items = section.items or {}
        local block = ValuesBlock:new{
            width = width,
            height = height,
            cols = section.columns or 2,
            items = items,
        }
        self._appliers[#self._appliers + 1] = function()
            for i, item in ipairs(items) do
                local cell = block.cells[i]
                if cell then
                    cell.value:setText(model.format_value(self.data:state(item.entity), item, sep))
                end
            end
        end
        return block
    end
    if kind == "buttons" then
        local items = section.items or {}
        local row = ButtonRow:new{
            width = width,
            height = height,
            cols = section.columns or 2,
            items = items,
            on_press = function(button)
                self:runButton(button.id, false)
            end,
        }
        for i = 1, #row.buttons do
            self._buttons[#self._buttons + 1] = row.buttons[i]
        end
        self._appliers[#self._appliers + 1] = function()
            for i, button in ipairs(row.buttons) do
                local item = button.item
                local text, inverted, icon_name = nil, false, item.icon
                if item.state then
                    local state_obj = self.data:state(item.state.entity)
                    if state_obj then
                        local view = model.button_view(state_obj.state, item.state.map, item.icon)
                        text = view and view.text or "?"
                        inverted = view and view.style == "inverted"
                        icon_name = view and view.icon or item.icon
                    else
                        text = "—"
                    end
                end
                button.inverted = inverted and true or false
                button.state_text = text
                button.icon_name = icon_name
            end
        end
        return row
    end
    if kind == "footer" then
        local minutes = self.config.refresh.states_min or 5
        local footer = Footer:new{
            width = width,
            height = height,
            hint_text = self.tr.t("every_min", minutes),
        }
        self._appliers[#self._appliers + 1] = function()
            footer.status:setText(model.footer_line(self.data.last_error, self.data.last_ok, offset, self.tr))
        end
        return footer
    end
    return VerticalSpan:new{ width = height }
end

function Dashboard:_buildDashboard()
    local screen = Screen:getSize()
    local pad = sbs(6)
    local gap = sbs(3)
    local sections = self.config.sections
    local n = #sections
    local budget = screen.h - 2 * pad - gap * math.max(0, n - 1)
    if budget < n then
        budget = n
    end
    local daily_rows_n = 4
    for _, sec in ipairs(sections) do
        if sec.type == "daily" then
            daily_rows_n = math.max(1, sec.days or 4)
        end
    end
    local mins = {
        header = sbs(44),
        weather_now = sbs(100),
        chart = sbs(230),
        daily = sbs(30) * daily_rows_n,
        values = sbs(56),
        buttons = sbs(100),
        footer = sbs(22),
    }
    local weights = {
        header = 0.5,
        weather_now = 1,
        chart = 4,
        daily = 2,
        values = 0.5,
        buttons = 1.5,
        footer = 0,
    }
    local order, min_of, weight_of = {}, {}, {}
    for i, section in ipairs(sections) do
        order[i] = i
        min_of[i] = mins[section.type] or sbs(24)
        weight_of[i] = weights[section.type] or 1
    end
    local heights = distribute(budget, order, min_of, weight_of)
    local inner_w = screen.w - 2 * pad
    self._appliers = {}
    self._buttons = {}
    local children = { align = "left", allow_mirroring = false }
    for i, section in ipairs(sections) do
        if i > 1 then
            -- VerticalSpan.width is the reserved height.
            children[#children + 1] = VerticalSpan:new{ width = gap }
        end
        children[#children + 1] = self:_sectionWidget(section, inner_w, heights[i])
    end
    self[1] = FrameContainer:new{
        width = screen.w,
        height = screen.h,
        background = WHITE,
        bordersize = 0,
        padding = pad,
        margin = 0,
        allow_mirroring = false,
        VerticalGroup:new(children),
    }
end

function Dashboard:applyData()
    if not self._appliers then
        return
    end
    for i = 1, #self._appliers do
        self._appliers[i]()
    end
end

function Dashboard:init()
    self:_setupWindow()
    self._appliers = {}
    self._buttons = {}
    local cfg, info, tr = load_config()
    self.tr = tr or i18n.new(cfg and cfg.locale)
    if not cfg then
        logger.warn("[homedash]", "config", info)
        self:_buildMessage(info)
        return
    end
    self.config = cfg
    logger.info("[homedash]", "config", info)
    self.client = HA:new{
        url = cfg.ha.url,
        token = cfg.ha.token,
        timeout = cfg.ha.timeout,
    }
    self.data = Data:new{
        config = cfg,
        client = self.client,
    }
    self.data:refresh(os.time(), "all")
    local err = self.data.last_error
    if err then
        logger.warn("[homedash]", "fetch", err.kind, err.code, err.message)
    end
    self:_buildDashboard()
    self:applyData()
end

function Dashboard:_unschedule()
    if self._refresh_task then
        UIManager:unschedule(self._refresh_task)
    end
    if self._resume_task then
        UIManager:unschedule(self._resume_task)
    end
    if self._shot_task then
        UIManager:unschedule(self._shot_task)
    end
    if self._action_task then
        UIManager:unschedule(self._action_task)
    end
    if self._post_action_task then
        UIManager:unschedule(self._post_action_task)
    end
end

-- Battery and Wi-Fi for the header. Cheap calls only, each guarded: a missing
-- API (emulator, other device) simply leaves that piece out.
function Dashboard:_deviceStatus()
    local st = {}
    local ok, power = pcall(function() return Device:getPowerDevice() end)
    if ok and power then
        local ok_c, cap = pcall(function() return power:getCapacity() end)
        if ok_c and type(cap) == "number" then
            st.battery = math.max(0, math.min(100, math.floor(cap + 0.5)))
            local ok_ch, ch = pcall(function() return power:isCharging() end)
            st.charging = ok_ch and ch and true or false
        end
    end
    local ok_n, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_n and NetworkMgr then
        local ok_w, on = pcall(function() return NetworkMgr:isWifiOn() end)
        if ok_w and on ~= nil then
            local ok_c, conn = pcall(function() return NetworkMgr:isConnected() end)
            st.wifi = (on and (not ok_c or conn ~= false)) and true or false
        end
    end
    return st
end

function Dashboard:_repaint(button, force_full)
    if button and button.dimen then
        UIManager:setDirty(self, function()
            return "ui", button.dimen
        end)
        return
    end
    if force_full then
        self._partials = 0
        UIManager:setDirty(self, "full")
        return
    end
    self._partials = (self._partials or 0) + 1
    local every = (self.config and self.config.refresh and self.config.refresh.full_every) or 6
    local mode = "ui"
    if every > 0 and self._partials >= every then
        mode = "full"
        self._partials = 0
        logger.info("[homedash]", "full refresh")
    end
    UIManager:setDirty(self, mode)
end

function Dashboard:refreshNow()
    if not self.data or self._busy or self.closed then
        return
    end
    -- "all" ignores the due times: every state and every forecast is fetched now.
    self.data:refresh(os.time(), model.REFRESH_NOW)
    self:applyData()
    self:_repaint(nil, true)
end

--- Device woke from suspend: refresh everything after a short wait for Wi-Fi.
function Dashboard:onResume()
    if not self.data or self.closed then
        return
    end
    if self._resume_task then
        UIManager:unschedule(self._resume_task)
    end
    self._resume_task = function()
        self._resume_task = nil
        if self.closed or not UIManager:isWidgetShown(self) then
            return
        end
        self:refreshNow()
    end
    UIManager:scheduleIn(model.RESUME_DELAY_S, self._resume_task)
end

function Dashboard:_findButton(id)
    local buttons = self._buttons or {}
    for i = 1, #buttons do
        if buttons[i].id == id then
            return buttons[i]
        end
    end
    return nil
end

function Dashboard:_actionFor(button)
    local item = button.item
    local value
    if item.state and item.state.entity then
        local state_obj = self.data:state(item.state.entity)
        value = state_obj and state_obj.state or nil
    end
    return model.resolve_action(value, item.action)
end

function Dashboard:_notify(text)
    UIManager:show(Notification:new{
        text = text,
        timeout = 2,
    })
end

function Dashboard:_shortError(err)
    if type(err) ~= "table" then
        return self.tr.t("error")
    end
    if err.code then
        return self.tr.t("error_code", tostring(err.code))
    end
    if err.kind == "network" then
        return self.tr.t("offline")
    end
    return self.tr.t("error")
end

function Dashboard:_callAction(button, action)
    if self.closed or self._busy then
        return
    end
    self._busy = true
    logger.info("[homedash]", "action", action.service)
    local result, err = self.client:call_service(action.service, action.data or {})
    self._busy = false
    if self.closed then
        return
    end
    if result then
        self:_notify(self.tr.t("sent"))
    else
        if type(err) == "table" then
            err.at = os.time()
            self.data.last_error = err
        end
        self:applyData()
        self:_repaint(nil)
        self:_notify(self:_shortError(err))
        logger.warn("[homedash]", "action failed", err and err.kind, err and err.code, err and err.message)
    end
    local delay = (self.config.refresh and self.config.refresh.after_action_s) or 5
    if self._post_action_task then
        UIManager:unschedule(self._post_action_task)
    end
    self._post_action_task = function()
        if self.closed or not UIManager:isWidgetShown(self) then
            return
        end
        self.data:refresh(os.time(), "states")
        self:applyData()
        self:_repaint(button)
    end
    UIManager:scheduleIn(delay, self._post_action_task)
end

function Dashboard:runButton(id, skip_confirm)
    if not self.client or self.closed then
        return
    end
    local button = self:_findButton(id)
    if not button then
        logger.warn("[homedash]", "no button", id)
        return
    end
    if not hd_util.actions_enabled(os.getenv("HOMEDASH_ACTIONS")) then
        logger.info("[homedash]", "actions off, not calling HA for", id)
        self:_notify(self.tr.t("actions_off"))
        return
    end
    local action = self:_actionFor(button)
    if not action then
        self:_notify(self.tr.t("no_action"))
        return
    end
    local function go()
        self:_callAction(button, action)
    end
    if skip_confirm or type(action.confirm) ~= "string" or action.confirm == "" then
        go()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = action.confirm,
        ok_callback = go,
    })
end

function Dashboard:onShow()
    logger.info("[homedash]", "opened", self.screen_line)
    if self._hooks_done then
        return
    end
    self._hooks_done = true
    local shot = os.getenv("HOMEDASH_SCREENSHOT")
    local auto = os.getenv("HOMEDASH_AUTOACTION")
    local after_s = 5
    if self.config and self.config.refresh and self.config.refresh.after_action_s then
        after_s = self.config.refresh.after_action_s
    end
    if auto and auto ~= "" and not hd_util.actions_enabled(os.getenv("HOMEDASH_ACTIONS")) then
        logger.warn("[homedash]", "HOMEDASH_AUTOACTION ignored: HOMEDASH_ACTIONS=off")
        auto = nil
    end
    if auto and auto ~= "" and self.client then
        self._action_task = function()
            if self.closed then
                return
            end
            self:runButton(auto, true)
        end
        UIManager:scheduleIn(1, self._action_task)
    end
    if shot and shot ~= "" then
        local delay = 2
        if auto and auto ~= "" then
            delay = 1 + after_s + 2
        end
        self._shot_task = function()
            if UIManager:isWidgetShown(self) then
                saveScreenshot(shot)
            else
                logger.warn("[homedash]", "screenshot skipped, dashboard closed")
            end
            if os.getenv("HOMEDASH_EXIT_AFTER_SHOT") == "1" then
                logger.info("[homedash]", "quitting")
                UIManager:quit()
            end
        end
        UIManager:scheduleIn(delay, self._shot_task)
    end
    if self.config and self.data then
        local every = (self.config.refresh.states_min or 5) * 60
        self._refresh_task = function()
            if self.closed or not UIManager:isWidgetShown(self) then
                return
            end
            self.data:refresh(os.time(), "due")
            self:applyData()
            self:_repaint(nil)
            UIManager:scheduleIn(every, self._refresh_task)
        end
        UIManager:scheduleIn(every, self._refresh_task)
    end
end

function Dashboard:onTap()
    return true
end

function Dashboard:onSwipe(_, ges)
    if ges.direction == "south" then
        self:onClose()
        return true
    end
    return false
end

function Dashboard:onClose()
    if self.closed then
        return true
    end
    self.closed = true
    self:_unschedule()
    logger.info("[homedash]", "closed")
    if self.on_closed then
        self.on_closed()
    end
    UIManager:close(self, "partial")
    return true
end

function Dashboard:onCloseWidget()
    self:free()
end

return Dashboard
