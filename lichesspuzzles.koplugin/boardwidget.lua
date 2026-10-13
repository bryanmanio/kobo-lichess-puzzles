--[[--
Chess board widget: draws the board and pieces, and turns taps into squares.

Input is tap-to-select then tap-to-move rather than drag. On an e-ink digitizer
a drag is unreliable and would repaint the board on every motion event, so
two taps is both more accurate and far cheaper to refresh.

Rendering notes for e-ink: light squares are white and dark squares are a light
grey, which keeps the solid black pieces legible on both. Piece artwork is
rendered once per square size from SVG and cached, never scaled per repaint.

@module koplugin.lichesspuzzles.boardwidget
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local Screen = Device.screen
local logger = require("logger")

local Chess = require("chess")

local LIGHT_SQUARE = Blitbuffer.COLOR_WHITE
local DARK_SQUARE  = Blitbuffer.COLOR_LIGHT_GRAY      -- 0xCC
-- Darker than either square colour (0xFF light, 0xCC dark), so a highlighted
-- square cannot be mistaken for ordinary board shading. Greyscale is all e-ink
-- has, so the highlight has to come from tone rather than hue.
local LASTMOVE     = Blitbuffer.COLOR_GRAY_9          -- 0x99
local MARK         = Blitbuffer.COLOR_BLACK

--- Draws a thick diagonal stroke, centred on the line it describes.
-- Blitbuffer only fills axis-aligned rectangles, so a diagonal is stepped out
-- of small squares.
local function paintStroke(bb, x0, y0, x1, y1, thickness, colour)
    local steps = math.floor(math.max(math.abs(x1 - x0), math.abs(y1 - y0)))
    local half = math.floor(thickness / 2)
    if steps <= 0 then
        bb:paintRect(math.floor(x0) - half, math.floor(y0) - half,
                     thickness, thickness, colour)
        return
    end
    for i = 0, steps do
        bb:paintRect(math.floor(x0 + (x1 - x0) * i / steps) - half,
                     math.floor(y0 + (y1 - y0) * i / steps) - half,
                     thickness, thickness, colour)
    end
end

--- Draws a badge in the corner of a square: a tick for the move just played
--- being right, a cross for it being wrong.
--
-- Drawn from primitives rather than a glyph, so it cannot degrade into a
-- missing character, and so its polarity can follow what is underneath: a
-- light badge would disappear into a white piece and a dark one into a black
-- piece, so it inverts against whichever it is sitting on.
-- @string kind "correct" or "error"
-- @string piece_code the piece under the badge, e.g. "wQ", or nil
local function paintBadge(bb, sx, sy, size, kind, piece_code)
    local r = math.max(7, math.floor(size / 6))
    local cx = sx + size - r - math.floor(r / 3)
    local cy = sy + r + math.floor(r / 3)

    -- Default to a dark badge: the squares are light, so it reads on an empty
    -- square as well as on a white piece.
    local over_black = piece_code ~= nil and string.sub(piece_code, 1, 1) == "b"
    local disc = over_black and Blitbuffer.COLOR_WHITE or MARK
    local ink = over_black and MARK or Blitbuffer.COLOR_WHITE

    bb:paintCircle(cx, cy, r, disc)
    -- A rim in the ink colour, so a light badge still has an edge where it
    -- overhangs the piece onto a light square.
    bb:paintCircle(cx, cy, r, ink, math.max(1, math.floor(r / 7)))

    local thickness = math.max(2, math.floor(r / 4))
    if kind == "correct" then
        paintStroke(bb, cx - r * 0.45, cy + r * 0.05,
                        cx - r * 0.12, cy + r * 0.42, thickness, ink)
        paintStroke(bb, cx - r * 0.12, cy + r * 0.42,
                        cx + r * 0.50, cy - r * 0.45, thickness, ink)
    else
        paintStroke(bb, cx - r * 0.38, cy - r * 0.38,
                        cx + r * 0.38, cy + r * 0.38, thickness, ink)
        paintStroke(bb, cx + r * 0.38, cy - r * 0.38,
                        cx - r * 0.38, cy + r * 0.38, thickness, ink)
    end
end

--- Locates the piece artwork.
-- The chunk name is not guaranteed to be an absolute path, so deriving the
-- directory from debug.getinfo alone can silently yield a relative path that
-- resolves against KOReader's working directory and finds nothing. Each
-- candidate is probed for a real file before being accepted.
-- @treturn string directory ending in "/"
-- @treturn bool whether real artwork was found there
local function findPiecesDir()
    local candidates = {}
    local source = debug.getinfo(1, "S").source
    local dir = string.match(source, "^@?(.*/)")
    if dir then candidates[#candidates + 1] = dir .. "pieces/" end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getDataDir then
        candidates[#candidates + 1] =
            DataStorage:getDataDir() .. "/plugins/lichesspuzzles.koplugin/pieces/"
    end
    candidates[#candidates + 1] = "plugins/lichesspuzzles.koplugin/pieces/"

    for i = 1, #candidates do
        local probe = io.open(candidates[i] .. "wK.svg", "r")
        if probe then
            probe:close()
            return candidates[i], true
        end
    end
    logger.warn("lichesspuzzles: no piece artwork found; tried",
                table.concat(candidates, ", "))
    return candidates[1] or "pieces/", false
end

--- A letter to draw when a piece image will not render, so a missing or
--- unreadable image degrades to a usable board instead of an empty one.
-- Uppercase is White and lowercase Black, as in FEN.
local function fallbackGlyph(self, code)
    local cached = self.fallback_cache[code]
    if cached then return cached end
    local letter = string.sub(code, 2, 2)
    if string.sub(code, 1, 1) == "b" then letter = string.lower(letter) end
    local widget = TextWidget:new{
        text = letter,
        face = Font:getFace("cfont", math.max(8, math.floor(self.square_size * 0.55))),
        bold = true,
    }
    self.fallback_cache[code] = widget
    return widget
end

local BoardWidget = InputContainer:extend{
    position = nil,          -- a Chess Position
    square_size = nil,       -- pixels; computed from the screen when absent
    flipped = false,         -- true puts Black at the bottom
    pieces_dir = nil,        -- directory holding wK.svg etc.
    on_square_tap = nil,     -- callback(square)
}

function BoardWidget:init()
    if not self.square_size then
        -- Fit the board to the narrower screen dimension so it works on any Kobo.
        self.square_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) / 8)
    end
    local side = self.square_size * 8
    -- Mutated in place by paintTo; the gesture range holds a reference to it.
    self.dimen = Geom:new{ x = 0, y = 0, w = side, h = side }

    self.selected = nil      -- square the user picked up
    self.destinations = {}   -- [square] = true; drives tap handling, never drawn
    self.last_move = nil     -- { from = sq, to = sq }
    self.marks = {}          -- [square] = "hint" | "error"
    self.piece_cache = {}

    self.fallback_cache = {}
    if not self.pieces_dir then
        -- artwork_missing lets the view explain the letters, since only the
        -- user can fix it by re-copying the plugin folder.
        self.pieces_dir, self.artwork_found = findPiecesDir()
        self.artwork_missing = not self.artwork_found
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            TapSquare = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
end

function BoardWidget:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

--- Loads and caches a piece bitmap at the current square size.
-- @string code two character piece code such as "wQ"
local function loadPiece(self, code)
    local cached = self.piece_cache[code]
    if cached ~= nil then return cached end
    local path = self.pieces_dir .. code .. ".svg"
    -- NanoSVG keeps the aspect ratio and centres the result in the target box.
    local ok, bb = pcall(RenderImage.renderSVGImageFile, RenderImage, path,
                         self.square_size, self.square_size)
    if not ok or not bb then
        logger.warn("lichesspuzzles: could not render piece", path, bb)
        self.piece_cache[code] = false
        return false
    end
    self.piece_cache[code] = bb
    return bb
end

function BoardWidget:freePieces()
    for code, bb in pairs(self.piece_cache) do
        if bb then bb:free() end
        self.piece_cache[code] = nil
    end
    for code, widget in pairs(self.fallback_cache or {}) do
        if widget.free then widget:free() end
        self.fallback_cache[code] = nil
    end
end

--- Maps a square to its row and column on screen, honouring board orientation.
-- @treturn int, int column and row, both 0 based from the top left
function BoardWidget:squareToGrid(sq)
    local file, rank = Chess.fileOf(sq), Chess.rankOf(sq)
    if self.flipped then
        return 7 - file, rank
    end
    return file, 7 - rank
end

--- Inverse of squareToGrid.
function BoardWidget:gridToSquare(col, row)
    if col < 0 or col > 7 or row < 0 or row > 7 then return nil end
    local file, rank
    if self.flipped then
        file, rank = 7 - col, row
    else
        file, rank = col, 7 - row
    end
    return rank * 16 + file
end

--- Screen rectangle of a square, in absolute coordinates.
function BoardWidget:squareRect(sq)
    local col, row = self:squareToGrid(sq)
    local s = self.square_size
    return self.dimen.x + col * s, self.dimen.y + row * s, s, s
end

--- The square at an absolute screen position, or nil when outside the board.
function BoardWidget:squareAt(x, y)
    local s = self.square_size
    local col = math.floor((x - self.dimen.x) / s)
    local row = math.floor((y - self.dimen.y) / s)
    return self:gridToSquare(col, row)
end

--- Bounding box of the given squares, for a regional refresh.
-- @tparam table squares array of square indices
-- @treturn Geom|nil region in absolute coordinates
function BoardWidget:regionFor(squares)
    local min_x, min_y, max_x, max_y
    for i = 1, #squares do
        local x, y, w, h = self:squareRect(squares[i])
        if not min_x or x < min_x then min_x = x end
        if not min_y or y < min_y then min_y = y end
        if not max_x or x + w > max_x then max_x = x + w end
        if not max_y or y + h > max_y then max_y = y + h end
    end
    if not min_x then return nil end
    return Geom:new{ x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y }
end

--- Replaces the position shown, returning the squares whose occupant changed.
-- Stepping through a solution can change many squares at once, so the caller
-- refreshes exactly those rather than repainting the whole board.
-- @tparam Position pos the new position
-- @treturn table array of changed squares
function BoardWidget:setPosition(pos)
    local previous = self.position
    local changed = {}
    for sq = 0, 119 do
        if sq % 16 <= 7 then
            local before = previous and previous:pieceCodeAt(sq) or nil
            local after = pos and pos:pieceCodeAt(sq) or nil
            if before ~= after then changed[#changed + 1] = sq end
        end
    end
    self.position = pos
    return changed
end

--- Marks a picked up piece and records where it may legally go.
-- The destinations are deliberately not drawn: the board stays minimal, and
-- the squares are only needed so a second tap knows it completes a move.
-- @int sq selected square, or nil to clear
-- @tparam[opt] table moves legal moves, recorded for tap handling
function BoardWidget:setSelection(sq, moves)
    self.selected = sq
    self.destinations = {}
    for i = 1, #(moves or {}) do
        -- Promotions repeat the same destination; the table collapses them.
        self.destinations[moves[i].to] = true
    end
end

function BoardWidget:setLastMove(from, to)
    self.last_move = from and { from = from, to = to } or nil
end

function BoardWidget:setMark(sq, kind)
    self.marks[sq] = kind
end

function BoardWidget:clearMarks()
    self.marks = {}
end

--- Every square currently painted with a marker, so callers can refresh just
--- those. Legal destinations are excluded because they are not drawn.
function BoardWidget:markedSquares()
    local squares = {}
    if self.selected then squares[#squares + 1] = self.selected end
    for sq in pairs(self.marks) do squares[#squares + 1] = sq end
    if self.last_move then
        squares[#squares + 1] = self.last_move.from
        squares[#squares + 1] = self.last_move.to
    end
    return squares
end

function BoardWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local s = self.square_size
    local pos = self.position

    for sq = 0, 119 do
        if sq % 16 <= 7 then
            local col, row = self:squareToGrid(sq)
            local sx, sy = x + col * s, y + row * s

            -- A square is dark when file and rank have the same parity.
            local dark = ((Chess.fileOf(sq) + Chess.rankOf(sq)) % 2) == 0
            local fill = dark and DARK_SQUARE or LIGHT_SQUARE
            if self.last_move
                and (sq == self.last_move.from or sq == self.last_move.to) then
                fill = LASTMOVE
            end
            bb:paintRect(sx, sy, s, s, fill)

            local code = pos and pos:pieceCodeAt(sq) or nil
            if pos then
                if code then
                    local piece = loadPiece(self, code)
                    if piece then
                        -- NanoSVG gives straight alpha, so alphablitFrom is correct here.
                        bb:alphablitFrom(piece, sx, sy, 0, 0, s, s)
                    else
                        -- Artwork unavailable: draw the letter rather than
                        -- leaving the square empty. A blank board is the one
                        -- failure that makes the plugin unusable.
                        local glyph = fallbackGlyph(self, code)
                        local size = glyph:getSize()
                        glyph:paintTo(bb,
                            sx + math.floor((s - size.w) / 2),
                            sy + math.floor((s - size.h) / 2))
                    end
                end
            end

            -- Markers paint last so pieces never hide them.
            if sq == self.selected then
                -- The only feedback that a tap registered, now that legal
                -- destinations are not drawn, so keep it easy to see.
                bb:paintInnerBorder(sx, sy, s, s, math.max(3, math.floor(s / 16)), MARK)
            end
            local mark = self.marks[sq]
            if mark == "error" or mark == "correct" then
                paintBadge(bb, sx, sy, s, mark, code)
            elseif mark == "hint" then
                bb:paintInnerBorder(sx, sy, s, s, math.max(2, math.floor(s / 24)), MARK)
            end
        end
    end
end

function BoardWidget:onTapSquare(_, ges)
    if not self.on_square_tap then return false end
    local sq = self:squareAt(ges.pos.x, ges.pos.y)
    if not sq then return false end
    self.on_square_tap(sq)
    return true
end

function BoardWidget:onCloseWidget()
    self:freePieces()
end

return BoardWidget
