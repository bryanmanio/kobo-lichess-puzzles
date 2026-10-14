--[[--
Full screen puzzle solving view: board, a single status line, and the controls.

The view has two modes. While solving, the controls are Hint and Solution. Once
the puzzle is over they become back/forward arrows for stepping through the
solution, plus Redo to attempt the same puzzle again.

Everything the user needs to know lives in one short line above the board:
whose turn it is, whether the puzzle has been lost, the result and rating
change once known, and the move number while reviewing. There is deliberately
no second line of prose, which would cost a row of screen for text that the
board already conveys.

Failure is reported the moment it happens rather than only in the final score:
a wrong move puts LOST in the status line and leaves the rejected square marked
until the next tap.

Refresh strategy matters more than anything else here. Repainting the whole
board on every tap would be slow and would ghost badly, so:
  * picking a piece up or putting it down refreshes only the affected squares,
    with a greyscale-capable waveform
  * a played move refreshes just the squares involved, with "ui"
  * stepping through the solution refreshes only the squares that changed
  * a new puzzle does one "full" refresh to clear accumulated ghosting

The opponent's reply is painted in the same refresh as the solver's move
rather than after a delay. On e-ink two refreshes in quick succession reads as
a flash, and the last-move highlight already shows what the opponent played.

@module koplugin.lichesspuzzles.puzzleview
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local BoardWidget = require("boardwidget")
local Chess = require("chess")
local Session = require("session")

--- The status strip above the board.
-- CenterContainer never records where it was painted, but setDirty needs the
-- strip's real position: a Geom defaults to x=0,y=0, so refreshes were landing
-- in the screen's top-left corner instead of on the status line, and updates
-- often never reached the panel. Inverting the whole strip is also the most
-- legible "this puzzle is over" signal e-ink can give.
local StatusBar = CenterContainer:extend{ inverted = false }

function StatusBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    CenterContainer.paintTo(self, bb, x, y)
    if self.inverted then
        bb:invertRect(x, y, self.dimen.w, self.dimen.h)
    end
end

-- Module scope: the artwork warning is shown once per run, not per puzzle.
local warned_about_artwork = false

-- How long a rejected move stays on the board before it is put back. Long
-- enough to see what was played and read the cross, short enough not to feel
-- like the app has hung.
local WRONG_MOVE_LINGER = 0.9

local BACK_LABEL = "←"
local FORWARD_LABEL = "→"

local PuzzleView = InputContainer:extend{
    puzzle = nil,            -- { id, pgn, solution, rating, themes }
    rated = true,
    signed_in = true,
    pieces_dir = nil,
    on_finished = nil,       -- function(session) when the puzzle ends
    on_next = nil,           -- function() to request the next puzzle
    on_exit = nil,           -- function() when the user leaves
    on_menu = nil,           -- function() when the status line is tapped
    covers_fullscreen = true,
}

function PuzzleView:init()
    self.session = Session.new(self.puzzle)
    if not self.session then
        -- A puzzle we cannot parse is not recoverable; let the caller skip it.
        self.broken = true
        return
    end

    self.mode = "playing"    -- playing | review
    self.review = nil
    self.result_text = nil   -- the outcome from lichess, kept in the status line
    self.submitted = false   -- a redone puzzle must not be reported twice

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    -- Room for the status line and the button row, and nothing else.
    local chrome = Screen:scaleBySize(150)
    local square = math.floor(math.min(screen_w, screen_h - chrome) / 8)

    self.board = BoardWidget:new{
        position = self.session.position,
        square_size = square,
        -- Orient so the solver's pieces are at the bottom, as on the website.
        flipped = self.session.player_color == "black",
        pieces_dir = self.pieces_dir,
        on_square_tap = function(sq) self:onSquareTap(sq) end,
    }

    -- Sized to the board rather than the screen, so a long line truncates with
    -- an ellipsis inside the board's width instead of running off the panel.
    -- Show the opponent's setup move straight away, as the website does.
    if self.session.last_move then
        self.board:setLastMove(self.session.last_move.from, self.session.last_move.to)
    end

    self.status_text = TextWidget:new{
        text = self:statusLine(),
        face = Font:getFace("cfont", 20),
        max_width = self.board.dimen.w,
    }
    -- VerticalGroup caches each child's width when it first lays out, so a
    -- status line that later gets shorter would keep being painted at the
    -- original offset and drift off centre. A fixed-size CenterContainer
    -- re-centres on every paint, and its constant width also means the refresh
    -- region always covers whatever the previous, longer line left behind.
    self.status_container = StatusBar:new{
        dimen = Geom:new{
            w = self.board.dimen.w,
            h = self.status_text:getSize().h,
        },
        self.status_text,
    }

    -- One row of four. Hint and Solution become the review arrows once the
    -- puzzle is over, which is why their callbacks dispatch on the mode.
    self.button_table = ButtonTable:new{
        width = screen_w - Screen:scaleBySize(20),
        buttons = { {
            { text = _("Hint"), id = "hint",
              callback = function()
                  if self.mode == "review" then self:onReviewBack() else self:onHint() end
              end },
            { text = _("Solution"), id = "solution",
              callback = function()
                  if self.mode == "review" then self:onReviewForward() else self:onShowSolution() end
              end },
            { text = _("Redo"), id = "redo", enabled = false,
              callback = function() self:onRedo() end },
            { text = _("Next"), id = "next", enabled = false,
              callback = function() self:onNextPuzzle() end },
        } },
        show_parent = self,
    }

    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            VerticalGroup:new{
                align = "center",
                self.status_container,
                VerticalSpan:new{ width = Screen:scaleBySize(10) },
                self.board,
                VerticalSpan:new{ width = Screen:scaleBySize(10) },
                self.button_table,
            },
        },
    }

    if Device:isTouchDevice() then
        -- The status line doubles as the board's menu button. Kobo has no Back
        -- key, so without this there is no way off the board at all when the
        -- puzzles were launched on their own from the home screen.
        self.ges_events = {
            TapStatus = {
                GestureRange:new{
                    ges = "tap",
                    -- A function, not the dimen itself: StatusBar only learns
                    -- its real position the first time it is painted.
                    range = function() return self:statusTapRegion() end,
                },
            },
        }
    end

    if self.board.artwork_missing and not warned_about_artwork then
        warned_about_artwork = true
        -- The board stays playable via letters, but only the user can restore
        -- the images, so say so rather than leaving it a mystery.
        UIManager:show(InfoMessage:new{
            text = _("Piece images are missing, so pieces are shown as letters (uppercase is White).\n\nRe-copy the lichesspuzzles.koplugin folder to the device to restore them."),
        })
    end

    if Device:hasKeys() then
        -- The Libra's physical page-turn buttons. In review mode they step
        -- through the solution, which is the natural thing to want there.
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPuzzle = { { Device.input.group.PgFwd } },
            Hint = { { Device.input.group.PgBack } },
        }
    end
end

--- "FAILED", saying what cost the puzzle. Without the reason a hint looks
--- exactly like a rejected move, which is genuinely confusing.
function PuzzleView:failedLabel()
    local reason = self.session.loss_reason
    if not reason then return _("Failed") end
    return T(_("Failed (%1)"), reason)
end

--- True when this attempt can still affect the rating. A hint switches the
--- current puzzle to casual; the next one starts rated again, because each
--- puzzle gets a fresh view that reads the global setting.
function PuzzleView:isRatedAttempt()
    return self.session:isRatedAttempt(self.rated)
end

--- How the puzzle ended, which is a different question from whether it earned
--- any rating. Playing the line out yourself is a solve even when a hint means
--- it does not count; being shown the answer is not a solve at all. Reporting
--- a hinted-then-solved puzzle as "FAILED" hid the fact that it was solved.
function PuzzleView:outcomeLabel()
    local session = self.session
    if session.revealed then return _("Failed") end
    if session.win then return _("Solved") end
    local SHORT = { hint = _("hint"), ["wrong move"] = _("mistake") }
    local why = SHORT[session.loss_reason or ""]
    if why then return T(_("Solved (%1)"), why) end
    return _("Solved (no credit)")
end

--- The one line above the board. Kept short so it never needs truncating:
--- the puzzle id is deliberately not shown, as it is not useful while solving.
function PuzzleView:statusLine()
    local session = self.session
    local parts = {}

    if self.result_text then
        -- Once lichess has answered, the outcome and rating change are the
        -- headline, and stay visible while stepping through the solution.
        parts[#parts + 1] = self.result_text
    elseif session:isFinished() then
        parts[#parts + 1] = self:outcomeLabel()
    elseif not session.win then
        -- Once lost, that is the headline: it leads, and says why, so a hint
        -- is never mistaken for the move being rejected. Whose turn it is is
        -- obvious from the board, and dropping it keeps the line short.
        parts[#parts + 1] = self:failedLabel()
    else
        parts[#parts + 1] = (session.player_color == "white")
            and _("White to play") or _("Black to play")
        if self.puzzle.rating then
            parts[#parts + 1] = T(_("Puzzle %1"), string.format("%d", self.puzzle.rating))
        end
    end

    -- Shown in every state, including a lost puzzle: a missing token means
    -- nothing is being recorded, which the user needs to know regardless.
    if not self.result_text then
        if not self.signed_in then
            -- Distinct from "casual": one is a choice, the other is a problem
            -- the user can fix, and showing "casual" for both is misleading.
            parts[#parts + 1] = _("No token")
        elseif not self:isRatedAttempt() then
            parts[#parts + 1] = _("Casual")
        end
    end

    if self.review then
        parts[#parts + 1] = string.format("%d/%d", self.review.index, #self.review.line)
    end

    return BD.wrap(table.concat(parts, "  ·  "))
end

--- Where a tap counts as "open the menu".
-- A single line of text is a small target on e-ink, so the region is grown
-- into the empty space above it. It is not grown far below: the board's own
-- tap handling starts there, and the board must stay the easy thing to hit.
function PuzzleView:statusTapRegion()
    local dimen = self.status_container.dimen
    local above = Screen:scaleBySize(30)
    return Geom:new{
        x = dimen.x,
        y = dimen.y - above,
        w = dimen.w,
        h = dimen.h + above,
    }
end

function PuzzleView:onTapStatus()
    if self.on_menu then self.on_menu(self) end
    return true
end

function PuzzleView:updateStatus()
    self.status_text:setText(self:statusLine())
    -- Refresh the whole status strip, not just the new text: a shorter line
    -- must erase what the longer one left on the panel.
    UIManager:setDirty(self, "ui", self.status_container.dimen)
end

--- Repaints only the given squares, which keeps e-ink refreshes cheap.
-- @tparam table squares array of square indices
-- @string mode refresh waveform. Must be greyscale-capable: the dark
--   squares are grey, and the "fast" (DU) waveform renders any content
--   to pure black and white, which erases the checkerboard where it lands.
function PuzzleView:refreshSquares(squares, mode)
    local region = self.board:regionFor(squares)
    if not region then return end
    UIManager:setDirty(self, mode or "ui", region)
end

--- Switches the controls between solving and reviewing.
function PuzzleView:setButtonMode(mode)
    self.mode = mode
    local hint = self.button_table:getButtonById("hint")
    local solution = self.button_table:getButtonById("solution")
    local redo = self.button_table:getButtonById("redo")
    local next_button = self.button_table:getButtonById("next")

    if mode == "review" then
        if hint then hint:setText(BACK_LABEL, hint.width); hint:enable() end
        if solution then solution:setText(FORWARD_LABEL, solution.width); solution:enable() end
        if redo then redo:enable() end
        if next_button then next_button:enable() end
    else
        if hint then hint:setText(_("Hint"), hint.width); hint:enable() end
        if solution then solution:setText(_("Solution"), solution.width); solution:enable() end
        -- Redo stays available once the puzzle is lost, so a mistake can be
        -- retried from the start without first playing the puzzle out.
        if redo then
            if self.session.win then redo:disable() else redo:enable() end
        end
        if next_button then next_button:disable() end
    end

    for _, button in ipairs({ hint, solution, redo, next_button }) do
        if button then button:refresh() end
    end
end

--- Takes back a rejected move left on the board.
-- @treturn table squares that need repainting
function PuzzleView:takeBackWrongMove()
    if self.take_back_scheduled then
        UIManager:unschedule(self.take_back_scheduled)
        self.take_back_scheduled = nil
    end
    local move = self.session:revertWrong()
    if not move then return {} end
    self.board:clearMarks()
    return { move.from, move.to }
end

--- Enables Redo the moment the puzzle is lost, mid-play, so a mistake can be
--- retried without playing the rest of the line out first.
function PuzzleView:updateRedoAvailability()
    local redo = self.button_table:getButtonById("redo")
    if not redo then return end
    local available = self.mode == "review"
        or not self.session.win or self.session.hinted
    if available == redo.enabled then return end
    if available then redo:enable() else redo:disable() end
    redo:refresh()
end

--- Shows a rejected move briefly, then puts the piece back so the user can
--- try again, as the website does. Tapping sooner takes it back immediately.
function PuzzleView:scheduleTakeBack()
    if self.take_back_scheduled then
        UIManager:unschedule(self.take_back_scheduled)
    end
    self.take_back_scheduled = function()
        self.take_back_scheduled = nil
        local restored = self:takeBackWrongMove()
        if #restored > 0 then
            self:refreshSquares(restored, "ui")
        end
    end
    UIManager:scheduleIn(WRONG_MOVE_LINGER, self.take_back_scheduled)
end

function PuzzleView:onSquareTap(sq)
    local session = self.session
    if self.mode == "review" or session:isFinished() then return end

    local previous = self.board:markedSquares()
    -- A rejected move is left on the board so it can be seen; take it back as
    -- soon as the user acts again.
    local restored = self:takeBackWrongMove()
    for i = 1, #restored do previous[#previous + 1] = restored[i] end
    self.board:clearMarks()

    -- Completing a move: the tapped square is a highlighted destination.
    if self.board.selected and self.board.destinations[sq] then
        local from = self.board.selected
        local moves = session:legalMoves(from)
        local candidates = {}
        for i = 1, #moves do
            if moves[i].to == sq then candidates[#candidates + 1] = moves[i] end
        end
        if #candidates > 1 and candidates[1].promotion then
            self:askPromotion(from, sq, candidates)
            return
        end
        self:playMove(session.position:toUCI(candidates[1]))
        return
    end

    if sq == self.board.selected then
        -- Tapping the piece again puts it back down.
        self.board:setSelection(nil, nil)
    elseif session:isOwnPiece(sq) then
        self.board:setSelection(sq, session:legalMoves(sq))
    end
    -- Otherwise the tap was not a legal destination, so the selection is left
    -- alone. Clearing it would make a mis-tap look exactly like the app
    -- freezing, which is the one thing the board must never look like.

    local changed = self.board:markedSquares()
    for i = 1, #previous do changed[#changed + 1] = previous[i] end
    self:refreshSquares(changed, "ui")
end

--- Asks which piece a promoting pawn should become.
function PuzzleView:askPromotion(from, to, candidates)
    local LABELS = { q = _("Queen"), r = _("Rook"), b = _("Bishop"), n = _("Knight") }
    local row = {}
    for i = 1, #candidates do
        local uci = self.session.position:toUCI(candidates[i])
        local piece = string.sub(uci, 5, 5)
        row[#row + 1] = {
            text = LABELS[piece] or string.upper(piece),
            callback = function()
                UIManager:close(self.promotion_dialog)
                self.promotion_dialog = nil
                self:playMove(uci)
            end,
        }
    end
    self.promotion_dialog = ButtonDialog:new{
        title = _("Promote to"),
        title_align = "center",
        buttons = { row },
    }
    UIManager:show(self.promotion_dialog)
end

function PuzzleView:playMove(uci)
    local session = self.session
    local before = self.board:markedSquares()
    local was_lost = not session.win
    local result = session:tryMove(uci)

    if result.result == "illegal" or result.result == "ignored" then
        return
    end

    if result.result == "wrong" then
        -- The move was never applied, so there is nothing to take back. Mark
        -- the square and leave the mark up until the next tap, so a glance at
        -- the board still shows what was rejected.
        self.board:setSelection(nil, nil)
        self.board:setMark(result.move.to, "error")
        -- The move was played, so the square it came from changed too.
        local touched = { result.move.from, result.move.to }
        for i = 1, #before do touched[#touched + 1] = before[i] end
        self:refreshSquares(touched, "ui")
        -- Always refresh the status: FAILED must appear on the very first
        -- mistake, not only once the rating comes back.
        self:updateStatus()
        self:updateRedoAvailability()
        self:scheduleTakeBack()
        return
    end

    -- Correct. The solver's move and the scripted reply are both on the board.
    self.board:setSelection(nil, nil)
    self.board:clearMarks()
    -- Tick the square the solver moved to, so a correct move is acknowledged
    -- rather than just quietly accepted. It clears on the next tap.
    self.board:setMark(result.move.to, "correct")
    local touched = { result.move.from, result.move.to }
    if result.reply then
        touched[#touched + 1] = result.reply.from
        touched[#touched + 1] = result.reply.to
        self.board:setLastMove(result.reply.from, result.reply.to)
    else
        self.board:setLastMove(result.move.from, result.move.to)
    end
    for i = 1, #before do touched[#touched + 1] = before[i] end
    self:refreshSquares(touched, "ui")

    if result.solved then
        self:finish()
    end
end

function PuzzleView:onHint()
    local session = self.session
    if self.mode == "review" or session:isFinished() then return end
    local was_lost = not session.win
    local touched = self.board:markedSquares()
    local restored = self:takeBackWrongMove()
    for i = 1, #restored do touched[#touched + 1] = restored[i] end
    local level, from, to = session:hint()
    self.board:clearMarks()
    if from then
        self.board:setMark(from, "hint")
        touched[#touched + 1] = from
    end
    if level == 2 and to then
        self.board:setMark(to, "hint")
        touched[#touched + 1] = to
    end
    self:refreshSquares(touched, "ui")
    -- Always refresh: the first hint flips the line to casual.
    self:updateStatus()
    self:updateRedoAvailability()
    return true
end

--- Plays out the rest of the solution, one move per refresh.
function PuzzleView:onShowSolution()
    local session = self.session
    if self.mode == "review" or session:isFinished() then return end
    self.board:setSelection(nil, nil)
    local restored = self:takeBackWrongMove()
    if #restored > 0 then self:refreshSquares(restored, "ui") end
    self.board:clearMarks()
    self:updateStatus()

    local function step()
        local move, done = session:revealNext()
        if move then
            self.board:setLastMove(move.from, move.to)
            self:refreshSquares({ move.from, move.to }, "ui")
        end
        if done then
            self:finish()
        else
            UIManager:scheduleIn(0.7, step)
        end
    end
    step()
end

--- Ends the puzzle, switches to review controls and reports the result.
function PuzzleView:finish()
    self.board:setSelection(nil, nil)
    self.board:clearMarks()
    self:setButtonMode("review")
    self:enterReview()
    -- Invert the whole status strip: on e-ink this is the clearest possible
    -- signal that the puzzle is over, and the word says which way it went.
    self.status_container.inverted = true
    self:updateStatus()

    if self.on_finished and not self.submitted then
        -- The caller submits the result and calls back with a rating change.
        self.submitted = true
        self.on_finished(self.session)
    end
end

--- Prepares stepping through the puzzle's solution from its start position.
function PuzzleView:enterReview()
    local start = Chess.newFromPGN(self.puzzle.pgn)
    if not start then return end
    self.review = {
        start = start,
        line = self.puzzle.solution or {},
        index = 0,
    }
    -- Show the finished position first; the user steps back from there.
    self:reviewGoTo(#self.review.line)
end

--- Shows the position after `index` moves of the solution.
-- The position is rebuilt from the puzzle start each time, which is cheap for
-- the handful of moves a puzzle has and avoids unwinding history.
function PuzzleView:reviewGoTo(index)
    local review = self.review
    if not review then return end
    index = math.max(0, math.min(index, #review.line))

    local position = review.start:clone()
    -- At index 0 the relevant move is the opponent's setup move, so the start
    -- of a review looks like the puzzle did when it opened.
    local opening = review.start:lastMove()
    local last_from = opening and opening.from
    local last_to = opening and opening.to
    for i = 1, index do
        local move = position:applyUCI(review.line[i])
        if move then
            last_from, last_to = move.from, move.to
        end
    end

    local previous = self.board:markedSquares()
    local changed = self.board:setPosition(position)
    self.board:setSelection(nil, nil)
    self.board:clearMarks()
    self.board:setLastMove(last_from, last_to)
    review.index = index

    for i = 1, #previous do changed[#changed + 1] = previous[i] end
    if last_from then
        changed[#changed + 1] = last_from
        changed[#changed + 1] = last_to
    end
    self:refreshSquares(changed, "ui")
    self:updateStatus()
end

function PuzzleView:onReviewBack()
    if not self.review then return true end
    self:reviewGoTo(self.review.index - 1)
    return true
end

function PuzzleView:onReviewForward()
    if not self.review then return true end
    self:reviewGoTo(self.review.index + 1)
    return true
end

--- Restarts the same puzzle. The result has already been reported, so this
--- never submits again and cannot change the rating a second time.
function PuzzleView:onRedo()
    local session = Session.new(self.puzzle)
    if not session then return true end
    -- If the puzzle was lost and that loss has not been reported yet, carry it
    -- into the retry: the mistake already happened, and a second attempt must
    -- not be able to report a win for a puzzle that was failed. Once the
    -- result has been sent, a retry is pure practice and starts clean.
    local carry_loss = (not self.session.win) and (not self.submitted)
    local carried_reason = self.session.loss_reason
    -- A hint already spent this puzzle's rating chance; retrying must not win
    -- it back, so the casual flag carries until the result has been reported.
    local carry_hint = self.session.hinted and not self.submitted
    self.session = session
    if carry_loss then
        session.win = false
        session.loss_reason = carried_reason
    end
    session.hinted = carry_hint
    self.review = nil
    self.board:setPosition(session.position)
    self.board:setSelection(nil, nil)
    self.board:clearMarks()
    local opening = session.last_move
    self.board:setLastMove(opening and opening.from, opening and opening.to)
    self:setButtonMode("playing")
    self.status_container.inverted = false
    -- Drop the previous attempt's result, or the retry would open still
    -- displaying the outcome and rating change of the attempt before it.
    self.result_text = nil
    self:updateStatus()
    -- Many squares change at once; one full refresh also clears ghosting.
    UIManager:setDirty(self, "full")
    return true
end

--- Shows the outcome reported by lichess, e.g. the rating change.
-- It goes in the status line so it stays visible while reviewing the moves.
function PuzzleView:showResult(text)
    self.result_text = text
    self:updateStatus()
end

function PuzzleView:onNextPuzzle()
    if not self.session:isFinished() then return true end
    if self.on_next then self.on_next() end
    return true
end

function PuzzleView:onClose()
    UIManager:close(self)
    if self.on_exit then self.on_exit() end
    return true
end

function PuzzleView:onCloseWidget()
    if self.take_back_scheduled then
        UIManager:unschedule(self.take_back_scheduled)
        self.take_back_scheduled = nil
    end
    if self.board then self.board:freePieces() end
end

function PuzzleView:onShow()
    -- One full refresh per puzzle clears ghosting left by the previous one.
    UIManager:setDirty(self, "full")
    return true
end

return PuzzleView
