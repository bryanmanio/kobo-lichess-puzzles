-- Board geometry: square <-> screen mapping, orientation and refresh regions.
-- KOReader modules are stubbed, so this runs on a desktop with plain luajit.
-- Run with: luajit spec/board_spec.lua

package.path = "lichesspuzzles.koplugin/?.lua;" .. package.path

-- Minimal stand-in for KOReader's widget class model.
local function widgetClass()
    local C = {}
    C.__index = C
    function C:extend(subclass)
        subclass = subclass or {}
        subclass.__index = subclass
        setmetatable(subclass, { __index = self })
        return subclass
    end
    function C:new(o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end
    return C
end

-- Libra H2O panel, the target device.
local SCREEN_W, SCREEN_H = 1264, 1680

package.preload["ffi/blitbuffer"] = function()
    -- Any colour name resolves to a distinct value. A fixed list would return
    -- nil for a constant the widget starts using, which silently turns colour
    -- assertions into nil == nil.
    return setmetatable({}, { __index = function(_, k) return "color:" .. k end })
end
package.preload["device"] = function()
    return {
        isTouchDevice = function() return true end,
        screen = { getWidth = function() return SCREEN_W end,
                   getHeight = function() return SCREEN_H end },
    }
end
package.preload["ui/geometry"] = function()
    local Geom = {}
    Geom.__index = Geom
    function Geom:new(o) return setmetatable(o or {}, Geom) end
    return Geom
end
package.preload["ui/gesturerange"] = function()
    local G = {}
    function G:new(o) return o end
    return G
end
package.preload["ui/widget/container/inputcontainer"] = function() return widgetClass() end
package.preload["ui/renderimage"] = function()
    return { renderSVGImageFile = function() return nil end }
end
package.preload["logger"] = function()
    return { warn = function() end, dbg = function() end, err = function() end }
end
package.preload["ui/font"] = function()
    return { getFace = function() return { size = 20 } end }
end
package.preload["ui/widget/textwidget"] = function()
    local TW = widgetClass()
    function TW:getSize() return { w = 20, h = 24 } end
    function TW:paintTo(bb, x, y)
        if bb.glyphs then bb.glyphs[#bb.glyphs + 1] = { text = self.text, x = x, y = y } end
    end
    function TW:free() end
    return TW
end

local Chess = require("chess")
local BoardWidget = require("boardwidget")

local failures, checks = 0, 0
local function check(ok, msg)
    checks = checks + 1
    if not ok then failures = failures + 1; print("FAIL " .. msg) end
    return ok
end

local function sq(name) return Chess.algebraicToSquare(name) end

-- 1. Sizing fits the narrower screen dimension, so the board is square on any Kobo.
do
    local b = BoardWidget:new{}
    check(b.square_size == math.floor(SCREEN_W / 8),
        "square size should divide the narrow dimension: " .. tostring(b.square_size))
    check(b.dimen.w == b.square_size * 8 and b.dimen.h == b.dimen.w,
        "board should be square")
end

-- 2. Orientation. Unflipped puts a8 top-left and h1 bottom-right.
do
    local b = BoardWidget:new{}
    local col, row = b:squareToGrid(sq("a8"))
    check(col == 0 and row == 0, string.format("a8 should be top-left, got %d,%d", col, row))
    col, row = b:squareToGrid(sq("h1"))
    check(col == 7 and row == 7, string.format("h1 should be bottom-right, got %d,%d", col, row))
    col, row = b:squareToGrid(sq("a1"))
    check(col == 0 and row == 7, string.format("a1 should be bottom-left, got %d,%d", col, row))
end

-- Flipped puts h1 top-left and a8 bottom-right, so Black sits at the bottom.
do
    local b = BoardWidget:new{ flipped = true }
    local col, row = b:squareToGrid(sq("h1"))
    check(col == 0 and row == 0, string.format("flipped h1 should be top-left, got %d,%d", col, row))
    col, row = b:squareToGrid(sq("a8"))
    check(col == 7 and row == 7, string.format("flipped a8 should be bottom-right, got %d,%d", col, row))
end

-- 3. Round trips over every square, in both orientations. A tap anywhere inside
--    a square must resolve back to that square.
for _, flipped in ipairs({ false, true }) do
    local b = BoardWidget:new{ flipped = flipped }
    b.dimen.x, b.dimen.y = 37, 101   -- arbitrary non-zero origin
    local label = flipped and "flipped" or "normal"
    local bad_grid, bad_tap = 0, 0
    for rank = 0, 7 do
        for file = 0, 7 do
            local square = rank * 16 + file
            local col, row = b:squareToGrid(square)
            if b:gridToSquare(col, row) ~= square then bad_grid = bad_grid + 1 end

            local x, y, w, h = b:squareRect(square)
            -- Probe the corners and centre of the square.
            local probes = {
                { x + 1, y + 1 }, { x + w - 1, y + 1 },
                { x + 1, y + h - 1 }, { x + w - 1, y + h - 1 },
                { x + math.floor(w / 2), y + math.floor(h / 2) },
            }
            for _, p in ipairs(probes) do
                if b:squareAt(p[1], p[2]) ~= square then bad_tap = bad_tap + 1 end
            end
        end
    end
    check(bad_grid == 0, string.format("%s: %d squares failed grid round trip", label, bad_grid))
    check(bad_tap == 0, string.format("%s: %d tap probes resolved to the wrong square", label, bad_tap))
end

-- 4. Taps outside the board must be rejected rather than clamped to an edge square.
do
    local b = BoardWidget:new{}
    b.dimen.x, b.dimen.y = 0, 200
    check(b:squareAt(-5, 300) == nil, "tap left of the board should be nil")
    check(b:squareAt(5, 100) == nil, "tap above the board should be nil")
    check(b:squareAt(b.dimen.w + 5, 300) == nil, "tap right of the board should be nil")
    check(b:squareAt(5, 200 + b.dimen.h + 5) == nil, "tap below the board should be nil")
end

-- 5. Refresh regions cover exactly the squares asked for.
do
    local b = BoardWidget:new{}
    b.dimen.x, b.dimen.y = 0, 0
    local s = b.square_size
    local region = b:regionFor({ sq("a1"), sq("a2") })
    check(region.w == s and region.h == 2 * s,
        string.format("two stacked squares should give a 1x2 region, got %dx%d",
                      region.w, region.h))
    local one = b:regionFor({ sq("d4") })
    check(one.w == s and one.h == s, "single square region should be one square")
    check(b:regionFor({}) == nil, "empty square list should give no region")
end

-- 6. Promotions generate four moves to the same square; the dot set must collapse them.
do
    local b = BoardWidget:new{}
    local pos = Chess.newFromFEN("8/4P3/8/8/8/8/8/K6k w - - 0 1")
    local moves = pos:legalMoves(sq("e7"))
    check(#moves == 4, "a pawn on the seventh should have four promotion moves, got " .. #moves)
    b:setSelection(sq("e7"), moves)
    local count = 0
    for _ in pairs(b.destinations) do count = count + 1 end
    check(count == 1, "four promotions should collapse to one destination dot, got " .. count)
    check(b.destinations[sq("e8")] == true, "destination should be e8")
end

-- 7. markedSquares reports what is actually painted, and nothing else.
-- Legal destinations are tracked for tap handling but never drawn, so they
-- must not inflate the refresh region.
do
    local b = BoardWidget:new{}
    b:setSelection(sq("e2"), { { to = sq("e4") }, { to = sq("e3") } })
    b:setLastMove(sq("g8"), sq("f6"))
    b:setMark(sq("c3"), "hint")
    local seen = {}
    for _, s in ipairs(b:markedSquares()) do seen[s] = true end
    for _, name in ipairs({ "e2", "g8", "f6", "c3" }) do
        check(seen[sq(name)] == true, "markedSquares should include " .. name)
    end
    for _, name in ipairs({ "e4", "e3" }) do
        check(seen[sq(name)] ~= true,
            "markedSquares must not include undrawn destination " .. name)
    end
    -- The destinations are still recorded, or a second tap could not move.
    check(b.destinations[sq("e4")] == true, "destinations should still be tracked")
    check(b.destinations[sq("e3")] == true, "destinations should still be tracked")
end

-- 8. Selecting a piece therefore refreshes exactly one square.
do
    local b = BoardWidget:new{}
    b.dimen.x, b.dimen.y = 0, 0
    local many = {}
    for file = 0, 7 do many[#many + 1] = { to = 4 * 16 + file } end
    b:setSelection(sq("e1"), many)
    local region = b:regionFor(b:markedSquares())
    check(region.w == b.square_size and region.h == b.square_size,
        string.format("a selection should refresh one square, got %dx%d",
                      region.w, region.h))
end

-- 9. The board must never render blank. If the piece artwork cannot be
-- rendered (the stub RenderImage always fails), every piece falls back to a
-- letter so the puzzle is still playable and the failure is visible.
do
    local b = BoardWidget:new{}
    b.dimen.x, b.dimen.y = 0, 0
    b.position = Chess.new()           -- the standard opening array: 32 pieces

    local fake_bb = {
        rects = 0, blits = 0, glyphs = {},
        paintRect = function(self) self.rects = self.rects + 1 end,
        alphablitFrom = function(self) self.blits = self.blits + 1 end,
        paintInnerBorder = function() end,
        invertRect = function() end,
        paintCircle = function() end,
    }

    local ok, err = pcall(function() b:paintTo(fake_bb, 0, 0) end)
    check(ok, "painting must not error when artwork is missing: " .. tostring(err))
    check(fake_bb.rects == 64, "all 64 squares should be painted, got " .. fake_bb.rects)
    check(fake_bb.blits == 0, "the stub renderer cannot produce bitmaps")
    check(#fake_bb.glyphs == 32,
        "every piece should fall back to a letter, got " .. #fake_bb.glyphs)

    -- Uppercase is White and lowercase Black, as in FEN.
    local seen = {}
    for _, g in ipairs(fake_bb.glyphs) do seen[g.text] = (seen[g.text] or 0) + 1 end
    check(seen["P"] == 8 and seen["p"] == 8, "eight pawns a side")
    check(seen["K"] == 1 and seen["k"] == 1, "one king a side")
    check(seen["R"] == 2 and seen["r"] == 2, "two rooks a side")
end

-- 10. The artwork directory is probed for a real file, not merely derived.
do
    local b = BoardWidget:new{}
    local probe = io.open(b.pieces_dir .. "wK.svg", "r")
    check(probe ~= nil, "pieces_dir should point at real artwork, got " .. tostring(b.pieces_dir))
    if probe then probe:close() end
end

-- 11. The last-move highlight must be a tone no ordinary square uses, or it
-- reads as board shading rather than as a highlight. e-ink has no colour, so
-- the distinction has to come from tone.
do
    local b = BoardWidget:new{}
    b.dimen.x, b.dimen.y = 0, 0
    b.position = Chess.new()
    b:setLastMove(sq("e2"), sq("e4"))

    local fills = {}
    local fake_bb = {
        paintRect = function(_, x, y, w, h, value)
            fills[#fills + 1] = { x = x, y = y, value = value }
        end,
        alphablitFrom = function() end,
        paintInnerBorder = function() end,
        invertRect = function() end,
        paintCircle = function() end,
        glyphs = {},
    }
    b:paintTo(fake_bb, 0, 0)

    local function fillAt(square)
        local x, y = b:squareRect(square)
        for _, f in ipairs(fills) do
            if f.x == x and f.y == y then return f.value end
        end
    end

    local highlight_from = fillAt(sq("e2"))
    local highlight_to = fillAt(sq("e4"))
    check(highlight_from == highlight_to,
        "both ends of the move should share one highlight tone")

    -- Gather the tones used by squares that are not highlighted.
    local ordinary = {}
    for square = 0, 119 do
        if square % 16 <= 7 and square ~= sq("e2") and square ~= sq("e4") then
            ordinary[fillAt(square)] = true
        end
    end
    check(ordinary[highlight_from] ~= true,
        "the highlight tone must not be one the board already uses: "
        .. tostring(highlight_from))
    local count = 0
    for _ in pairs(ordinary) do count = count + 1 end
    check(count == 2, "ordinary squares should use exactly two tones, got " .. count)
end

-- 12. The badges are drawn from pixels, and invert against the piece beneath:
-- a light badge would vanish into a white piece and a dark one into a black
-- piece. Drawn rather than lettered, so no font can fail to provide them.
do
    local WHITE, BLACK = "color:COLOR_WHITE", "color:COLOR_BLACK"
    local b = BoardWidget:new{}
    b.dimen.x, b.dimen.y = 0, 0
    b.position = Chess.new()
    b:setMark(sq("e2"), "correct")   -- a white pawn stands here
    b:setMark(sq("e7"), "error")     -- a black pawn stands here

    local circles, rects = {}, {}
    local fake_bb = {
        paintRect = function(_, x, y, w, h, value)
            rects[#rects + 1] = { x = x, y = y, w = w, h = h, value = value }
        end,
        paintCircle = function(_, cx, cy, r, colour, width)
            circles[#circles + 1] = { x = cx, y = cy, r = r, colour = colour, width = width }
        end,
        alphablitFrom = function() end,
        paintInnerBorder = function() end,
        invertRect = function() end,
        glyphs = {},
    }
    b:paintTo(fake_bb, 0, 0)

    local function badgeOn(square)
        local x, y, w, h = b:squareRect(square)
        local found = {}
        for _, c in ipairs(circles) do
            if c.x >= x and c.x <= x + w and c.y >= y and c.y <= y + h then
                found[#found + 1] = c
            end
        end
        return found
    end

    local on_white = badgeOn(sq("e2"))
    local on_black = badgeOn(sq("e7"))
    check(#on_white == 2, "a badge is a disc plus a rim, got " .. #on_white)
    check(#on_black == 2, "a badge is a disc plus a rim, got " .. #on_black)

    if #on_white == 2 then
        check(on_white[1].colour == BLACK,
            "over a white piece the disc must be dark, got " .. tostring(on_white[1].colour))
        check(on_white[2].colour == WHITE, "its rim and ink must be light")
        check(on_white[2].width ~= nil and on_white[2].width < on_white[2].r,
            "the rim must be an outline, not a second filled disc")
    end
    if #on_black == 2 then
        check(on_black[1].colour == WHITE,
            "over a black piece the disc must be light, got " .. tostring(on_black[1].colour))
        check(on_black[2].colour == BLACK, "its rim and ink must be dark")
    end

    -- The symbol itself is stroked inside the badge, in the ink colour.
    local function strokesIn(badge, ink)
        local n = 0
        for _, r in ipairs(rects) do
            if r.value == ink and r.w < badge.r * 2
                and math.abs(r.x - badge.x) <= badge.r
                and math.abs(r.y - badge.y) <= badge.r then
                n = n + 1
            end
        end
        return n
    end
    if #on_white == 2 then
        check(strokesIn(on_white[1], WHITE) > 0,
            "the tick should be stroked in light ink over a white piece")
    end
    if #on_black == 2 then
        check(strokesIn(on_black[1], BLACK) > 0,
            "the cross should be stroked in dark ink over a black piece")
    end

    -- Both badges sit in a corner rather than covering the square.
    for _, badge in ipairs({ on_white[1], on_black[1] }) do
        if badge then
            check(badge.r > 0 and badge.r < b.square_size / 2,
                "a badge should be a corner mark, got radius " .. tostring(badge.r))
        end
    end

    -- No badge when nothing is marked.
    local b2 = BoardWidget:new{}
    b2.dimen.x, b2.dimen.y = 0, 0
    b2.position = Chess.new()
    local circles2 = {}
    local bb2 = {
        paintRect = function() end,
        paintCircle = function(_, cx) circles2[#circles2 + 1] = cx end,
        alphablitFrom = function() end,
        paintInnerBorder = function() end,
        invertRect = function() end,
        glyphs = {},
    }
    b2:paintTo(bb2, 0, 0)
    check(#circles2 == 0, "an unmarked board should draw no badge")
end

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
