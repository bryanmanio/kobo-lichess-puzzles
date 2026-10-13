-- Puzzle solving rules, exercised against the 100 real puzzles in the fixture.
-- Run with: luajit spec/session_spec.lua

package.path = "lichesspuzzles.koplugin/?.lua;spec/fixtures/?.lua;" .. package.path
local Chess = require("chess")
local Session = require("session")
local puzzles = require("puzzles")

local failures, checks = 0, 0
local function check(ok, msg)
    checks = checks + 1
    if not ok then failures = failures + 1; print("FAIL " .. msg) end
    return ok
end

local function byId(id)
    for _, pz in ipairs(puzzles) do
        if pz.id == id then return pz end
    end
end

-- 1. Solving every fixture puzzle correctly must report a clean win.
do
    local solved, bad = 0, 0
    for _, pz in ipairs(puzzles) do
        local s, err = Session.new(pz)
        if not check(s ~= nil, "session failed for " .. pz.id .. ": " .. tostring(err)) then
            bad = bad + 1
        else
            -- The solver owns the odd numbered solution plies; even ones are
            -- replayed automatically as the opponent's answer.
            local ok = true
            for i = 1, #pz.solution, 2 do
                local res = s:tryMove(pz.solution[i])
                if res.result ~= "correct" then
                    print(string.format("FAIL %s: move %d (%s) returned %s",
                        pz.id, i, pz.solution[i], res.result))
                    failures = failures + 1
                    ok = false
                    break
                end
            end
            checks = checks + 1
            if ok then
                if s:isFinished() and s.win and s.state == "solved" then
                    solved = solved + 1
                else
                    failures = failures + 1
                    print(string.format("FAIL %s: finished=%s win=%s state=%s",
                        pz.id, tostring(s:isFinished()), tostring(s.win), s.state))
                end
            end
        end
    end
    print(string.format("solved %d/%d fixture puzzles cleanly", solved, #puzzles))
    check(solved == #puzzles, "every fixture puzzle should solve to a win")
end

-- 2. The solver plays the side to move in the puzzle position, and owns those pieces.
do
    local mismatches = 0
    for _, pz in ipairs(puzzles) do
        local s = Session.new(pz)
        local from = Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2))
        if not s:isOwnPiece(from) then mismatches = mismatches + 1 end
    end
    check(mismatches == 0,
        mismatches .. " puzzles where the first solution move is not the solver's piece")
end

-- 3. A wrong move loses the puzzle and must not disturb the board.
do
    local pz = puzzles[1]
    local s = Session.new(pz)
    local before = s.position:toFEN()
    -- Any legal move that is neither the solution nor mate.
    local wrong
    for _, m in ipairs(s.position:generateLegalMoves()) do
        local uci = s.position:toUCI(m)
        if uci ~= pz.solution[1] then
            s.position:makeMove(m)
            local mate = s.position:isCheckmate()
            s.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    check(wrong ~= nil, "fixture should offer a non-solution, non-mating move")
    local res = s:tryMove(wrong)
    check(res.result == "wrong", "non-solution move should be reported wrong")
    check(s.win == false, "a wrong move should lose the puzzle")
    check(s:isFinished() == false, "a wrong move should still allow retrying")

    -- The move is played so the user can see what they chose: a move that
    -- simply refuses to happen reads as the app being broken.
    check(s.position:toFEN() ~= before, "a wrong move should be shown on the board")
    check(s.pending_wrong ~= nil, "the rejected move should be pending a take-back")

    local reverted = s:revertWrong()
    check(reverted ~= nil, "revertWrong should report the move it took back")
    check(s.position:toFEN() == before, "taking the move back should restore the board")
    check(s.pending_wrong == nil, "nothing should remain pending")
    check(s:revertWrong() == nil, "a second take-back should be a no-op")

    -- Retrying with the real solution still works, but the puzzle stays lost.
    local retry = s:tryMove(pz.solution[1])
    check(retry.result == "correct", "retry after a mistake should be accepted")
    check(s.win == false, "the puzzle stays lost after a mistake")
end

-- 3b. Any further action takes back a pending wrong move implicitly, so the
-- rules are never judged against a board the user only saw transiently.
do
    local pz = puzzles[1]
    local function wrongMoveFor(session)
        for _, m in ipairs(session.position:generateLegalMoves()) do
            local uci = session.position:toUCI(m)
            if uci ~= session:expectedUCI() then
                session.position:makeMove(m)
                local mate = session.position:isCheckmate()
                session.position:undoMove()
                if not mate then return uci end
            end
        end
    end

    -- tryMove reverts before judging the next attempt.
    local s = Session.new(pz)
    local before = s.position:toFEN()
    s:tryMove(wrongMoveFor(s))
    local res = s:tryMove(pz.solution[1])
    check(res.result == "correct", "the next attempt should be judged on the real position")
    check(s.pending_wrong == nil, "tryMove should clear the pending move")

    -- hint reverts too, and points at the real expected move.
    s = Session.new(pz)
    s:tryMove(wrongMoveFor(s))
    local _, from = s:hint()
    check(s.pending_wrong == nil, "hint should take back a pending wrong move")
    check(from == Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2)),
        "the hint should point at the real expected move")
    check(s.position:toFEN() == before, "hint should leave the real position")

    -- revealNext reverts too, and plays the genuine solution move.
    s = Session.new(pz)
    s:tryMove(wrongMoveFor(s))
    local move = s:revealNext()
    check(s.pending_wrong == nil, "revealNext should take back a pending wrong move")
    check(move ~= nil and s.position:toUCI(move) == pz.solution[1],
        "revealNext should play the real solution move")
end

-- 3c. The puzzle records WHY it was lost. Without this a hint is
-- indistinguishable from a rejected move, which genuinely confused a user.
do
    local pz = puzzles[1]
    local function wrongMoveFor(session)
        for _, m in ipairs(session.position:generateLegalMoves()) do
            local uci = session.position:toUCI(m)
            if uci ~= session:expectedUCI() then
                session.position:makeMove(m)
                local mate = session.position:isCheckmate()
                session.position:undoMove()
                if not mate then return uci end
            end
        end
    end

    local s = Session.new(pz)
    check(s.loss_reason == nil, "a fresh puzzle has no loss reason")

    s:hint()
    check(s.win == false, "a hint loses the puzzle")
    check(s.loss_reason == "hint", "the reason should be the hint, got "
        .. tostring(s.loss_reason))

    -- The first reason is what cost the puzzle; later ones must not overwrite it.
    s:tryMove(wrongMoveFor(s))
    check(s.loss_reason == "hint",
        "a later mistake must not rewrite the original reason, got "
        .. tostring(s.loss_reason))

    s = Session.new(pz)
    s:tryMove(wrongMoveFor(s))
    check(s.loss_reason == "wrong move", "a mistake should be recorded as such, got "
        .. tostring(s.loss_reason))

    s = Session.new(pz)
    s:revealNext()
    check(s.loss_reason == "solution", "revealing should be recorded as such, got "
        .. tostring(s.loss_reason))

    -- Solving cleanly records nothing.
    s = Session.new(pz)
    for i = 1, #pz.solution, 2 do s:tryMove(pz.solution[i]) end
    check(s.win == true and s.loss_reason == nil,
        "a clean solve should have no loss reason")
end

-- 3d. A puzzle opens with the opponent's move already highlighted, as the
-- website does. Without it you cannot see what was just played.
do
    local missing, wrong_owner = 0, 0
    for _, pz in ipairs(puzzles) do
        local s = Session.new(pz)
        if not s.last_move then
            missing = missing + 1
        else
            -- The final PGN ply is the opponent's move, so its destination
            -- must hold an opponent piece in the puzzle position.
            local code = s.position:pieceCodeAt(s.last_move.to)
            local colour = code and ((string.sub(code, 1, 1) == "w") and "white" or "black")
            if not code or colour == s.player_color then
                wrong_owner = wrong_owner + 1
            end
        end
    end
    check(missing == 0, missing .. " puzzles opened with no move highlighted")
    check(wrong_owner == 0,
        wrong_owner .. " puzzles highlighted a square that is not the opponent's move")

    -- It tracks play from there.
    local pz = puzzles[1]
    local s = Session.new(pz)
    local opening = s.last_move
    s:tryMove(pz.solution[1])
    check(s.last_move.from ~= opening.from or s.last_move.to ~= opening.to,
        "the highlight should follow play, not stay on the opening move")
end

-- 3e. Being shown the answer is tracked separately from losing credit:
-- a hint costs the rating but you still solve the puzzle yourself.
do
    local pz = puzzles[1]

    local s = Session.new(pz)
    check(s.revealed == false, "a fresh puzzle has not been revealed")
    s:hint()
    for i = 1, #pz.solution, 2 do
        if s:isFinished() then break end
        s:tryMove(pz.solution[i])
    end
    check(s.revealed == false, "a hint is not the same as being shown the answer")
    check(s.win == false, "a hint still costs the credit")
    check(s.state == "solved", "the user still finished the line themselves")

    s = Session.new(pz)
    while not s:isFinished() do s:revealNext() end
    check(s.revealed == true, "revealing should be recorded")
    check(s.win == false, "revealing costs the credit too")
end

-- 4. Illegal input is rejected without touching the board.
do
    local s = Session.new(puzzles[1])
    local before = s.position:toFEN()
    local res = s:tryMove("a1a8")
    check(res.result == "illegal", "an illegal move should be reported as illegal")
    check(s.position:toFEN() == before, "an illegal move must not change the board")
    check(s.win == true, "an illegal move is input noise and must not lose the puzzle")
end

-- 5. Any mating move is accepted, even when it is not the listed solution.
-- 0jFaq reaches a position at solution ply 3 where both h3f5 and g5f6 mate.
do
    local pz = byId("0jFaq")
    if check(pz ~= nil, "fixture 0jFaq should be present") then
        local s = Session.new(pz)
        s:tryMove(pz.solution[1])          -- also auto-plays the opponent reply
        check(s.index == 3, "should be at solution index 3, got " .. tostring(s.index))
        check(pz.solution[3] == "g5f6", "expected solution move should be g5f6")
        local res = s:tryMove("h3f5")      -- a different mate
        check(res.result == "correct", "an alternative mate should be accepted")
        check(res.mate == true, "the result should report mate")
        check(res.solved == true, "mate should finish the puzzle immediately")
        check(s.win == true, "an alternative mate should still count as a win")
    end
end

-- 6. Hints cost the puzzle and point at the expected move.
do
    local pz = puzzles[1]
    local s = Session.new(pz)
    local want_from = Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2))
    local want_to = Chess.algebraicToSquare(string.sub(pz.solution[1], 3, 4))
    local level, from, to = s:hint()
    check(level == 1 and from == want_from and to == nil,
        "first hint should reveal only the source square")
    check(s.win == false, "taking a hint should lose the puzzle")
    local level2, from2, to2 = s:hint()
    check(level2 == 2 and from2 == want_from and to2 == want_to,
        "second hint should reveal the destination")
    local level3 = s:hint()
    check(level3 == 2, "hint level should not go past 2")
end

-- 7. Revealing the solution walks out the whole line and loses the puzzle.
do
    local pz = puzzles[1]
    local s = Session.new(pz)
    local steps, done = 0, false
    while not done and steps < 40 do
        local _, finished = s:revealNext()
        done = finished
        steps = steps + 1
    end
    check(done, "revealNext should finish the puzzle")
    check(steps == #pz.solution, string.format(
        "reveal should take %d steps, took %d", #pz.solution, steps))
    check(s.win == false, "revealing the solution should lose the puzzle")
    check(s.state == "solved", "the puzzle should end in the solved position")
end

-- 8. Nothing happens after the puzzle is over.
do
    local pz = puzzles[1]
    local s = Session.new(pz)
    for i = 1, #pz.solution, 2 do s:tryMove(pz.solution[i]) end
    check(s:isFinished(), "puzzle should be finished")
    local after = s.position:toFEN()
    local res = s:tryMove(pz.solution[1])
    check(res.result == "ignored", "moves after the end should be ignored")
    check(s.position:toFEN() == after, "the board must not change after the end")
    check(s:expectedUCI() == nil, "there is no expected move once finished")
end

-- 9. The report sent to lichess carries the id, outcome and rated flag.
do
    local s = Session.new(puzzles[1])
    local report = s:solutionReport(true)
    check(report.id == puzzles[1].id, "report should carry the puzzle id")
    check(report.win == true and report.rated == true, "a clean solve reports a rated win")
    s.win = false
    check(s:solutionReport(false).rated == false, "unrated mode should report rated=false")
end

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
