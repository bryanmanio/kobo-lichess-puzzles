--[[--
Chess rules engine: board state, legal move generation, SAN parsing, UCI conversion.

Pure Lua with no KOReader dependencies, so it can be unit tested on a desktop
with luajit. Lua 5.1 / LuaJIT compatible: no integer division, no bit library.

Board uses the classic 0x88 representation: square = rank * 16 + file, where
rank 0 is White's back rank and file 0 is the a-file. A square is on the board
when its file nibble is <= 7, which we test with arithmetic rather than a
bitwise AND so no bit library is required.

@module koplugin.lichesspuzzles.chess
]]

local WHITE, BLACK = 1, 2
local PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING = 1, 2, 3, 4, 5, 6

-- Pieces are encoded as a single integer: white = type, black = type + 8.
local BLACK_OFFSET = 8

local PIECE_LETTER = { [PAWN] = "P", [KNIGHT] = "N", [BISHOP] = "B",
                       [ROOK] = "R", [QUEEN] = "Q", [KING] = "K" }
local LETTER_PIECE = { P = PAWN, N = KNIGHT, B = BISHOP,
                       R = ROOK, Q = QUEEN, K = KING }

local KNIGHT_OFFSETS = { -33, -31, -18, -14, 14, 18, 31, 33 }
local KING_OFFSETS   = { -17, -16, -15, -1, 1, 15, 16, 17 }
local BISHOP_OFFSETS = { -17, -15, 15, 17 }
local ROOK_OFFSETS   = { -16, -1, 1, 16 }
local QUEEN_OFFSETS  = { -17, -16, -15, -1, 1, 15, 16, 17 }

local SLIDING_OFFSETS = {
    [BISHOP] = BISHOP_OFFSETS,
    [ROOK]   = ROOK_OFFSETS,
    [QUEEN]  = QUEEN_OFFSETS,
}

-- Corner squares, used to revoke castling rights when a rook moves or is taken.
local A1, H1, E1 = 0, 7, 4
local A8, H8, E8 = 112, 119, 116

local floor = math.floor

local function onBoard(sq)
    return sq >= 0 and sq <= 119 and sq % 16 <= 7
end

local function pieceColor(p)
    if p > BLACK_OFFSET then return BLACK end
    return WHITE
end

local function pieceType(p)
    if p > BLACK_OFFSET then return p - BLACK_OFFSET end
    return p
end

local function makePiece(color, ptype)
    if color == BLACK then return ptype + BLACK_OFFSET end
    return ptype
end

local function opponent(color)
    if color == WHITE then return BLACK end
    return WHITE
end

local function fileOf(sq) return sq % 16 end
local function rankOf(sq) return floor(sq / 16) end

local function squareToAlgebraic(sq)
    return string.char(97 + fileOf(sq)) .. tostring(rankOf(sq) + 1)
end

local function algebraicToSquare(s)
    local f = string.byte(s, 1) - 97
    local r = string.byte(s, 2) - 49
    if f < 0 or f > 7 or r < 0 or r > 7 then return nil end
    return r * 16 + f
end

local Position = {}
Position.__index = Position

local Chess = {
    WHITE = WHITE,
    BLACK = BLACK,
    PAWN = PAWN, KNIGHT = KNIGHT, BISHOP = BISHOP,
    ROOK = ROOK, QUEEN = QUEEN, KING = KING,
    squareToAlgebraic = squareToAlgebraic,
    algebraicToSquare = algebraicToSquare,
    fileOf = fileOf,
    rankOf = rankOf,
    pieceColor = pieceColor,
    pieceType = pieceType,
}

--- Creates an empty position. Callers normally want newFromFEN or newFromPGN.
function Chess.newEmpty()
    local self = setmetatable({}, Position)
    self.board = {}
    for sq = 0, 119 do self.board[sq] = 0 end
    self.turn = WHITE
    self.castling = { [WHITE] = { k = false, q = false },
                      [BLACK] = { k = false, q = false } }
    self.ep = nil
    self.halfmove = 0
    self.fullmove = 1
    self.kings = { [WHITE] = nil, [BLACK] = nil }
    self.undo_stack = {}
    return self
end

local STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

--- Parses a FEN string into a Position.
-- @string fen full FEN; the halfmove and fullmove fields may be omitted
-- @treturn Position|nil position, or nil plus an error message
function Chess.newFromFEN(fen)
    local self = Chess.newEmpty()
    local fields = {}
    for word in string.gmatch(fen, "%S+") do fields[#fields + 1] = word end
    if #fields < 4 then return nil, "FEN must have at least 4 fields" end

    local rank, file = 7, 0
    for i = 1, #fields[1] do
        local c = string.sub(fields[1], i, i)
        if c == "/" then
            rank, file = rank - 1, 0
        elseif string.match(c, "%d") then
            file = file + tonumber(c)
        else
            local ptype = LETTER_PIECE[string.upper(c)]
            if not ptype then return nil, "bad piece in FEN: " .. c end
            -- Lowercase letters are Black, uppercase are White.
            local color = (c == string.lower(c)) and BLACK or WHITE
            if rank < 0 or file > 7 then return nil, "FEN board overflows" end
            local sq = rank * 16 + file
            self.board[sq] = makePiece(color, ptype)
            if ptype == KING then self.kings[color] = sq end
            file = file + 1
        end
    end

    self.turn = (fields[2] == "b") and BLACK or WHITE

    if fields[3] ~= "-" then
        self.castling[WHITE].k = string.find(fields[3], "K", 1, true) ~= nil
        self.castling[WHITE].q = string.find(fields[3], "Q", 1, true) ~= nil
        self.castling[BLACK].k = string.find(fields[3], "k", 1, true) ~= nil
        self.castling[BLACK].q = string.find(fields[3], "q", 1, true) ~= nil
    end

    if fields[4] ~= "-" then self.ep = algebraicToSquare(fields[4]) end
    self.halfmove = tonumber(fields[5] or "0") or 0
    self.fullmove = tonumber(fields[6] or "1") or 1

    if not self.kings[WHITE] or not self.kings[BLACK] then
        return nil, "FEN is missing a king"
    end
    return self
end

--- Creates a position at the standard starting array.
function Chess.new()
    return Chess.newFromFEN(STARTPOS_FEN)
end

--- Serialises the position back to FEN. Used by tests and for debugging.
function Position:toFEN()
    local rows = {}
    for rank = 7, 0, -1 do
        local row, empty = {}, 0
        for file = 0, 7 do
            local p = self.board[rank * 16 + file]
            if p == 0 then
                empty = empty + 1
            else
                if empty > 0 then row[#row + 1] = tostring(empty); empty = 0 end
                local letter = PIECE_LETTER[pieceType(p)]
                row[#row + 1] = (pieceColor(p) == WHITE) and letter or string.lower(letter)
            end
        end
        if empty > 0 then row[#row + 1] = tostring(empty) end
        rows[#rows + 1] = table.concat(row)
    end

    local rights = {}
    if self.castling[WHITE].k then rights[#rights + 1] = "K" end
    if self.castling[WHITE].q then rights[#rights + 1] = "Q" end
    if self.castling[BLACK].k then rights[#rights + 1] = "k" end
    if self.castling[BLACK].q then rights[#rights + 1] = "q" end

    return table.concat(rows, "/")
        .. " " .. ((self.turn == WHITE) and "w" or "b")
        .. " " .. ((#rights > 0) and table.concat(rights) or "-")
        .. " " .. (self.ep and squareToAlgebraic(self.ep) or "-")
        .. " " .. tostring(self.halfmove)
        .. " " .. tostring(self.fullmove)
end

--- Returns the side to move as "white" or "black".
function Position:sideToMove()
    return (self.turn == WHITE) and "white" or "black"
end

--- Returns a two character piece code at a square, e.g. "wP" or "bK".
-- Matches the cburnett image filenames, so the board widget can use it directly.
-- @int sq 0x88 square index
-- @treturn string|nil code, or nil when the square is empty
function Position:pieceCodeAt(sq)
    local p = self.board[sq]
    if not p or p == 0 then return nil end
    return ((pieceColor(p) == WHITE) and "w" or "b") .. PIECE_LETTER[pieceType(p)]
end

--- True when `sq` is attacked by any piece of `color`.
-- Used both for legality filtering and for check detection.
function Position:isAttacked(sq, color)
    local board = self.board

    -- Pawns. A white pawn on sq-15 or sq-17 attacks sq; black is mirrored.
    if color == WHITE then
        local p = board[sq - 15]
        if p and p ~= 0 and onBoard(sq - 15) and p == PAWN then return true end
        p = board[sq - 17]
        if p and p ~= 0 and onBoard(sq - 17) and p == PAWN then return true end
    else
        local bp = PAWN + BLACK_OFFSET
        local p = board[sq + 15]
        if p and p ~= 0 and onBoard(sq + 15) and p == bp then return true end
        p = board[sq + 17]
        if p and p ~= 0 and onBoard(sq + 17) and p == bp then return true end
    end

    local knight = makePiece(color, KNIGHT)
    for i = 1, #KNIGHT_OFFSETS do
        local target = sq + KNIGHT_OFFSETS[i]
        if onBoard(target) and board[target] == knight then return true end
    end

    local king = makePiece(color, KING)
    for i = 1, #KING_OFFSETS do
        local target = sq + KING_OFFSETS[i]
        if onBoard(target) and board[target] == king then return true end
    end

    -- Sliding pieces: walk outwards until we hit something.
    local bishop, rook, queen =
        makePiece(color, BISHOP), makePiece(color, ROOK), makePiece(color, QUEEN)
    for i = 1, #BISHOP_OFFSETS do
        local target = sq + BISHOP_OFFSETS[i]
        while onBoard(target) do
            local p = board[target]
            if p ~= 0 then
                if p == bishop or p == queen then return true end
                break
            end
            target = target + BISHOP_OFFSETS[i]
        end
    end
    for i = 1, #ROOK_OFFSETS do
        local target = sq + ROOK_OFFSETS[i]
        while onBoard(target) do
            local p = board[target]
            if p ~= 0 then
                if p == rook or p == queen then return true end
                break
            end
            target = target + ROOK_OFFSETS[i]
        end
    end

    return false
end

--- True when the side to move (or `color`, if given) is in check.
function Position:isCheck(color)
    color = color or self.turn
    return self:isAttacked(self.kings[color], opponent(color))
end

local function addPawnMoves(moves, from, to, flags, captured)
    -- A pawn reaching the last rank generates one move per promotion piece.
    local rank = rankOf(to)
    if rank == 7 or rank == 0 then
        local promos = { QUEEN, ROOK, BISHOP, KNIGHT }
        for i = 1, #promos do
            moves[#moves + 1] = { from = from, to = to, piece = PAWN,
                                  captured = captured, promotion = promos[i],
                                  flags = flags }
        end
    else
        moves[#moves + 1] = { from = from, to = to, piece = PAWN,
                              captured = captured, flags = flags }
    end
end

--- Generates pseudo-legal moves: legal except that they may leave the king in check.
-- @int only_from optional square to restrict generation to
function Position:generatePseudoMoves(only_from)
    local moves = {}
    local board = self.board
    local us, them = self.turn, opponent(self.turn)

    for from = 0, 119 do
        if onBoard(from) and (not only_from or from == only_from) then
            local p = board[from]
            if p ~= 0 and pieceColor(p) == us then
                local ptype = pieceType(p)

                if ptype == PAWN then
                    local forward = (us == WHITE) and 16 or -16
                    local start_rank = (us == WHITE) and 1 or 6
                    local one = from + forward

                    if onBoard(one) and board[one] == 0 then
                        addPawnMoves(moves, from, one, nil, nil)
                        local two = one + forward
                        if rankOf(from) == start_rank and board[two] == 0 then
                            moves[#moves + 1] = { from = from, to = two, piece = PAWN,
                                                  flags = "double" }
                        end
                    end

                    local caps = (us == WHITE) and { 15, 17 } or { -15, -17 }
                    for i = 1, 2 do
                        local to = from + caps[i]
                        if onBoard(to) then
                            local target = board[to]
                            if target ~= 0 and pieceColor(target) == them then
                                addPawnMoves(moves, from, to, nil, target)
                            elseif self.ep and to == self.ep then
                                -- En passant: the captured pawn is beside us, not on `to`.
                                moves[#moves + 1] = { from = from, to = to, piece = PAWN,
                                                      captured = makePiece(them, PAWN),
                                                      flags = "ep" }
                            end
                        end
                    end

                elseif ptype == KNIGHT or ptype == KING then
                    local offsets = (ptype == KNIGHT) and KNIGHT_OFFSETS or KING_OFFSETS
                    for i = 1, #offsets do
                        local to = from + offsets[i]
                        if onBoard(to) then
                            local target = board[to]
                            if target == 0 or pieceColor(target) == them then
                                moves[#moves + 1] = { from = from, to = to, piece = ptype,
                                                      captured = (target ~= 0) and target or nil }
                            end
                        end
                    end

                else
                    local offsets = SLIDING_OFFSETS[ptype]
                    for i = 1, #offsets do
                        local to = from + offsets[i]
                        while onBoard(to) do
                            local target = board[to]
                            if target == 0 then
                                moves[#moves + 1] = { from = from, to = to, piece = ptype }
                            else
                                if pieceColor(target) == them then
                                    moves[#moves + 1] = { from = from, to = to, piece = ptype,
                                                          captured = target }
                                end
                                break
                            end
                            to = to + offsets[i]
                        end
                    end
                end
            end
        end
    end

    -- Castling. The king must not be in check, pass through, or land on an
    -- attacked square; the squares between king and rook must be empty.
    local king_sq = self.kings[us]
    if not only_from or only_from == king_sq then
        local rights = self.castling[us]
        local home = (us == WHITE) and E1 or E8
        if king_sq == home and not self:isAttacked(king_sq, them) then
            if rights.k
                and board[home + 1] == 0 and board[home + 2] == 0
                and board[home + 3] == makePiece(us, ROOK)
                and not self:isAttacked(home + 1, them)
                and not self:isAttacked(home + 2, them) then
                moves[#moves + 1] = { from = home, to = home + 2, piece = KING,
                                      flags = "castle_k" }
            end
            if rights.q
                and board[home - 1] == 0 and board[home - 2] == 0 and board[home - 3] == 0
                and board[home - 4] == makePiece(us, ROOK)
                and not self:isAttacked(home - 1, them)
                and not self:isAttacked(home - 2, them) then
                moves[#moves + 1] = { from = home, to = home - 2, piece = KING,
                                      flags = "castle_q" }
            end
        end
    end

    return moves
end

--- Applies a move, recording enough state to undo it.
function Position:makeMove(move)
    local board = self.board
    local us, them = self.turn, opponent(self.turn)

    self.undo_stack[#self.undo_stack + 1] = {
        move = move,
        castling = { [WHITE] = { k = self.castling[WHITE].k, q = self.castling[WHITE].q },
                     [BLACK] = { k = self.castling[BLACK].k, q = self.castling[BLACK].q } },
        ep = self.ep,
        halfmove = self.halfmove,
        king = self.kings[us],
        captured_sq = nil,
    }
    local undo = self.undo_stack[#self.undo_stack]

    local moving = board[move.from]
    board[move.from] = 0

    if move.flags == "ep" then
        -- The captured pawn sits on the moving pawn's rank, not on `to`.
        local cap_sq = (us == WHITE) and (move.to - 16) or (move.to + 16)
        undo.captured_sq = cap_sq
        board[cap_sq] = 0
    end

    if move.promotion then
        board[move.to] = makePiece(us, move.promotion)
    else
        board[move.to] = moving
    end

    if move.piece == KING then
        self.kings[us] = move.to
        self.castling[us].k, self.castling[us].q = false, false
        if move.flags == "castle_k" then
            board[move.to - 1] = board[move.to + 1]
            board[move.to + 1] = 0
        elseif move.flags == "castle_q" then
            board[move.to + 1] = board[move.to - 2]
            board[move.to - 2] = 0
        end
    end

    -- A rook leaving or being captured on a corner revokes that castling right.
    if move.from == A1 or move.to == A1 then self.castling[WHITE].q = false end
    if move.from == H1 or move.to == H1 then self.castling[WHITE].k = false end
    if move.from == A8 or move.to == A8 then self.castling[BLACK].q = false end
    if move.from == H8 or move.to == H8 then self.castling[BLACK].k = false end

    if move.flags == "double" then
        self.ep = (us == WHITE) and (move.from + 16) or (move.from - 16)
    else
        self.ep = nil
    end

    if move.piece == PAWN or move.captured then
        self.halfmove = 0
    else
        self.halfmove = self.halfmove + 1
    end
    if us == BLACK then self.fullmove = self.fullmove + 1 end

    self.turn = them
end

--- Reverts the most recent makeMove.
function Position:undoMove()
    local undo = table.remove(self.undo_stack)
    if not undo then return end
    local move = undo.move
    local board = self.board

    self.turn = opponent(self.turn)
    local us = self.turn

    local moved = board[move.to]
    board[move.to] = 0
    -- A promoted piece reverts to the pawn that moved.
    board[move.from] = move.promotion and makePiece(us, PAWN) or moved

    if move.flags == "ep" then
        board[undo.captured_sq] = move.captured
    elseif move.captured then
        board[move.to] = move.captured
    end

    if move.flags == "castle_k" then
        board[move.to + 1] = board[move.to - 1]
        board[move.to - 1] = 0
    elseif move.flags == "castle_q" then
        board[move.to - 2] = board[move.to + 1]
        board[move.to + 1] = 0
    end

    self.kings[us] = undo.king
    self.castling = undo.castling
    self.ep = undo.ep
    self.halfmove = undo.halfmove
    if us == BLACK then self.fullmove = self.fullmove - 1 end
end

--- The move most recently applied, or nil if none has been.
-- After replaying a puzzle's PGN this is the opponent's move that set the
-- puzzle up, which the board highlights so the user can see what was played.
-- @treturn table|nil move
function Position:lastMove()
    local undo = self.undo_stack[#self.undo_stack]
    return undo and undo.move or nil
end

--- Generates fully legal moves.
-- @int only_from optional square to restrict generation to
function Position:generateLegalMoves(only_from)
    local legal = {}
    local pseudo = self:generatePseudoMoves(only_from)
    local us = self.turn
    for i = 1, #pseudo do
        local move = pseudo[i]
        self:makeMove(move)
        if not self:isAttacked(self.kings[us], opponent(us)) then
            legal[#legal + 1] = move
        end
        self:undoMove()
    end
    return legal
end

--- Legal destination squares for the piece on `from`, for board highlighting.
-- @int from 0x88 square index
-- @treturn table array of moves
function Position:legalMoves(from)
    return self:generateLegalMoves(from)
end

--- True when the side to move is checkmated.
function Position:isCheckmate()
    return self:isCheck() and #self:generateLegalMoves() == 0
end

--- True when the side to move is stalemated.
function Position:isStalemate()
    return (not self:isCheck()) and #self:generateLegalMoves() == 0
end

--- Converts a move table to a UCI string, e.g. "e2e4" or "e7e8q".
function Position:toUCI(move)
    local uci = squareToAlgebraic(move.from) .. squareToAlgebraic(move.to)
    if move.promotion then
        uci = uci .. string.lower(PIECE_LETTER[move.promotion])
    end
    return uci
end

--- Finds the legal move matching a UCI string, without applying it.
-- @string uci e.g. "e2e4", "e7e8q"
-- @treturn table|nil the move, or nil when no legal move matches
function Position:findUCI(uci)
    local from = algebraicToSquare(string.sub(uci, 1, 2))
    local to = algebraicToSquare(string.sub(uci, 3, 4))
    if not from or not to then return nil end
    local promo_char = string.sub(uci, 5, 5)
    local promo = (promo_char ~= "") and LETTER_PIECE[string.upper(promo_char)] or nil

    local moves = self:generateLegalMoves(from)
    for i = 1, #moves do
        local m = moves[i]
        if m.to == to and m.promotion == promo then return m end
    end
    return nil
end

--- Applies a UCI move.
-- @string uci e.g. "e2e4", "e7e8q"
-- @treturn table|nil the applied move, or nil plus an error message
function Position:applyUCI(uci)
    local move = self:findUCI(uci)
    if not move then return nil, "illegal UCI move: " .. tostring(uci) end
    self:makeMove(move)
    return move
end

--- Finds the legal move matching a SAN token.
-- Rather than constructing SAN for every candidate, we parse the token into
-- constraints (piece type, destination, disambiguation) and filter legal moves.
-- @string san e.g. "Nf3", "exd5", "O-O", "e8=Q+", "Nbd2"
-- @treturn table|nil the move, or nil plus an error message
function Position:findSAN(san)
    -- Strip check/mate markers and annotations such as !? and ?!.
    local token = string.gsub(san, "[+#!?]", "")
    token = string.gsub(token, "^%.+", "")
    if token == "" then return nil, "empty SAN token" end

    local moves = self:generateLegalMoves()

    -- Castling, accepting both letter O and digit 0 spellings.
    local normalised = string.gsub(token, "0", "O")
    if normalised == "O-O" or normalised == "O-O-O" then
        local want = (normalised == "O-O") and "castle_k" or "castle_q"
        for i = 1, #moves do
            if moves[i].flags == want then return moves[i] end
        end
        return nil, "castling not available: " .. san
    end

    local promo
    local eq = string.find(token, "=", 1, true)
    if eq then
        promo = LETTER_PIECE[string.upper(string.sub(token, eq + 1, eq + 1))]
        if not promo then return nil, "bad promotion in SAN: " .. san end
        token = string.sub(token, 1, eq - 1)
    end

    -- The destination is always the final two characters.
    local dest = algebraicToSquare(string.sub(token, -2))
    if not dest then return nil, "bad destination in SAN: " .. san end
    local head = string.sub(token, 1, -3)

    local ptype = PAWN
    local first = string.sub(head, 1, 1)
    if LETTER_PIECE[first] and first == string.upper(first) and first ~= "" then
        ptype = LETTER_PIECE[first]
        head = string.sub(head, 2)
    end

    head = string.gsub(head, "x", "")

    -- Whatever remains is disambiguation: a file letter, a rank digit, or both.
    local want_file, want_rank
    for i = 1, #head do
        local c = string.sub(head, i, i)
        if string.match(c, "%a") then
            want_file = string.byte(c) - 97
        elseif string.match(c, "%d") then
            want_rank = tonumber(c) - 1
        end
    end

    local matches = {}
    for i = 1, #moves do
        local m = moves[i]
        if m.to == dest and m.piece == ptype and m.promotion == promo
            and (not want_file or fileOf(m.from) == want_file)
            and (not want_rank or rankOf(m.from) == want_rank) then
            matches[#matches + 1] = m
        end
    end

    if #matches == 0 then return nil, "no legal move matches SAN: " .. san end
    if #matches > 1 then return nil, "ambiguous SAN: " .. san end
    return matches[1]
end

--- Applies a SAN move.
-- @treturn table|nil the applied move, or nil plus an error message
function Position:applySAN(san)
    local move, err = self:findSAN(san)
    if not move then return nil, err end
    self:makeMove(move)
    return move
end

--- Replays a space separated SAN move list into a position.
-- Lichess puzzle PGNs have this shape: no move numbers, no tags, no result.
-- Move numbers and result tokens are tolerated anyway so ordinary PGN movetext works.
-- @string pgn e.g. "d4 d5 Nf3 e5 dxe5 f6"
-- @treturn Position|nil position after the final ply, or nil plus an error message
-- @treturn int number of plies applied
function Chess.newFromPGN(pgn)
    local pos = Chess.new()
    local plies = 0
    for token in string.gmatch(pgn or "", "%S+") do
        -- Skip move numbers ("12." / "12...") and game results.
        local is_number = string.match(token, "^%d+%.*$") ~= nil
        local is_result = token == "1-0" or token == "0-1"
            or token == "1/2-1/2" or token == "*"
        if not is_number and not is_result then
            local move, err = pos:applySAN(token)
            if not move then
                return nil, string.format("ply %d (%s): %s", plies + 1, token, err)
            end
            plies = plies + 1
        end
    end
    return pos, plies
end

--- Deep copies the position, so a view can branch without disturbing the original.
function Position:clone()
    local copy = Chess.newEmpty()
    for sq = 0, 119 do copy.board[sq] = self.board[sq] end
    copy.turn = self.turn
    copy.castling = { [WHITE] = { k = self.castling[WHITE].k, q = self.castling[WHITE].q },
                      [BLACK] = { k = self.castling[BLACK].k, q = self.castling[BLACK].q } }
    copy.ep = self.ep
    copy.halfmove = self.halfmove
    copy.fullmove = self.fullmove
    copy.kings[WHITE] = self.kings[WHITE]
    copy.kings[BLACK] = self.kings[BLACK]
    return copy
end

Chess.Position = Position

return Chess
