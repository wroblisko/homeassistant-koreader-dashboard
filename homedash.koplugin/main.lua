--[[--
Home Assistant dashboard plugin.

@module koplugin.homedash
--]]--

local Dashboard = require("homedash_view")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Set on the first UI that can show the dashboard, so opening a book
-- (which constructs a second plugin instance) does not open it again.
local autoopen_done = false

local HomeDash = WidgetContainer:extend{
    name = "homedash",
    is_doc_only = false,
}

function HomeDash:onDispatcherRegisterActions()
    Dispatcher:registerAction("homedash_show", {
        category = "none",
        event = "ShowHomeDash",
        title = _("Home Assistant dashboard"),
        general = true,
    })
end

function HomeDash:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:scheduleAutoOpen()
end

function HomeDash:addToMainMenu(menu_items)
    menu_items.homedash = {
        text = _("Home Assistant dashboard"),
        sorting_hint = "more_tools",
        callback = function()
            self:showDashboard()
        end,
    }
end

function HomeDash:scheduleAutoOpen()
    if autoopen_done or os.getenv("HOMEDASH_AUTOOPEN") ~= "1" then
        return
    end
    -- FileManager is the usual shell. ReaderUI is the shell when KOReader
    -- starts straight into a document (first-run quickstart). Plugin init
    -- runs before FileManager:setupLayout, so `ui.file_chooser` does not
    -- exist yet; the instance metatable is the reliable check. ReaderUI
    -- already has `document` at this point. Schedule once per process.
    local FileManager = require("apps/filemanager/filemanager")
    local in_filemanager = getmetatable(self.ui) == FileManager
    local in_reader = self.ui.document ~= nil
    if not (in_filemanager or in_reader) then
        return
    end
    autoopen_done = true
    logger.info("[homedash]", "auto-open in 1s")
    UIManager:scheduleIn(1, function()
        self:showDashboard()
    end)
end

function HomeDash:showDashboard()
    if self.dashboard and UIManager:isWidgetShown(self.dashboard) then
        return
    end
    self.dashboard = Dashboard:new{
        on_closed = function()
            self.dashboard = nil
        end,
    }
    UIManager:show(self.dashboard, "partial")
end

function HomeDash:onShowHomeDash()
    self:showDashboard()
    return true
end

return HomeDash
