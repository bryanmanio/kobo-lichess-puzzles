--[[--
Lichess puzzles for KOReader.

Solves lichess.org puzzles on an e-reader and reports the results back, so the
account's puzzle rating moves exactly as it would on the website.

Authentication is a personal access token with the puzzle:read and puzzle:write
scopes, read from a one line file in the KOReader settings directory. That file
is reachable over USB, so the token never has to be typed on the device.

Network calls never ask whether to turn Wi-Fi on. What a request needs is a
connection, an IP and a gateway, not KOReader's "online", which is a DNS lookup
of dns.msftncsi.com that a dozing Kobo radio fails routinely while perfectly
associated. With no connection the plugin makes one instead of asking, because
KOReader turns Wi-Fi off every time the Kobo sleeps and by default never turns
it back on, so its "Do you want to turn on Wi-Fi?" came up after nearly every
wake. A connection already on its way, from KOReader restoring Wi-Fi after a
wake or a radio still associating, is waited for rather than raced. A request
that fails while connected is retried once, and errors only mention Wi-Fi when
the device really is off the network.

The wait and the requests are blocking, so each is preceded by a message that
is given a chance to paint first. Blocking also keeps to one request at a time:
nothing can be solved while the previous result is still being sent.

Setting KO_LICHESS_PUZZLES=1 in the environment turns this into the only thing
KOReader does: the board opens at startup and leaving it exits KOReader, which
on Kobo hands the screen back to the stock interface. That is how the home
screen launcher works, and it is why the board carries its own small menu: in
that mode KOReader's own menus are never on screen.

@module koplugin.lichesspuzzles
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiutil.template

local API = require("api")
local PuzzleView = require("puzzleview")

-- Refill when the queue runs below this, and ask for this many at a time.
local QUEUE_LOW_WATER = 2
local BATCH_SIZE = 10

-- How long to wait for a connection that is already on its way. KOReader's
-- restore script gives wpa_supplicant 15s, and then still has to get an
-- address. Polled, so a quick connection is not kept waiting.
local CONNECT_WAIT = 20
local CONNECT_POLL = 0.25

-- A request that fails while connected is usually the radio still waking from
-- power save, which a short pause and one more attempt gets past.
local RETRY_DELAY = 2

local TOKEN_FILENAME = "lichess_token.txt"

-- Set by the home screen launcher to mean "puzzles are all this run is for".
local KIOSK_ENV = "KO_LICHESS_PUZZLES"

-- The plugin is instantiated once per UI (file manager, then reader), so the
-- autostart has to be remembered for the process, not for the instance.
local autostarted = false

local Lichess = WidgetContainer:extend{
    name = "lichesspuzzles",
    is_doc_only = false,
}

function Lichess:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/lichesspuzzles.lua"
    self.token_file = DataStorage:getSettingsDir() .. "/" .. TOKEN_FILENAME
    self.settings = LuaSettings:open(self.settings_file)

    self.api = API.new{
        token = self:readToken(),
        socketutil = require("socketutil"),
    }

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self.kiosk = os.getenv(KIOSK_ENV) == "1"
    if self.kiosk and not autostarted then
        autostarted = true
        -- Deferred so the file manager finishes coming up first; showing a
        -- widget from inside init would race with it.
        UIManager:nextTick(function() self:start() end)
    end
end

function Lichess:onDispatcherRegisterActions()
    Dispatcher:registerAction("lichesspuzzles_start", {
        category = "none",
        event = "StartLichessPuzzles",
        title = _("Lichess puzzles"),
        general = true,
    })
end

function Lichess:onStartLichessPuzzles()
    self:start()
    return true
end

--- Reads the access token, preferring the USB-reachable file over settings.
-- @treturn string|nil token
function Lichess:readToken()
    local file = io.open(self.token_file, "r")
    if file then
        local line = file:read("*l")
        file:close()
        if line then
            -- Tolerate trailing whitespace and newlines from desktop editors.
            local token = string.match(line, "^%s*(.-)%s*$")
            if token ~= "" then
                -- Mirror it into settings: the file has been seen to vanish
                -- from this folder, and losing it silently stops every result
                -- from being recorded.
                if self.settings:readSetting("token") ~= token then
                    self.settings:saveSetting("token", token)
                    self.settings:flush()
                end
                return token
            end
        end
    end
    return self.settings:readSetting("token")
end

function Lichess:isRated()
    local rated = self.settings:readSetting("rated")
    if rated == nil then return true end
    return rated
end

function Lichess:addToMainMenu(menu_items)
    menu_items.lichess_puzzles = {
        text = _("Lichess puzzles"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Solve puzzles"),
                keep_menu_open = false,
                callback = function() self:start() end,
            },
            {
                text = _("Rated"),
                help_text = _("Rated puzzles update your lichess puzzle rating. Turn this off to practise without affecting it."),
                checked_func = function() return self:isRated() end,
                callback = function()
                    self.settings:saveSetting("rated", not self:isRated())
                    self.settings:flush()
                end,
            },
            {
                text = _("Account"),
                keep_menu_open = true,
                callback = function() self:showAccount() end,
            },
            {
                text = _("How to sign in"),
                keep_menu_open = true,
                callback = function() self:showTokenHelp() end,
            },
        },
    }
end

--- Called when the user leaves the board.
-- Launched from the Kobo home screen there is nothing behind the board worth
-- showing, so quit: KOReader's exit restarts the stock interface, which makes
-- the puzzles behave like an app the device came with. Started from inside
-- KOReader the file manager is behind the board, so leaving is enough.
function Lichess:leaveBoard()
    if not self.kiosk then return end
    UIManager:broadcastEvent(Event:new("Exit"))
end

--- The board's own menu, opened by tapping the status line.
-- Everything here is also in KOReader's menus, which the kiosk never shows.
function Lichess:showBoardMenu(view)
    local dialog
    local function close()
        UIManager:close(dialog)
    end
    local buttons = {
        {{
            text = self:isRated() and _("Rated: on") or _("Rated: off"),
            callback = function()
                self.settings:saveSetting("rated", not self:isRated())
                self.settings:flush()
                -- The result is reported with whatever is set at submission
                -- time, so the status line has to follow the toggle rather
                -- than keep showing what was true when the puzzle opened.
                view.rated = self:isRated()
                view.signed_in = self.api:hasToken()
                view:updateStatus()
                close()
            end,
        }},
        {{
            text = _("Account"),
            callback = function()
                close()
                self:showAccount()
            end,
        }},
        {{
            text = _("Quit"),
            callback = function()
                close()
                view:onClose()
            end,
        }},
    }
    if Device:hasFrontlight() then
        -- KOReader's own dialog: brightness, and warmth on a Kobo that has it.
        table.insert(buttons, 2, {{
            text = _("Frontlight"),
            callback = function()
                close()
                Device:showLightDialog()
            end,
        }})
    end
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

function Lichess:showTokenHelp()
    UIManager:show(InfoMessage:new{
        text = T(_([[To record your results and rating, create a lichess access token with the puzzle:read and puzzle:write permissions:

%1

Then save it as a single line in this file, which you can reach over USB:

%2

Without a token you can still solve puzzles, but nothing is recorded.]]),
            API.TOKEN_URL, self.token_file),
    })
end

function Lichess:showAccount()
    self.api:setToken(self:readToken())
    if not self.api:hasToken() then
        return self:showTokenHelp()
    end
    self:withNetwork(_("Checking your lichess account…"), function()
        return self.api:getAccount()
    end, function(account, err)
        if not account then
            return self:showError(err)
        end
        local rating
        if account.perfs and account.perfs.puzzle then
            rating = account.perfs.puzzle.rating
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Signed in as %1.\nPuzzle rating: %2"),
                account.username or "?", rating and tostring(rating) or _("unknown")),
        })
    end)
end

--- True when KOReader is already bringing a connection up: the Wi-Fi module is
--- loaded but has no address yet, or a turn-on or a restore after a wake is
--- still under way. The pending flags are KOReader's own bookkeeping.
local function connectionUnderway()
    return NetworkMgr:isWifiOn()
        or NetworkMgr.pending_connection
        or NetworkMgr.pending_connectivity_check
end

--- Blocks until the device is connected, or CONNECT_WAIT has passed.
-- @treturn bool whether it is connected
local function waitForConnection()
    local waited = 0
    while not NetworkMgr:isConnected() do
        if waited >= CONNECT_WAIT then return false end
        ffiutil.usleep(CONNECT_POLL * 1e6)
        waited = waited + CONNECT_POLL
    end
    return true
end

--- Runs `callback` once the device is connected, without ever asking.
-- See the note at the top of this file.
-- @func callback run once connected
-- @func on_offline run instead when no connection could be made
local function whenConnected(callback, on_offline)
    if NetworkMgr:isConnected() then return callback() end

    if connectionUnderway() then
        -- Starting another connection now would only fight this one.
        local info = InfoMessage:new{ text = _("Connecting to Wi-Fi…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local connected = waitForConnection()
        UIManager:close(info)
        if connected then return callback() end
    end

    if not NetworkMgr.turnOnWifiAndWaitForConnection then
        -- An older KOReader without it: let it ask, rather than never connect.
        return NetworkMgr:runWhenConnected(callback)
    end
    -- What KOReader itself runs when set to turn Wi-Fi on: join the saved
    -- network, showing progress but never a question. It returns false when
    -- that failed, and nil without connecting when an earlier attempt still
    -- holds the radio; either way the callback is never going to run.
    local attempt = NetworkMgr:turnOnWifiAndWaitForConnection(callback)
    if attempt == false or (attempt == nil and not NetworkMgr:isConnected()) then
        on_offline()
    end
end

--- Runs blocking work once there is a connection, with a message up meanwhile.
-- @string message shown during the call
-- @func work returns value, err
-- @func done called with (value, err)
function Lichess:withNetwork(message, work, done)
    whenConnected(function()
        local info = InfoMessage:new{ text = message, timeout = nil }
        UIManager:show(info)
        -- Give the message a tick to paint before the blocking request starts.
        UIManager:nextTick(function()
            local ok, value, err = pcall(work)
            if ok and value == nil and err and err.code == "network"
                and NetworkMgr:isConnected() then
                ffiutil.sleep(RETRY_DELAY)
                ok, value, err = pcall(work)
            end
            UIManager:close(info)
            if not ok then
                logger.err("lichesspuzzles: request failed:", value)
                done(nil, { code = "internal", message = tostring(value) })
                return
            end
            if err and err.code == "network" and not NetworkMgr:isConnected() then
                -- The connection went away under the request, so this one
                -- really is about Wi-Fi.
                err = { code = "offline", message = err.message }
            end
            done(value, err)
        end)
    end, function()
        done(nil, { code = "offline" })
    end)
end

function Lichess:showError(err)
    local message = err and err.message or _("Something went wrong.")
    if err and err.code == "auth" then
        message = message .. "\n\n" .. _("Check the token file and that it has not expired.")
    elseif err and err.code == "forbidden" then
        message = message .. "\n\n" ..
            _("Create a new token with both puzzle:read and puzzle:write.")
    elseif err and err.code == "network" then
        -- The device is connected, or this would be "offline", so pointing at
        -- Wi-Fi would send the user looking for a fault that is not there.
        message = _("Could not reach lichess. Try again in a moment.")
    elseif err and err.code == "offline" then
        message = _("Not connected to Wi-Fi. Connect to a network and try again.")
    end
    UIManager:show(InfoMessage:new{ text = message })
end

--- Normalises an API puzzle entry into what Session expects.
local function normalise(entry)
    if not entry or not entry.puzzle or not entry.game then return nil end
    return {
        id = entry.puzzle.id,
        pgn = entry.game.pgn,
        solution = entry.puzzle.solution,
        rating = entry.puzzle.rating,
        themes = entry.puzzle.themes,
        initialPly = entry.puzzle.initialPly,
    }
end

function Lichess:queue()
    return self.settings:readSetting("queue") or {}
end

function Lichess:setQueue(queue)
    self.settings:saveSetting("queue", queue)
    self.settings:flush()
end

function Lichess:pending()
    return self.settings:readSetting("pending") or {}
end

function Lichess:setPending(pending)
    self.settings:saveSetting("pending", pending)
    self.settings:flush()
end

--- Entry point: make sure there is a puzzle to show, then show it.
function Lichess:start()
    self.api:setToken(self:readToken())
    if #self:queue() > 0 then
        return self:showNextPuzzle()
    end
    self:fetchMore(function(ok)
        if ok then self:showNextPuzzle() end
    end)
end

--- Fetches a batch and appends it to the queue.
function Lichess:fetchMore(done)
    self:withNetwork(_("Fetching puzzles…"), function()
        return self.api:getBatch(BATCH_SIZE, "normal")
    end, function(puzzles, err)
        if not puzzles then
            self:showError(err)
            return done and done(false)
        end
        local queue = self:queue()
        for i = 1, #puzzles do
            local puzzle = normalise(puzzles[i])
            if puzzle then queue[#queue + 1] = puzzle end
        end
        self:setQueue(queue)
        if #queue == 0 then
            UIManager:show(InfoMessage:new{ text = _("Lichess returned no puzzles.") })
            return done and done(false)
        end
        return done and done(true)
    end)
end

function Lichess:showNextPuzzle()
    local queue = self:queue()
    local puzzle = table.remove(queue, 1)
    self:setQueue(queue)
    if not puzzle then
        return self:fetchMore(function(ok)
            if ok then self:showNextPuzzle() end
        end)
    end

    local view
    view = PuzzleView:new{
        puzzle = puzzle,
        rated = self:isRated(),
        signed_in = self.api:hasToken(),
        on_finished = function(session) self:onPuzzleFinished(session, view) end,
        on_next = function()
            UIManager:close(view)
            self:showNextPuzzle()
        end,
        on_exit = function() self:leaveBoard() end,
        on_menu = function() self:showBoardMenu(view) end,
    }
    if view.broken then
        -- Skip a puzzle we cannot parse rather than getting stuck on it.
        logger.warn("lichesspuzzles: skipping unparseable puzzle", puzzle.id)
        return self:showNextPuzzle()
    end
    UIManager:show(view)
end

--- Records a finished puzzle and tops the queue back up in the same request.
function Lichess:onPuzzleFinished(session, view)
    local pending = self:pending()
    pending[#pending + 1] = session:solutionReport(self:isRated())
    self:setPending(pending)

    if not self.api:hasToken() then
        view:showResult(_("No lichess token - not recorded"))
        return
    end

    local queue = self:queue()
    local refill = (#queue < QUEUE_LOW_WATER) and BATCH_SIZE or 0

    self:withNetwork(_("Recording your result…"), function()
        return self.api:solve(pending, refill)
    end, function(result, err)
        if not result then
            -- Keep the results pending so they are retried next time rather
            -- than silently lost; otherwise the rating would drift from reality.
            logger.warn("lichesspuzzles: submission failed, keeping it pending")
            view:showResult(_("Saved. It will be sent when lichess is reachable."))
            return
        end

        self:setPending({})

        if #result.puzzles > 0 then
            local updated = self:queue()
            for i = 1, #result.puzzles do
                local puzzle = normalise(result.puzzles[i])
                if puzzle then updated[#updated + 1] = puzzle end
            end
            self:setQueue(updated)
        end

        local diff = API.ratingDiffFor(result.rounds, session.puzzle.id)
        local rating = result.glicko and result.glicko.rating
        if not view:isRatedAttempt() then
            -- A casual round records the puzzle without moving the rating, so
            -- a delta would be meaningless or zero.
            view:showResult(T(_("%1  ·  %2"), view:outcomeLabel(), _("Casual")))
        elseif diff and rating then
            view:showResult(T(_("%1  ·  %2 (%3)"),
                view:outcomeLabel(),
                string.format("%d", rating),
                string.format("%+d", diff)))
        elseif diff then
            view:showResult(T(_("Rating change: %1"), string.format("%+d", diff)))
        else
            view:showResult(view:outcomeLabel())
        end
    end)
end

return Lichess
