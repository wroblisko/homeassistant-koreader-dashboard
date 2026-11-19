--[[--
Which entities to fetch, and when. Keeps the last good state and forecast.

Synchronous: each refresh blocks on the client. No KOReader modules.
]]

local Data = {}
Data.__index = Data

local function add_id(list, seen, entity_id)
    if type(entity_id) == "string" and entity_id ~= "" and not seen[entity_id] then
        seen[entity_id] = true
        list[#list + 1] = entity_id
    end
end

--- Entity ids the card displays, in section order, without duplicates.
-- Action targets are not included; the button reads `state.entity`.
function Data.entity_ids(config)
    local list, seen = {}, {}
    local sections = type(config) == "table" and config.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            if section.type == "weather_now" then
                add_id(list, seen, section.weather)
                add_id(list, seen, section.temperature)
            elseif section.type == "chart" then
                -- Optional sun entity: night shading in the chart.
                add_id(list, seen, section.sun)
            elseif section.type == "values" then
                for _, item in ipairs(section.items or {}) do
                    if type(item) == "table" then
                        add_id(list, seen, item.entity)
                    end
                end
            elseif section.type == "buttons" then
                for _, item in ipairs(section.items or {}) do
                    if type(item) == "table" and type(item.state) == "table" then
                        add_id(list, seen, item.state.entity)
                    end
                end
            end
        end
    end
    return list
end

--- `{ entity_id, kind }` for chart (hourly) and daily sections.
function Data.forecast_queries(config)
    local list, seen = {}, {}
    local sections = type(config) == "table" and config.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            local kind
            if section.type == "chart" then
                kind = "hourly"
            elseif section.type == "daily" then
                kind = "daily"
            end
            if kind and type(section.weather) == "string" and section.weather ~= "" then
                local key = section.weather .. "\0" .. kind
                if not seen[key] then
                    seen[key] = true
                    list[#list + 1] = { entity_id = section.weather, kind = kind }
                end
            end
        end
    end
    -- weather_now shows today's max and min, which live on the daily forecast.
    -- Reuse a daily query the daily section already asked for.
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "weather_now"
            and type(section.weather) == "string" and section.weather ~= "" then
            local key = section.weather .. "\0daily"
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = { entity_id = section.weather, kind = "daily" }
            end
        end
    end
    return list
end

function Data:new(opts)
    opts = opts or {}
    local o = {
        config = opts.config or {},
        client = opts.client,
        states = {},
        forecasts = {},
        last_error = nil,
        last_ok = nil,
        _states_at = nil,
        _forecast_at = {},
    }
    return setmetatable(o, self)
end

function Data:state(entity_id)
    return self.states[entity_id]
end

function Data:forecast(entity_id, kind)
    local slot = self.forecasts[entity_id]
    local entry = slot and slot[kind]
    return entry and entry.items or nil
end

local function as_error(err)
    if type(err) == "table" then
        return err
    end
    return { kind = "network", message = tostring(err or "error") }
end

--- `mode` is `"all"`, `"states"`, `"forecasts"` or `"due"` (the default).
-- `"due"` honours `refresh.states_min` and `refresh.forecast_min`.
-- A failed entity keeps its previous value. The last error is kept until a
-- later refresh completes with no errors.
function Data:refresh(now, mode)
    mode = mode or "due"
    now = now or os.time()
    local refresh = self.config.refresh or {}
    local states_every = (refresh.states_min or 5) * 60
    local forecast_every = (refresh.forecast_min or 30) * 60
    local force_states = mode == "all" or mode == "states"
    local force_forecasts = mode == "all" or mode == "forecasts"
    local do_states = force_states or (
        mode == "due" and (self._states_at == nil or now - self._states_at >= states_every))
    local any_ok = false
    local any_err = nil
    local attempted = false
    -- A network failure (refused, timeout) means HA is unreachable: skip the
    -- remaining requests instead of waiting for one timeout per entity.
    local unreachable = false

    if do_states then
        attempted = true
        self._states_at = now
        for _, entity_id in ipairs(Data.entity_ids(self.config)) do
            local state, err = self.client:get_state(entity_id)
            if state then
                self.states[entity_id] = state
                any_ok = true
            else
                any_err = as_error(err)
                if any_err.kind == "network" then
                    unreachable = true
                    break
                end
            end
        end
    end

    if force_forecasts or mode == "due" or mode == "all" then
        for _, query in ipairs(Data.forecast_queries(self.config)) do
            local key = query.entity_id .. "\0" .. query.kind
            local fetched_at = self._forecast_at[key]
            local due = fetched_at == nil or now - fetched_at >= forecast_every
            if unreachable then
                break
            end
            if force_forecasts or (mode == "due" and due) or (mode == "all") then
                attempted = true
                self._forecast_at[key] = now
                local items, err = self.client:get_forecast(query.entity_id, query.kind)
                if items then
                    local slot = self.forecasts[query.entity_id]
                    if not slot then
                        slot = {}
                        self.forecasts[query.entity_id] = slot
                    end
                    slot[query.kind] = { at = now, items = items }
                    any_ok = true
                else
                    any_err = as_error(err)
                    if any_err.kind == "network" then
                        unreachable = true
                    end
                end
            end
        end
    end

    if not attempted then
        return
    end
    if any_err then
        any_err.at = now
        self.last_error = any_err
    else
        self.last_error = nil
    end
    if any_ok then
        self.last_ok = now
    end
end

return Data
