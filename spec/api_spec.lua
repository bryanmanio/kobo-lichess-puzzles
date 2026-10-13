-- api.lua request shaping and error mapping, with an injected transport.
-- No network and no KOReader modules are touched.
-- Run with: luajit spec/api_spec.lua

package.path = "lichesspuzzles.koplugin/?.lua;" .. package.path
local API = require("api")

local failures, checks = 0, 0
local function check(ok, msg)
    checks = checks + 1
    if not ok then failures = failures + 1; print("FAIL " .. msg) end
    return ok
end

-- Minimal ltn12 stand-in: enough for a table sink and a string source.
local fake_ltn12 = {
    sink = { table = function(t)
        return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
    end },
    source = { string = function(s) return function() return s end end },
}

-- Builds a client whose transport replays canned responses and records requests.
-- Each response: { status = 200, body = "...", decoded = {...} } or { fail = "..." }.
local function client(responses, opts)
    local state = { calls = {}, encoded = {}, decoded = nil }
    local fake_http = { request = function(req)
        state.calls[#state.calls + 1] = req
        local r = table.remove(responses, 1) or { status = 200, body = "{}", decoded = {} }
        if r.fail then return nil, r.fail end
        state.decoded = r.decoded
        if req.sink and r.body then req.sink(r.body) end
        return 1, r.status
    end }
    local fake_json = {
        encode = function(t) state.encoded[#state.encoded + 1] = t; return '{"stub":1}' end,
        decode = function() 
            if state.decoded == nil then error("bad json") end
            return state.decoded
        end,
    }
    opts = opts or {}
    local o = { http = fake_http, json = fake_json, ltn12 = fake_ltn12 }
    for k, v in pairs(opts) do o[k] = v end
    -- Assigning nil cannot clear a key in Lua, so anonymity needs an explicit flag.
    if not opts.anonymous then o.token = o.token or "TOK" end
    return API.new(o), state
end

-- 1. Batch fetch: URL, query parameters and auth header.
do
    local api, state = client({ { status = 200, body = "x",
        decoded = { puzzles = { { puzzle = { id = "abc" } } } } } })
    local puzzles, err = api:getBatch(25, "harder")
    check(puzzles ~= nil, "getBatch returned an error: " .. tostring(err and err.message))
    check(puzzles and #puzzles == 1, "getBatch should unwrap the puzzles array")
    local req = state.calls[1]
    check(req.method == "GET", "batch fetch should be a GET")
    check(req.url == "https://lichess.org/api/puzzle/batch/mix?nb=25&difficulty=harder",
        "unexpected batch URL: " .. tostring(req.url))
    check(req.headers["Authorization"] == "Bearer TOK", "missing bearer token")
end

-- A nil difficulty must be omitted rather than sent empty.
do
    local api, state = client({ { status = 200, body = "x", decoded = { puzzles = {} } } })
    api:getBatch(10, nil)
    check(state.calls[1].url == "https://lichess.org/api/puzzle/batch/mix?nb=10",
        "nil difficulty should be omitted: " .. tostring(state.calls[1].url))
end

-- Anonymous clients must not send an Authorization header.
do
    local api, state = client({ { status = 200, body = "x", decoded = { puzzles = {} } } },
        { anonymous = true })
    check(api:hasToken() == false, "hasToken should be false without a token")
    api:getBatch(1)
    check(state.calls[1].headers["Authorization"] == nil,
        "anonymous request must not send Authorization")
end

-- 2. Solve: method, body shape, refill parameter and JSON headers.
do
    local api, state = client({ { status = 200, body = "x", decoded = {
        rounds = { { id = "abc", win = true, ratingDiff = 12 } },
        puzzles = { {}, {} },
        glicko = { rating = 1536 },
    } } })
    local solutions = { { id = "abc", win = true, rated = true } }
    local res, err = api:solve(solutions, 5)
    check(res ~= nil, "solve returned an error: " .. tostring(err and err.message))
    local req = state.calls[1]
    check(req.method == "POST", "solve should be a POST")
    check(req.url == "https://lichess.org/api/puzzle/batch/mix?nb=5",
        "unexpected solve URL: " .. tostring(req.url))
    check(req.headers["Content-Type"] == "application/json", "solve needs a JSON content type")
    check(req.headers["Content-Length"] == tostring(#'{"stub":1}'),
        "solve must set Content-Length so luasocket does not use chunked encoding")
    check(state.encoded[1] and state.encoded[1].solutions == solutions,
        "solve body should be wrapped as { solutions = ... }")
    check(res and res.glicko.rating == 1536, "solve should surface the new rating")
    check(API.ratingDiffFor(res.rounds, "abc") == 12, "ratingDiffFor should find the delta")
    check(API.ratingDiffFor(res.rounds, "nope") == nil, "ratingDiffFor should return nil if absent")
end

-- 3. HTTP status mapping, so the UI can explain what went wrong.
local STATUS_CASES = {
    { 401, "auth" }, { 403, "forbidden" }, { 429, "ratelimit" },
    { 500, "http" }, { 404, "http" },
}
for _, case in ipairs(STATUS_CASES) do
    local api = client({ { status = case[1], body = "", decoded = {} } })
    local res, err = api:getBatch(1)
    check(res == nil, string.format("HTTP %d should be an error", case[1]))
    check(err and err.code == case[2],
        string.format("HTTP %d -> %s, want %s", case[1], tostring(err and err.code), case[2]))
end

-- 4. Transport failure and undecodable payloads.
do
    local api = client({ { fail = "host not found" } })
    local res, err = api:getBatch(1)
    check(res == nil and err.code == "network",
        "transport failure should map to a network error")
    check(err.message == "host not found", "network error should carry the reason")
end
do
    local api = client({ { status = 200, body = "not json", decoded = nil } })
    local res, err = api:getBatch(1)
    check(res == nil and err.code == "json", "undecodable body should map to a json error")
end

-- 5. The token creation URL must carry both scopes the plugin relies on.
check(API.TOKEN_URL:find("puzzle:read", 1, true) ~= nil, "token URL needs puzzle:read")
check(API.TOKEN_URL:find("puzzle:write", 1, true) ~= nil, "token URL needs puzzle:write")

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
