--[[--
Home Assistant REST client.

`HA:new{ url, token, timeout, http = optional transport }`

The transport is `function(request) -> status, body, headers`.
`status` is the HTTP code, or nil with `body` holding the network error.
When `http` is omitted the client uses `socket.http`, `ltn12` and `socketutil`.

Each call returns `result` or `nil, err` with
`err = { kind = "network"|"auth"|"http"|"json", code = status|nil, message = ... }`.
A service-call timeout returns `{ timeout = true }` instead: the script may
have started (see docs/ha-api.md).
]]

local HA = {}
HA.__index = HA

local json_lib

local function load_json()
    if json_lib then
        return json_lib
    end
    local names = { "rapidjson", "json", "dkjson" }
    for i = 1, #names do
        local ok, lib = pcall(require, names[i])
        if ok and type(lib) == "table"
            and type(lib.decode) == "function"
            and type(lib.encode) == "function" then
            json_lib = lib
            return lib
        end
    end
    error("homedash: JSON library not found (rapidjson, json, dkjson)")
end

local function scrub(value, depth)
    if type(value) ~= "table" or depth > 8 then
        return
    end
    for key, item in pairs(value) do
        local kind = type(item)
        -- dkjson uses a function for null; rapidjson uses userdata.
        if kind == "function" or kind == "userdata" then
            value[key] = nil
        elseif kind == "table" then
            scrub(item, depth + 1)
        end
    end
end

local function decode_json(str)
    local lib = load_json()
    local ok, a, b, c = pcall(lib.decode, str)
    if not ok then
        return nil, tostring(a)
    end
    if type(a) == "table" then
        scrub(a, 0)
        return a
    end
    if a == nil then
        local err = c or b
        if type(err) == "string" and err ~= "" then
            return nil, err
        end
        return nil, "empty JSON"
    end
    return nil, "JSON value is not an object"
end

local function encode_json(value)
    local lib = load_json()
    local ok, encoded, err = pcall(lib.encode, value)
    if not ok then
        return nil, tostring(encoded)
    end
    if type(encoded) ~= "string" then
        return nil, tostring(err or "JSON encode failed")
    end
    return encoded
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function interpret(status, body)
    body = body or ""
    if status == 401 then
        local message = trim(body)
        if message == "" then
            message = "401"
        end
        return nil, { kind = "auth", code = 401, message = message }
    end
    if status < 200 or status >= 300 then
        local message = trim(body)
        if message:sub(1, 1) == "{" then
            local decoded = decode_json(message)
            if type(decoded) == "table" and type(decoded.message) == "string" then
                message = decoded.message
            end
        end
        if message == "" then
            message = "HTTP " .. tostring(status)
        end
        return nil, { kind = "http", code = status, message = message }
    end
    if body == "" then
        return {}
    end
    local decoded, err = decode_json(body)
    if type(decoded) ~= "table" then
        return nil, { kind = "json", code = status, message = err or "invalid JSON" }
    end
    return decoded
end

local function is_timeout_message(message)
    local text = tostring(message or ""):lower()
    return text:find("timeout", 1, true) ~= nil
        or text:find("wantread", 1, true) ~= nil
        or text:find("wantwrite", 1, true) ~= nil
end

local function default_exchange(req, timeout_s)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local sink = {}
    local block = timeout_s or 5
    if block < 1 then
        block = 1
    end
    socketutil:set_timeout(block, block)
    local headers = {}
    if req.headers then
        for key, value in pairs(req.headers) do
            headers[key] = value
        end
    end
    local source
    if req.body then
        source = ltn12.source.string(req.body)
        headers["content-length"] = tostring(#req.body)
        if not headers["content-type"] then
            headers["content-type"] = "application/json"
        end
    end
    local request = {
        url = req.url,
        method = req.method or "GET",
        headers = headers,
        source = source,
        sink = socketutil.table_sink(sink),
        redirect = false,
    }
    local ok, first, second, third, fourth = pcall(http.request, request)
    socketutil:reset_timeout()
    if not ok then
        return nil, tostring(first)
    end
    -- Success: 1, code, headers, status. Failure: nil, err.
    if first == nil then
        return nil, tostring(second or "offline")
    end
    return second, table.concat(sink), third, fourth
end

function HA:new(opts)
    opts = opts or {}
    local url = tostring(opts.url or ""):gsub("/+$", "")
    local o = {
        url = url,
        token = opts.token or "",
        timeout = opts.timeout or 5,
        http = opts.http,
    }
    return setmetatable(o, self)
end

function HA:_exchange(req)
    if self.http then
        return self.http(req)
    end
    return default_exchange(req, self.timeout)
end

function HA:_request(method, path, body, query)
    if self.url == "" then
        return nil, { kind = "network", message = "ha.url is empty" }
    end
    local payload
    if body ~= nil then
        local encoded, err = encode_json(body)
        if not encoded then
            return nil, { kind = "json", message = err or "JSON encode failed" }
        end
        payload = encoded
    end
    local url = self.url .. path
    if query and query ~= "" then
        url = url .. "?" .. query
    end
    local headers = {
        ["authorization"] = "Bearer " .. self.token,
    }
    if payload then
        headers["content-type"] = "application/json"
    end
    local status, resp_body, resp_headers = self:_exchange({
        method = method,
        url = url,
        path = path,
        headers = headers,
        body = payload,
        timeout = self.timeout,
    })
    if type(status) ~= "number" then
        return nil, {
            kind = "network",
            message = tostring(resp_body or status or "offline"),
        }
    end
    return interpret(status, resp_body, resp_headers)
end

function HA:_timeout(err)
    return type(err) == "table" and err.kind == "network" and is_timeout_message(err.message)
end

--- One entity. `state` is always a string on success.
function HA:get_state(entity_id)
    local path = "/api/states/" .. tostring(entity_id):gsub(
        "[^%w%-_%.~]",
        function(char)
            return string.format("%%%02X", string.byte(char))
        end)
    return self:_request("GET", path)
end

--- Forecast rows for one weather entity. `kind` is `"hourly"` or `"daily"`.
-- `?return_response` is sent only here.
function HA:get_forecast(weather_id, kind)
    local result, err = self:_request("POST", "/api/services/weather/get_forecasts", {
        entity_id = weather_id,
        type = kind,
    }, "return_response")
    if not result then
        return nil, err
    end
    local response = result.service_response
    local entry = type(response) == "table" and response[weather_id] or nil
    local forecast = type(entry) == "table" and entry.forecast or nil
    if type(forecast) ~= "table" then
        return nil, { kind = "json", code = 200, message = "brak prognozy" }
    end
    return forecast
end

--- `domain.service` plus a JSON object. No `return_response` query.
function HA:call_service(service, data)
    local domain, name = tostring(service or ""):match("^([%w_]+)%.([%w_]+)$")
    if not domain then
        return nil, { kind = "http", message = "bad service" }
    end
    local result, err = self:_request(
        "POST",
        "/api/services/" .. domain .. "/" .. name,
        data or {})
    if self:_timeout(err) then
        return { timeout = true }
    end
    return result, err
end

return HA
