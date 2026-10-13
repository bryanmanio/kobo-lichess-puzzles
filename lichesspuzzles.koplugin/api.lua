--[[--
Lichess puzzle API client.

Request shaping follows plugins/wallabag.koplugin/main.lua (callAPI): a table
request through socket.http with an ltn12 table sink, which handles HTTPS.

The http, json and ltn12 dependencies are injectable so the client can be unit
tested on a desktop without KOReader. They are required lazily, only when not
supplied, so requiring this module in a test never pulls in luasocket.

@module koplugin.lichesspuzzles.api
]]

local API = {}
API.__index = API

API.DEFAULT_BASE = "https://lichess.org"
-- The puzzle pool to draw from. "mix" is what lichess itself recommends.
API.DEFAULT_ANGLE = "mix"

-- Scopes the plugin needs: read to fetch puzzles, write to record results.
API.TOKEN_URL = "https://lichess.org/account/oauth/token/create"
    .. "?scopes[]=puzzle:read&scopes[]=puzzle:write&description=Kobo+Puzzles"

--- Creates a client.
-- @tparam table opts token, and optionally base, angle, http, json, ltn12,
--   socketutil, timeouts
function API.new(opts)
    opts = opts or {}
    local self = setmetatable({}, API)
    self.token = opts.token
    self.base = opts.base or API.DEFAULT_BASE
    self.angle = opts.angle or API.DEFAULT_ANGLE
    self.http = opts.http or require("socket.http")
    self.ltn12 = opts.ltn12 or require("ltn12")
    self.json = opts.json or require("json")
    -- Only present under KOReader; tests leave it nil.
    self.socketutil = opts.socketutil
    self.block_timeout = opts.block_timeout or 10
    self.total_timeout = opts.total_timeout or 30
    return self
end

function API:setToken(token)
    self.token = token
end

function API:hasToken()
    return self.token ~= nil and self.token ~= ""
end

local function urlEncode(str)
    return (string.gsub(tostring(str), "[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- Builds a query string from a table, skipping nil values.
local function buildQuery(params)
    local parts = {}
    for _, pair in ipairs(params) do
        if pair[2] ~= nil then
            parts[#parts + 1] = pair[1] .. "=" .. urlEncode(pair[2])
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

--- Performs a request and decodes the JSON response.
-- @string method "GET" or "POST"
-- @string path e.g. "/api/puzzle/next"
-- @tparam[opt] table body to be JSON encoded
-- @treturn table|nil decoded response, or nil plus an error table
--   { code = "network"|"auth"|"forbidden"|"ratelimit"|"http"|"json", message = ... }
function API:request(method, path, body)
    local sink_parts = {}
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = "kobo-lichess-puzzles",
    }
    if self:hasToken() then
        headers["Authorization"] = "Bearer " .. self.token
    end

    local request = {
        url = self.base .. path,
        method = method,
        headers = headers,
        sink = self.ltn12.sink.table(sink_parts),
    }

    if body ~= nil then
        local encoded = self.json.encode(body)
        headers["Content-Type"] = "application/json"
        -- Set the length explicitly; without it luasocket would use chunked
        -- transfer encoding, which the API does not accept.
        headers["Content-Length"] = tostring(#encoded)
        request.source = self.ltn12.source.string(encoded)
    end

    if self.socketutil then
        self.socketutil:set_timeout(self.block_timeout, self.total_timeout)
    end
    -- The table form returns 1, status, headers, status_line (or nil, error).
    local ok, status = self.http.request(request)
    if self.socketutil then
        self.socketutil:reset_timeout()
    end

    if not ok then
        return nil, { code = "network", message = tostring(status) }
    end

    status = tonumber(status) or 0
    if status == 401 then
        return nil, { code = "auth", status = status,
                      message = "Lichess rejected the token." }
    elseif status == 403 then
        return nil, { code = "forbidden", status = status,
                      message = "Token is missing a required scope." }
    elseif status == 429 then
        return nil, { code = "ratelimit", status = status,
                      message = "Rate limited by lichess. Wait a minute." }
    elseif status < 200 or status >= 300 then
        return nil, { code = "http", status = status,
                      message = "Lichess returned HTTP " .. tostring(status) }
    end

    local raw = table.concat(sink_parts)
    if raw == "" then return {} end

    local decode_ok, decoded = pcall(self.json.decode, raw)
    if not decode_ok or type(decoded) ~= "table" then
        return nil, { code = "json", message = "Could not parse the lichess response." }
    end
    return decoded
end

--- Fetches the authenticated account, used to verify the token and show a name.
-- @treturn table|nil account, or nil plus an error table
function API:getAccount()
    return self:request("GET", "/api/account")
end

--- Fetches a batch of puzzles.
-- When authenticated, lichess only returns puzzles the user has never seen.
-- @int nb how many puzzles (1-50)
-- @string difficulty one of easiest, easier, normal, harder, hardest
-- @treturn table|nil array of puzzle entries, or nil plus an error table
function API:getBatch(nb, difficulty)
    local query = buildQuery({ { "nb", nb or 10 }, { "difficulty", difficulty } })
    local res, err = self:request("GET", "/api/puzzle/batch/" .. self.angle .. query)
    if not res then return nil, err end
    return res.puzzles or {}
end

--- Submits solved puzzles and optionally refills the queue in the same call.
-- Requires the puzzle:write scope; this is what moves the puzzle rating.
-- @tparam table solutions array of { id = string, win = bool, rated = bool }
-- @int refill_nb how many new puzzles to receive back (0 for none)
-- @treturn table|nil { rounds = ..., puzzles = ..., glicko = ... }, or nil plus an error
function API:solve(solutions, refill_nb)
    local query = buildQuery({ { "nb", refill_nb or 0 } })
    local res, err = self:request("POST", "/api/puzzle/batch/" .. self.angle .. query,
                                  { solutions = solutions })
    if not res then return nil, err end
    return {
        rounds = res.rounds or {},
        puzzles = res.puzzles or {},
        glicko = res.glicko,
    }
end

--- Looks up the rating change for a puzzle in a solve response.
-- @tparam table rounds from API:solve
-- @string puzzle_id
-- @treturn int|nil rating difference
function API.ratingDiffFor(rounds, puzzle_id)
    for i = 1, #(rounds or {}) do
        if rounds[i].id == puzzle_id then return rounds[i].ratingDiff end
    end
    return nil
end

return API
