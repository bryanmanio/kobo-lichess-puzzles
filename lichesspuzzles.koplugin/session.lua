--[[--
A single puzzle attempt: the rules of solving, with no UI.

Lichess puzzle conventions this implements, verified against live payloads:
  * The puzzle position is the end of game.pgn (plies == initialPly + 1).
  * solution[1] is the solver's move, solution[2] the opponent's reply, and so on.
  * The solver plays whichever colour is to move in the puzzle position.
  * Any move that delivers checkmate is accepted, even when it is not the
    listed solution, matching the website in positions with more than one mate.
  * A wrong move or a hint loses the puzzle, which is what gets reported to
    lichess as win = false.

Keeping this free of KOReader lets the whole solving flow be unit tested.

@module koplugin.lichesspuzzles.session
]]

local Chess = require("chess")

local Session = {}
Session.__index = Session

--- Starts an attempt at a puzzle.
-- @tparam table puzzle { id, pgn, solution, rating, themes }
-- @treturn Session|nil session, or nil plus an error message
function Session.new(puzzle)
    local pos, err = Chess.newFromPGN(puzzle.pgn)
    if not pos then return nil, err end

    local self = setmetatable({}, Session)
    self.puzzle = puzzle
    self.position = pos
    self.solution = puzzle.solution or {}
    self.index = 1              -- next expected entry in solution
    self.player_color = pos:sideToMove()
    self.win = true             -- until a mistake or a hint
    self.loss_reason = nil      -- why it was lost: "hint", "wrong move", ...
    self.revealed = false       -- true once the solution was played for them
    self.state = "playing"      -- playing | solved | failed
    self.hint_level = 0
    -- The puzzle position is the end of the PGN, so the final ply is the
    -- opponent's move. Highlighting it from the start is how the website
    -- presents a puzzle, and it is the context you need to solve it.
    local opening = pos:lastMove()
    self.last_move = opening and { from = opening.from, to = opening.to } or nil
    self.pending_wrong = nil    -- a rejected move left on the board to be seen
    self.attempts = 0

    -- A puzzle with no solution is unsolvable; treat it as already finished.
    if #self.solution == 0 then self.state = "solved" end
    return self
end

--- Records that the puzzle has been lost, and why.
-- The first reason is kept: whatever cost the puzzle first is what cost it.
-- @string reason short, user-facing: "hint", "wrong move", "solution"
function Session:markLost(reason)
    if not self.win then return end
    self.win = false
    self.loss_reason = reason
end

--- The UCI string the solver is expected to play next, or nil when finished.
function Session:expectedUCI()
    if self.state ~= "playing" then return nil end
    return self.solution[self.index]
end

--- Source and destination squares of the expected move, for hints.
-- @treturn int|nil, int|nil from and to squares
function Session:expectedSquares()
    local uci = self:expectedUCI()
    if not uci then return nil, nil end
    return Chess.algebraicToSquare(string.sub(uci, 1, 2)),
           Chess.algebraicToSquare(string.sub(uci, 3, 4))
end

--- Legal moves for a square, used to highlight destinations on selection.
function Session:legalMoves(from)
    if self.state ~= "playing" then return {} end
    return self.position:legalMoves(from)
end

--- True when the square holds a piece belonging to the solver.
function Session:isOwnPiece(sq)
    local code = self.position:pieceCodeAt(sq)
    if not code then return false end
    local color = (string.sub(code, 1, 1) == "w") and "white" or "black"
    return color == self.player_color
end

local function squaresOf(move)
    return { from = move.from, to = move.to }
end

--- Plays the opponent's scripted reply, if the solution has one left.
-- @treturn table|nil the reply move
local function playReply(self)
    local uci = self.solution[self.index]
    if not uci then
        self.state = "solved"
        return nil
    end
    local move = self.position:applyUCI(uci)
    if not move then
        -- The solution disagrees with the rules; fail loudly rather than hang.
        self.state = "failed"
        return nil
    end
    self.index = self.index + 1
    self.last_move = squaresOf(move)
    if self.index > #self.solution then self.state = "solved" end
    return move
end

--- Takes back a rejected move that was left on the board for the user to see.
-- @treturn table|nil the move that was taken back
function Session:revertWrong()
    local move = self.pending_wrong
    if not move then return nil end
    self.position:undoMove()
    self.pending_wrong = nil
    return move
end

--- Attempts a solver move.
-- A wrong move IS applied, so the user sees it; call revertWrong (or any
-- further action, which does it implicitly) to take it back.
-- @string uci e.g. "e2e4", "e7e8q"
-- @treturn table result:
--   { result = "correct"|"wrong"|"illegal"|"ignored",
--     solved = bool, move = table|nil, reply = table|nil, mate = bool }
function Session:tryMove(uci)
    if self.state ~= "playing" then
        return { result = "ignored", solved = false }
    end
    -- Any rejected move still sitting on the board is taken back first, so
    -- legality is judged against the real position.
    self:revertWrong()

    local move = self.position:findUCI(uci)
    if not move then
        return { result = "illegal", solved = false }
    end

    self.attempts = self.attempts + 1
    local expected = self.solution[self.index]

    -- Check for mate before deciding, so an alternative mate still counts.
    self.position:makeMove(move)
    local is_mate = self.position:isCheckmate()
    self.position:undoMove()

    if uci ~= expected and not is_mate then
        self:markLost("wrong move")
        -- Play it anyway: a move that simply refuses to happen reads as the
        -- app being broken. It is taken back on the next action, so the user
        -- can carry on looking for the right move.
        self.position:makeMove(move)
        self.pending_wrong = move
        return { result = "wrong", solved = false, move = move }
    end

    self.position:makeMove(move)
    self.index = self.index + 1
    self.last_move = squaresOf(move)

    -- Mate ends the puzzle immediately, whichever mating move was chosen.
    if is_mate or self.index > #self.solution then
        self.state = "solved"
        return { result = "correct", solved = true, move = move, mate = is_mate }
    end

    local reply = playReply(self)
    return {
        result = "correct",
        solved = self.state == "solved",
        move = move,
        reply = reply,
        mate = false,
    }
end

--- Reveals progressively more of the expected move. Costs the puzzle.
-- @treturn int level reached, 1 for the source square and 2 for the destination
-- @treturn int|nil, int|nil squares to highlight
function Session:hint()
    if self.state ~= "playing" then return self.hint_level end
    self:revertWrong()
    self:markLost("hint")
    self.hint_level = math.min(self.hint_level + 1, 2)
    local from, to = self:expectedSquares()
    if self.hint_level == 1 then return 1, from, nil end
    return 2, from, to
end

--- Plays the next move of the solution for the user. Costs the puzzle.
-- Call repeatedly to walk out the rest of the line.
-- @treturn table|nil the move played
-- @treturn bool whether the puzzle is now finished
function Session:revealNext()
    if self.state ~= "playing" then return nil, true end
    self:revertWrong()
    self:markLost("solution")
    -- Being shown the answer is not solving it, however the line then ends.
    self.revealed = true
    local uci = self.solution[self.index]
    if not uci then
        self.state = "solved"
        return nil, true
    end
    local move = self.position:applyUCI(uci)
    if not move then
        self.state = "failed"
        return nil, true
    end
    self.index = self.index + 1
    self.last_move = squaresOf(move)
    if self.index > #self.solution or self.position:isCheckmate() then
        self.state = "solved"
    end
    return move, self.state ~= "playing"
end

--- True once the puzzle can no longer be played.
function Session:isFinished()
    return self.state ~= "playing"
end

--- The result to report to lichess.
-- @treturn table { id = ..., win = ..., rated = ... }
function Session:solutionReport(rated)
    return { id = self.puzzle.id, win = self.win, rated = rated and true or false }
end

return Session
