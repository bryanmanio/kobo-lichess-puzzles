-- Minimal stand-ins for the KOReader modules the plugin requires, so main.lua,
-- puzzleview.lua and boardwidget.lua can be loaded and driven on a desktop.
-- Only what the plugin actually touches is implemented.

local M = { shown = {}, dirty = {}, messages = {}, closed = {}, broadcast = {},
            scheduled = {}, defer_scheduled = false }

local function widgetClass()
    local C = {}
    C.__index = C
    function C:extend(sub)
        sub = sub or {}
        sub.__index = sub
        return setmetatable(sub, { __index = self })
    end
    function C:new(o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end
    return C
end
M.widgetClass = widgetClass

-- A generic container/leaf widget: accepts any fields, stores children.
local function genericWidget()
    local W = widgetClass()
    function W:getSize() return { w = 100, h = 20 } end
    -- Records where it was asked to paint, so positioning can be asserted.
    function W:paintTo(bb, x, y) self.painted_at = { x = x, y = y } end
    function W:setText(text) self.text = text end
    function W:free() end
    return W
end

function M.install(opts)
    opts = opts or {}
    local SCREEN_W = opts.screen_w or 1264
    local SCREEN_H = opts.screen_h or 1680

    local function preload(name, factory)
        package.preload[name] = function() return factory() end
    end

    preload("ffi/blitbuffer", function()
        return setmetatable({}, { __index = function(_, k) return "color:" .. k end })
    end)
    preload("device", function()
        return {
            isTouchDevice = function() return true end,
            hasKeys = function() return true end,
            input = { group = { Back = "Back", PgFwd = "PgFwd", PgBack = "PgBack" } },
            screen = {
                getWidth = function() return SCREEN_W end,
                getHeight = function() return SCREEN_H end,
                scaleBySize = function(_, n) return n end,
            },
        }
    end)
    preload("ui/geometry", function()
        -- Mirrors the real Geom, which defaults x and y to 0. That default is
        -- why a dimen built without a position silently refreshed the screen
        -- corner instead of the widget.
        local Geom = { x = 0, y = 0, w = 0, h = 0 }
        Geom.__index = Geom
        function Geom:new(o) return setmetatable(o or {}, Geom) end
        return Geom
    end)
    preload("ui/gesturerange", function()
        return { new = function(_, o) return o end }
    end)
    preload("ui/renderimage", function()
        -- Piece artwork is not exercised here; nil means "draw nothing".
        return { renderSVGImageFile = function() return nil end }
    end)
    preload("logger", function()
        return { warn = function() end, dbg = function() end, err = function() end,
                 info = function() end }
    end)
    preload("gettext", function()
        return setmetatable({}, { __call = function(_, s) return s end })
    end)
    preload("ui/bidi", function()
        return { wrap = function(s) return s end }
    end)
    preload("ui/font", function()
        return { getFace = function() return { size = 20 } end }
    end)
    preload("ui/size", function()
        return {
            span = { vertical_default = 2, vertical_large = 5, horizontal_default = 10 },
            padding = { small = 2, large = 8, button = 4 },
            border = { window = 2 },
            line = { medium = 2 },
        }
    end)

    for _, name in ipairs({
        "ui/widget/container/inputcontainer",
        "ui/widget/container/widgetcontainer",
        "ui/widget/container/framecontainer",
        "ui/widget/container/centercontainer",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "ui/widget/textwidget",
    }) do
        preload(name, genericWidget)
    end

    preload("ui/widget/buttontable", function()
        local BT = genericWidget()
        function BT:init()
            self.by_id = {}
            for _, row in ipairs(self.buttons or {}) do
                for _, spec in ipairs(row) do
                    local button = {
                        spec = spec,
                        text = spec.text,
                        width = 100,
                        enabled = spec.enabled ~= false,
                        enable = function(b) b.enabled = true end,
                        disable = function(b) b.enabled = false end,
                        refresh = function() end,
                        setText = function(b, text, width)
                            b.text = text
                            if width then b.width = width end
                        end,
                    }
                    if spec.id then self.by_id[spec.id] = button end
                end
            end
        end
        function BT:getButtonById(id) return self.by_id[id] end
        return BT
    end)

    preload("ui/widget/buttondialog", function()
        local BD = genericWidget()
        function BD:init() M.last_dialog = self end
        return BD
    end)

    preload("ui/widget/infomessage", function()
        local IM = genericWidget()
        function IM:init() M.messages[#M.messages + 1] = self.text end
        return IM
    end)

    preload("ui/event", function()
        return { new = function(_, name, ...)
            return { handler = "on" .. name, args = { ... } }
        end }
    end)

    preload("ui/uimanager", function()
        return {
            show = function(_, w) M.shown[#M.shown + 1] = w end,
            close = function(_, w) M.closed[#M.closed + 1] = w end,
            broadcastEvent = function(_, event)
                M.broadcast[#M.broadcast + 1] = event.handler
            end,
            setDirty = function(_, w, mode, region)
                M.dirty[#M.dirty + 1] = { widget = w, mode = mode, region = region }
            end,
            -- Deferred work runs immediately so flows complete inside the
            -- test. Set M.defer_scheduled to queue it instead, for assertions
            -- about what is on screen before a timer fires.
            nextTick = function(_, fn) fn() end,
            scheduleIn = function(_, _, fn)
                if M.defer_scheduled then
                    M.scheduled[#M.scheduled + 1] = fn
                else
                    fn()
                end
            end,
            unschedule = function(_, fn)
                for i = #M.scheduled, 1, -1 do
                    if M.scheduled[i] == fn then table.remove(M.scheduled, i) end
                end
            end,
        }
    end)

    preload("ui/network/manager", function()
        return { runWhenOnline = function(_, fn) fn() end,
                 isOnline = function() return true end }
    end)
    preload("datastorage", function()
        return { getSettingsDir = function() return opts.settings_dir or "/tmp" end }
    end)
    preload("dispatcher", function()
        return { registerAction = function() end }
    end)
    preload("socketutil", function()
        return { set_timeout = function() end, reset_timeout = function() end }
    end)
    preload("ffi/util", function()
        return {
            template = function(fmt, ...)
                local args = { ... }
                return (string.gsub(fmt, "%%(%d)", function(n)
                    return tostring(args[tonumber(n)])
                end))
            end,
        }
    end)
    preload("luasettings", function()
        local LS = {}
        LS.__index = LS
        function LS:open() return setmetatable({ data = {} }, LS) end
        function LS:readSetting(k) return self.data[k] end
        function LS:saveSetting(k, v) self.data[k] = v; return self end
        function LS:flush() end
        return LS
    end)

    preload("ltn12", function()
        return {
            sink = { table = function(t)
                return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
            end },
            source = { string = function(s) return function() return s end end },
        }
    end)

    return M
end

function M.reset()
    M.shown, M.dirty, M.messages, M.closed = {}, {}, {}, {}
    M.broadcast = {}
    M.scheduled = {}
    M.defer_scheduled = false
    M.last_dialog = nil
end

--- Runs everything queued while deferring, in order.
-- @treturn int how many callbacks fired
function M.runScheduled()
    local queued = M.scheduled
    M.scheduled = {}
    for _, fn in ipairs(queued) do fn() end
    return #queued
end

return M
