local HA = require("homedash_ha")

local function read_file(path)
    local handle = assert(io.open(path, "rb"), path)
    local text = handle:read("*a")
    handle:close()
    return text
end

local function contains(hay, needle)
    assert.is_true(tostring(hay):find(needle, 1, true) ~= nil,
        string.format("missing %q in %s", needle, tostring(hay)))
end

describe("homedash_ha", function()
    local state_body = read_file("spec/fixtures/ha/states/sensor.prologue_th_5_1_142_temperature.json")
    local hourly_body = read_file("spec/fixtures/ha/forecast_hourly.json")
    local daily_body = read_file("spec/fixtures/ha/forecast_daily.json")
    local unauthorized = read_file("spec/fixtures/ha/raw/unauthorized.body")
    local not_found = read_file("spec/fixtures/ha/raw/state_not_found.body")
    local twice_daily = read_file("spec/fixtures/ha/raw/forecast_twice_daily.body")
    local service_ok = read_file("spec/fixtures/ha/raw/service_ok_no_changes.body")

    local function client(handler)
        local requests = {}
        local ha = HA:new{
            url = "http://127.0.0.1:18123",
            token = "mock-token",
            timeout = 5,
            http = function(req)
                requests[#requests + 1] = req
                return handler(req)
            end,
        }
        return ha, requests
    end

    it("parses a state fixture and sends the bearer token", function()
        local ha, requests = client(function()
            return 200, state_body, {}
        end)
        local result, err = ha:get_state("sensor.prologue_th_5_1_142_temperature")
        assert.are.equal(nil, err)
        assert.are.equal("string", type(result.state))
        assert.are.equal("9.2", result.state)
        assert.are.equal("°C", result.attributes.unit_of_measurement)
        local req = requests[1]
        assert.are.equal("GET", req.method)
        contains(req.url, "/api/states/sensor.prologue_th_5_1_142_temperature")
        assert.are.equal("Bearer mock-token", req.headers.authorization)
    end)

    it("asks for a forecast response and returns the hourly rows", function()
        local ha, requests = client(function()
            return 200, hourly_body, {}
        end)
        local result, err = ha:get_forecast("weather.forecast_dom", "hourly")
        assert.are.equal(nil, err)
        assert.are.equal(48, #result)
        assert.are.equal("2026-11-19T16:00:00+00:00", result[1].datetime)
        local req = requests[1]
        assert.are.equal("POST", req.method)
        contains(req.url, "/api/services/weather/get_forecasts?return_response")
        contains(req.body, "hourly")
        contains(req.body, "weather.forecast_dom")
        assert.are.equal("Bearer mock-token", req.headers.authorization)
    end)

    it("returns the six daily rows", function()
        local ha = client(function()
            return 200, daily_body, {}
        end)
        local result, err = ha:get_forecast("weather.forecast_dom", "daily")
        assert.are.equal(nil, err)
        assert.are.equal(6, #result)
        assert.are.equal("2026-11-19T11:00:00+00:00", result[1].datetime)
    end)

    it("calls a service without return_response", function()
        local ha, requests = client(function()
            return 200, service_ok, {}
        end)
        local result, err = ha:call_service("script.turn_on", {
            entity_id = "script.otworz_garaz",
        })
        assert.are.equal(nil, err)
        assert.are.equal("table", type(result))
        local req = requests[1]
        assert.are.equal("POST", req.method)
        contains(req.url, "/api/services/script/turn_on")
        assert.is_true(req.url:find("return_response", 1, true) == nil)
        contains(req.body, "script.otworz_garaz")
    end)

    it("maps a 401 text body to auth", function()
        local ha = client(function()
            return 401, unauthorized, {}
        end)
        local result, err = ha:get_state("weather.forecast_dom")
        assert.are.equal(nil, result)
        assert.are.equal("auth", err.kind)
        assert.are.equal(401, err.code)
        contains(err.message, "Unauthorized")
    end)

    it("maps a 404 JSON body to http", function()
        local ha = client(function()
            return 404, not_found, {}
        end)
        local result, err = ha:get_state("sensor.missing")
        assert.are.equal(nil, result)
        assert.are.equal("http", err.kind)
        assert.are.equal(404, err.code)
        assert.are.equal("Entity not found.", err.message)
    end)

    it("maps a 500 JSON message", function()
        local ha = client(function()
            return 500, twice_daily, {}
        end)
        local result, err = ha:get_forecast("weather.forecast_dom", "twice_daily")
        assert.are.equal(nil, result)
        assert.are.equal("http", err.kind)
        assert.are.equal(500, err.code)
        contains(err.message, "does not support")
    end)

    it("maps a network failure", function()
        local ha = client(function()
            return nil, "connection refused"
        end)
        local result, err = ha:get_state("weather.forecast_dom")
        assert.are.equal(nil, result)
        assert.are.equal("network", err.kind)
        contains(err.message, "connection refused")
    end)

    it("maps invalid JSON", function()
        local ha = client(function()
            return 200, "{not json", {}
        end)
        local result, err = ha:get_state("weather.forecast_dom")
        assert.are.equal(nil, result)
        assert.are.equal("json", err.kind)
        assert.are.equal(200, err.code)
    end)

    it("treats a service timeout as maybe-done and a state timeout as network", function()
        local ha = client(function()
            return nil, "timeout"
        end)
        local result, err = ha:call_service("script.turn_on", {
            entity_id = "script.otworz_garaz",
        })
        assert.are.equal(nil, err)
        assert.is_true(result.timeout)
        local state, state_err = ha:get_state("binary_sensor.brama_garazowa")
        assert.are.equal(nil, state)
        assert.are.equal("network", state_err.kind)
    end)
end)
